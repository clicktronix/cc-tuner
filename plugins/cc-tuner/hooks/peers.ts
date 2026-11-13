import type { EngineInterface } from 'claude-code'

// Sessions of one product see each other: who is live next to this session, on which branch, claiming and
// editing which paths, and what the guard decides for a call (allow, a note, or a stop with its reason).
//
// One JSON record per Claude session in the record directory (CC_TUNER_PEERS_DIR, default
// ~/.cache/cc-tuner/sessions). A session writes only its own record, one write at a time in this
// process; other records are only read, and one that does not parse is skipped and noted. A session is
// its Claude process, pid plus start time; a nested `claude -p` counts as the outermost `claude` above it
// and shares its record. A record whose process is gone, or is another process now, is a tombstone: no
// longer a peer, its edited paths still on disk. A tombstone untouched for 24 h is removed; a resumed
// session with the same session_id adopts it. `/clear` drops acks and claims.
//
//   {session_id, pid, start, seen, claims: {<plan>: {repo, paths}}, acks: {<key>: <epoch>}, kept: [<task>],
//    checkouts: {<toplevel>: {repo, expected, writer, paths}}}
//
// repo is the git common directory, so worktrees of one repository share it. expected is the branch at
// first touch, moved only when HEAD changed during this session's own call that held a switch; writer
// the epoch of the last writer call; paths what Edit/Write changed. acks also hold the hourly notes.
//
// Resources are declared, not detected: `<toplevel>/.claude/cc-tuner-resources.json` (`product` and `resources`)
// and the machine's own file (CC_TUNER_PEERS_CONFIG, else $XDG_CONFIG_HOME or ~/.config, cc-tuner/resources.json),
// each read again when its mtime changes. A shared resource (`start` and `stop` command prefixes) is not stopped
// while another session of the product is live; the machine's, while any session is. An exclusive one (`tools`,
// MCP tool-name patterns) is leased to the first session that calls one: a lock directory `lease.<key>` in the
// record directory, made by an atomic `mkdir` that carries {key, pid, start, session, last use}. The lease moves
// on the holder's `peers_release`, after 10 minutes of its silence, or when its process is gone.
//
// A process runs only for what a decision needs: `ps` (start times kept for a minute), `git status`
// before a command that could lose or commit files, and the reads `peers_report` and `kill` need.

// A step's directory when a `cd` could not be read: the checkout it acts on is not known.
export const UNKNOWN = '\0'
export interface Step { words: string[]; dir: string; op: string; writes: boolean }
export interface Event {
  session_id?: string; phase: 'before' | 'after' | 'start'; tool?: string; cwd: string
  path?: string; steps?: Step[]; seen?: Record<string, string>; acks?: string[]; ok?: boolean
}
export interface Resource { key: string; kind: 'shared' | 'exclusive'; start: string[]; stop: string[]; tools: string[] }
interface Config { product?: string; resources: Resource[] }
interface Holder { key: string; pid: number; start: string; session: string | null; last: number }
export interface Verdict { decision: 'allow' | 'note' | 'stop'; reason?: string; seen?: Record<string, string> }
interface Checkout { repo: string; expected: string; writer: number | null; paths: string[] }
export interface Rec {
  session_id: string | null; pid: number; start: string; seen: number
  claims: Record<string, { repo: string; paths: string[] }>; acks: Record<string, number>; kept: string[]
  checkouts: Record<string, Checkout>
}
type Where = readonly [top: string, common: string]

// What the guard reads and runs, from the engine in a session and from a fake in the tests.
export interface World {
  dir: () => Promise<string>
  config: () => Promise<string>
  read: (path: string) => Promise<string>
  write: (path: string, text: string) => Promise<void>
  list: (dir: string) => Promise<readonly { name: string; kind: string; size: number; mtimeMs: number }[]>
  stat: (path: string) => Promise<{ kind: string; realPath?: string; mtimeMs?: number; size?: number } | undefined>
  run: (argv: readonly string[], init?: { env?: Record<string, string> }) => Promise<{ exitCode: number; stdout: string }>
  now: () => number
}

export function world($: EngineInterface): World {
  return {
    dir: async () => (await $.env.get('CC_TUNER_PEERS_DIR')) || `${await $.env.get('HOME')}/.cache/cc-tuner/sessions`,
    config: async () => (await $.env.get('CC_TUNER_PEERS_CONFIG')) ||
      `${(await $.env.get('XDG_CONFIG_HOME')) || `${await $.env.get('HOME')}/.config`}/cc-tuner/resources.json`,
    read: path => $.fs.read(path),
    write: (path, text) => $.fs.write(path, text),
    list: dir => $.fs.list(dir),
    stat: path => $.fs.stat(path, { resolve: true }).catch(() => undefined),
    run: (argv, init) => $.process.run(argv, { ...init, timeoutMs: 5000 }),
    now: () => Date.now(),
  }
}

const DAY = 24 * 3600
const ACK_TTL = 30 * 60
const NOTE_TTL = 3600
const WRITER_WINDOW = 2 * 3600
const PS_TTL = 60
const LEASE_IDLE = 10 * 60
const NONE: Config = { resources: [] }
// The lease scripts: each is one step in the shell. TAKE moves a lock aside only while it still holds the text
// the caller read, then makes it; RELEASE removes it only while it holds the caller's own text.
const TAKE = 'd="$1"; if [ -d "$d" ] && [ "$(cat "$d/holder.json" 2>/dev/null)" = "$2" ]; then mv "$d" "$d.$$" && rm -rf "$d.$$"; fi; ' +
  'mkdir "$d" 2>/dev/null && printf %s "$3" > "$d/holder.json"'
const RELEASE = '[ "$(cat "$1/holder.json" 2>/dev/null)" = "$2" ] && rm -rf "$1"'
const EDITS = new Set(['Edit', 'Write', 'NotebookEdit'])
const READ_ONLY = new Set(['ls', 'cat', 'grep', 'rg', 'find'])
const READ_ONLY_GIT = new Set(['status', 'log', 'diff', 'show'])
const OPAQUE = new Set(['sudo', 'doas', 'su', 'eval', 'watch', 'bash', 'sh', 'zsh', 'dash'])
const NAMES_A_COMMAND = /(^|[\s/])(git|gh|kill|pkill|killall)(\s|$)/
const WRITING_ARGS = new Set(['-delete', '-exec', '-execdir', '-ok', '-okdir'])
const VALUED = new Set(['-t', '--subject', '-b', '--body', '-F', '--body-file', '-R', '--repo', '-A', '--author-email', '--match-head-commit'])
const SIGNAL = /^-(\d+|[A-Z][A-Z0-9]{2,})$/
const NULL_SIGNAL = /^0+$/
const GIT_ENV = { GIT_OPTIONAL_LOCKS: '0' }
// A repository's own config can run a command (core.fsmonitor), so the guard's reads switch those off.
const GIT = ['git', '-c', 'core.fsmonitor=false', '-c', 'core.untrackedCache=false']
const LSTART = /^\s*(\d+)\s+(\d+)\s+(\w{3} \w{3} [ \d]\d \d\d:\d\d:\d\d \d{4})\s+(.*)$/

// --- paths ------------------------------------------------------------------------------------------
export function norm(p: string): string {
  const out: string[] = []
  for (const s of p.split('/')) {
    if (s === '' || s === '.') continue
    if (s === '..') { if (out.length > 0 && out[out.length - 1] !== '..') out.pop(); else if (!p.startsWith('/')) out.push('..') } else out.push(s)
  }
  return p.startsWith('/') ? `/${out.join('/')}` : out.join('/') || '.'
}
const join = (a: string, b: string) => norm(b.startsWith('/') ? b : `${a}/${b}`)
const dirname = (p: string) => { const n = norm(p); const i = n.lastIndexOf('/'); return i <= 0 ? (n.startsWith('/') ? '/' : '.') : n.slice(0, i) }
const basename = (p: string) => p.slice(p.lastIndexOf('/') + 1)
function relpath(p: string, base: string): string {
  const a = p.split('/').filter(Boolean)
  const b = base.split('/').filter(Boolean)
  let i = 0
  while (i < a.length && i < b.length && a[i] === b[i]) i++
  return [...Array<string>(b.length - i).fill('..'), ...a.slice(i)].join('/') || '.'
}

// --- the policy's small readers ---------------------------------------------------------------------
const flags = (a: readonly string[]) => (a.includes('--') ? a.slice(0, a.indexOf('--')) : a).filter(x => x.startsWith('-'))
const operands = (a: readonly string[]) => a.filter(x => !x.startsWith('-'))

// Signal 0 delivers nothing: `kill -0 <pid>` asks whether the process exists. The last signal named wins, as in
// the shell's `kill`; `-s` and `-n` name one for `kill` only (for `pkill` and `killall` they mean other things).
function probes(name: string, a: readonly string[]): boolean {
  let probe = false
  for (let i = 0; i < a.length && a[i] !== '--'; i++) {
    const x = a[i]!
    if (SIGNAL.test(x)) probe = NULL_SIGNAL.test(x.slice(1))
    else if (name === 'kill' && (x === '-s' || x === '-n' || x === '--signal') && i + 1 < a.length) probe = NULL_SIGNAL.test(a[++i]!)
  }
  return probe
}
const has = (a: readonly string[], long: string, short = '') =>
  flags(a).some(x => x === long || (short !== '' && new RegExp(`^-[a-zA-Z]*[${short}]`).test(x)))
const owns = (paths: readonly string[], f: string) => paths.includes(f) || (f.endsWith('/') && paths.some(p => p.startsWith(f)))
const glob = (spec: string) => new RegExp(`^${spec.replace(/[.+^${}()|\\]/g, '\\$&').replace(/\*/g, '.*').replace(/\?/g, '.')}$`)
const covers = (spec: string, f: string) =>
  spec === '.' || f === spec || f.startsWith(`${spec.replace(/\/+$/, '')}/`) || glob(spec).test(f) || (f.endsWith('/') && spec.startsWith(f))
const overlaps = (a: string, b: string) => {
  const [x, y] = [a.replace(/\/+$/, ''), b.replace(/\/+$/, '')]
  return x === y || x.startsWith(`${y}/`) || y.startsWith(`${x}/`)
}
const listing = (files: readonly string[]) => files.slice(0, 3).join(', ') + (files.length > 3 ? ` and ${files.length - 3} more` : '')
const who = (r: Rec, co?: Checkout) => `pid ${r.pid}${co === undefined ? '' : ` on ${co.expected || 'a detached HEAD'}`}`
const prefixed = (words: readonly string[], prefix: string) => {
  const p = prefix.trim().split(/\s+/)
  return p.length <= words.length && p.every((x, i) => (i === 0 ? basename(x) === basename(words[0]!) : x === words[i]))
}

function readOnly(step: Partial<Step>): boolean {
  const w = step.words ?? []
  if (step.writes || w.length === 0) return false
  const [name, args] = [basename(w[0]!), w.slice(1)]
  if (args.some(a => WRITING_ARGS.has(a) || /^(--output|--pre|-fprint|-fls)/.test(a))) return false
  return name === 'git' ? args.length > 0 && READ_ONLY_GIT.has(args[0]!) : READ_ONLY.has(name)
}
const switches = (step: Partial<Step>) => { const w = step.words ?? []; return w.length > 1 && basename(w[0]!) === 'git' && (w[1] === 'switch' || w[1] === 'checkout') }

const CRC = Array.from({ length: 256 }, (_, n) => {
  let c = n
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1
  return c >>> 0
})
function crc32(text: string): string {
  let c = 0xffffffff
  for (const b of new TextEncoder().encode(text)) c = CRC[(c ^ b) & 0xff]! ^ (c >>> 8)
  return ((c ^ 0xffffffff) >>> 0).toString(16).padStart(8, '0')
}

function valid(r: unknown): r is Rec {
  const x = r as Rec
  return typeof x === 'object' && x !== null && !Array.isArray(x) && Number.isInteger(x.pid) && typeof x.start === 'string'
    && typeof x.checkouts === 'object' && x.checkouts !== null && !Array.isArray(x.checkouts)
}

function parseConfig(text: string): Config {
  const j = JSON.parse(text) as { product?: unknown; resources?: unknown }
  const strings = (x: unknown) => (Array.isArray(x) ? x.filter((v): v is string => typeof v === 'string') : [])
  const resources = (Array.isArray(j.resources) ? j.resources : []).flatMap((r: Record<string, unknown> | null): Resource[] =>
    typeof r?.key === 'string' && (r.kind === 'shared' || r.kind === 'exclusive')
      ? [{ key: r.key, kind: r.kind, start: strings(r.start), stop: strings(r.stop), tools: strings(r.tools) }]
      : [])
  return { product: typeof j.product === 'string' && j.product !== '' ? j.product : undefined, resources }
}

function holder(text: string): Holder | undefined {
  try {
    const h = JSON.parse(text) as Holder
    return Number.isInteger(h.pid) && typeof h.start === 'string' && typeof h.last === 'number' ? h : undefined
  } catch {
    return undefined
  }
}

class Halt extends Error {}

// One module load's view of the record store: the Claude pid, start times read in the last minute, and
// records already read, re-read when the directory lists them changed. Calls run one at a time.
export class Peers {
  private claude: number | undefined
  private ps = new Map<number, { start: string | undefined; at: number }>()
  private cache = new Map<string, { key: string; rec: Rec }>()
  private configs = new Map<string, { key: string | undefined; config: Config }>()
  private user: string | undefined
  private swept = 0
  private queue: Promise<unknown> = Promise.resolve()

  constructor(private readonly w: World) {}

  private serial<T>(f: () => Promise<T>): Promise<T> {
    const run = this.queue.then(f, f)
    this.queue = run.catch(() => undefined)
    return run
  }

  private now() { return Math.floor(this.w.now() / 1000) }

  // --- processes ----------------------------------------------------------------------------------------
  // pid -> (ppid, name) of every process; the start times it reads are kept like any other.
  async table(): Promise<Map<number, { ppid: number; name: string }>> {
    const out = (await this.w.run(['ps', '-A', '-o', 'pid=,ppid=,lstart=,comm='], { env: { LC_ALL: 'C' } })).stdout
    const table = new Map<number, { ppid: number; name: string }>()
    const at = this.now()
    for (const line of out.split('\n')) {
      const m = LSTART.exec(line)
      if (m === null) continue
      table.set(Number(m[1]), { ppid: Number(m[2]), name: basename(m[4]!.trim()) })
      this.ps.set(Number(m[1]), { start: m[3], at })
    }
    return table
  }

  // pid -> its start time, undefined once it is gone; read by `ps` at most once a minute per pid.
  async starts(pids: readonly number[]): Promise<Map<number, string | undefined>> {
    const at = this.now()
    const need = [...new Set(pids)].filter(p => { const e = this.ps.get(p); return e === undefined || (at - e.at >= PS_TTL && p !== this.claude) })
    if (need.length > 0) {
      const out = (await this.w.run(['ps', '-o', 'pid=,ppid=,lstart=,comm=', '-p', need.join(',')], { env: { LC_ALL: 'C' } })).stdout
      const found = new Map<number, string>()
      for (const line of out.split('\n')) {
        const m = LSTART.exec(line)
        if (m !== null) found.set(Number(m[1]), m[3]!)
      }
      for (const p of need) this.ps.set(p, { start: found.get(p), at })
    }
    return new Map(pids.map(p => [p, this.ps.get(p)?.start]))
  }

  private async live(recs: readonly Rec[]): Promise<Set<Rec>> {
    const run = await this.starts(recs.map(r => r.pid))
    return new Set(recs.filter(r => run.get(r.pid) === r.start))
  }

  // This session's Claude process, read once: the outermost `claude` above the module's own child, as a
  // nested `claude -p` belongs to its parent. A parent that is not a `claude` (a stand-in) is itself.
  async pid(): Promise<number | undefined> {
    if (this.claude !== undefined) return this.claude
    const given = Number((await this.w.run(['/bin/sh', '-c', 'echo $PPID'])).stdout.trim())
    const table = await this.table()
    if (!table.has(given)) return undefined
    const isClaude = (p: number) => /^claude(\.exe)?$/.test(table.get(p)!.name)
    let top = given
    const seen = new Set<number>()
    for (let p = given; table.has(p) && !seen.has(p) && isClaude(given); p = table.get(p)!.ppid) {
      seen.add(p)
      if (isClaude(p)) top = p
    }
    this.claude = top
    return top
  }

  // --- checkouts ----------------------------------------------------------------------------------------
  private async gitdir(top: string): Promise<string | undefined> {
    const st = await this.w.stat(`${top}/.git`)
    if (st === undefined) return undefined
    if (st.kind === 'dir') return `${top}/.git`
    const line = (await this.w.read(`${top}/.git`).catch(() => '')).split('\n')[0]!
    return line.startsWith('gitdir:') ? join(top, line.slice(7).trim()) : undefined
  }

  // (toplevel, common dir) of the checkout holding d, read from the files: the first directory up holding
  // `.git`, and the common directory a worktree's git directory points to.
  async where(d: string): Promise<Where | undefined> {
    let x = norm(d)
    let st = await this.w.stat(x)
    while (st?.kind !== 'dir') {
      if (x === '/') return undefined
      x = dirname(x)
      st = await this.w.stat(x)
    }
    let top = st.realPath ?? x
    for (;;) {
      let gd = await this.gitdir(top)
      if (gd !== undefined) {
        const common = await this.w.read(`${gd}/commondir`).catch(() => undefined)
        if (common !== undefined) gd = join(gd, common.trim())
        return [top, (await this.w.stat(gd))?.realPath ?? gd]
      }
      if (top === '/') return undefined
      top = dirname(top)
    }
  }

  // Where a path lands, every link resolved, for a path that need not exist yet.
  async real(p: string): Promise<string> {
    const st = await this.w.stat(p)
    if (st?.realPath !== undefined) return st.realPath
    const up = dirname(p)
    return up === p ? p : join(await this.real(up), basename(p))
  }

  async branch(top: string, fallback = ''): Promise<string> {
    const gd = await this.gitdir(top)
    const head = gd === undefined ? undefined : await this.w.read(`${gd}/HEAD`).catch(() => undefined)
    return head?.trim().startsWith('ref: refs/heads/') ? head.trim().slice('ref: refs/heads/'.length) : fallback
  }

  // A resources file, read again only when its mtime or size changed; one that is missing or unreadable declares nothing.
  private async config(path: string): Promise<Config> {
    const st = await this.w.stat(path)
    if (st === undefined) return NONE
    const key = st.mtimeMs === undefined ? undefined : `${st.mtimeMs}:${st.size}`
    const hit = this.configs.get(path)
    if (hit !== undefined && key !== undefined && hit.key === key) return hit.config
    let config = NONE
    try {
      config = parseConfig(await this.w.read(path))
    } catch { /* declares nothing */ }
    this.configs.set(path, { key, config })
    return config
  }

  private async product(top: string): Promise<string | undefined> {
    return (await this.config(`${top}/.claude/cc-tuner-resources.json`)).product
  }

  // The resources that apply at a checkout, with whether each is the machine's.
  async rules(top: string | undefined): Promise<[Resource, boolean][]> {
    const repo = top === undefined ? NONE : await this.config(`${top}/.claude/cc-tuner-resources.json`)
    const machine = await this.config(this.user ??= await this.w.config())
    return [...repo.resources.map(r => [r, false] as [Resource, boolean]), ...machine.resources.map(r => [r, true] as [Resource, boolean])]
  }

  private async git(top: string, ...args: string[]): Promise<string | undefined> {
    const r = await this.w.run([...GIT, '-C', top, ...args], { env: GIT_ENV })
    return r.exitCode === 0 ? r.stdout.trim() : undefined
  }

  // --- records ------------------------------------------------------------------------------------------
  async load(): Promise<{ recs: Map<string, Rec>; bad: string[] }> {
    const dir = await this.w.dir()
    const entries = [...await this.w.list(dir).catch(() => [])].sort((a, b) => (a.name < b.name ? -1 : 1))
    const recs = new Map<string, Rec>()
    const bad: string[] = []
    for (const e of entries) {
      if (!e.name.endsWith('.json') || e.name.startsWith('.') || e.kind !== 'file') continue
      const key = `${e.mtimeMs}:${e.size}`
      const hit = this.cache.get(e.name)
      if (hit !== undefined && hit.key === key && e.mtimeMs > 0) { recs.set(e.name, hit.rec); continue }
      try {
        const r: unknown = JSON.parse(await this.w.read(`${dir}/${e.name}`))
        if (!valid(r)) throw new Error(e.name)
        recs.set(e.name, r)
        this.cache.set(e.name, { key, rec: r })
      } catch {
        bad.push(e.name)
      }
    }
    return { recs, bad }
  }

  private async save(name: string, r: Rec) {
    this.cache.delete(name)
    await this.w.write(`${await this.w.dir()}/${name}`, JSON.stringify(r))
  }

  // Once an hour: tombstones untouched for 24 h are removed, and so are merge results that old.
  private async sweep(recs: Map<string, Rec>) {
    const now = this.now()
    if (now - this.swept < NOTE_TTL) return
    this.swept = now
    const live = await this.live([...recs.values()])
    const old = [...recs].filter(([, r]) => !live.has(r) && now - (r.seen ?? 0) > DAY).map(([n]) => n)
    for (const n of old) recs.delete(n)
    await this.w.run(['/bin/sh', '-c', 'cd "$1" || exit 0; shift; rm -f -- "$@"; find merge -type f -mmin +1440 -exec rm -f {} + 2>/dev/null; exit 0',
      'sh', await this.w.dir(), ...old])
  }

  private mine(recs: Map<string, Rec>, pid: number, start: string | undefined): [string, Rec] | undefined {
    return [...recs].find(([, r]) => r.pid === pid && r.start === start)
  }

  // This session's record: the one of its process, else the tombstone of its session_id (resume adopts it),
  // else a new one.
  private async session(recs: Map<string, Rec>, pid: number, sid: string | null): Promise<[string, Rec]> {
    const start = (await this.starts([pid])).get(pid) ?? ''
    let found = this.mine(recs, pid, start)
    if (found === undefined && sid !== null) {
      const same = [...recs].filter(([, t]) => t.session_id === sid)
      const live = await this.live(same.map(([, t]) => t))
      found = same.find(([, t]) => !live.has(t))
      if (found !== undefined) Object.assign(found[1], { pid, start })
    }
    if (found !== undefined) return found
    const base = (sid ?? '').replace(/[^A-Za-z0-9_.-]/g, '_').replace(/^\.+/, '') || `p${pid}`
    const name = recs.has(`${base}.json`) ? `${base}-${pid}.json` : `${base}.json`
    const r: Rec = { session_id: sid, pid, start, seen: this.now(), claims: {}, acks: {}, kept: [], checkouts: {} }
    recs.set(name, r)
    return [name, r]
  }

  private async touch(r: Rec, [top, common]: Where): Promise<Checkout> {
    r.seen = this.now()
    return (r.checkouts[top] ??= { repo: common, expected: await this.branch(top), writer: null, paths: [] })
  }

  // --- peers --------------------------------------------------------------------------------------------
  // The live sessions next to `here` (same repository, or a repository of the same product), with the
  // checkouts that make them so.
  async peers(recs: Map<string, Rec>, me: string | undefined, here: Where): Promise<[Rec, [string, Checkout][]][]> {
    const product = await this.product(here[0])
    const found: [Rec, [string, Checkout][]][] = []
    for (const [n, r] of recs) {
      if (n === me) continue
      const cos: [string, Checkout][] = []
      for (const [top, co] of Object.entries(r.checkouts).sort(([a], [b]) => (a < b ? -1 : 1))) {
        if (co.repo === here[1] || (product !== undefined && await this.product(top) === product)) cos.push([top, co])
      }
      if (cos.length > 0) found.push([r, cos])
    }
    const live = await this.live(found.map(([r]) => r))
    return found.filter(([r]) => live.has(r))
  }

  // merge-tree of the two commits in a temporary object directory in front of the repository's own store,
  // so its result objects never reach the repository; cached per SHA pair.
  private async conflicts(top: string, common: string, mine: string, theirs: string): Promise<string[] | undefined> {
    const cache = `${await this.w.dir()}/merge/${mine}-${theirs}`
    try {
      return JSON.parse(await this.w.read(cache)) as string[]
    } catch { /* not cached yet */ }
    const r = await this.w.run(['/bin/sh', '-c',
      'd=$(mktemp -d "$1/.objects.XXXXXX") || exit 2; GIT_OBJECT_DIRECTORY="$d" GIT_ALTERNATE_OBJECT_DIRECTORIES="$2/objects" ' +
      'git -c core.fsmonitor=false -c core.untrackedCache=false -C "$3" merge-tree --write-tree --name-only "$4" "$5"; rc=$?; rm -rf "$d"; exit $rc',
    'sh', await this.w.dir(), common, top, mine, theirs], { env: GIT_ENV })
    if (r.exitCode !== 0 && r.exitCode !== 1) return undefined
    const names = r.stdout.split('\n\n')[0]!.split('\n').slice(1).filter(Boolean)
    await this.w.write(cache, JSON.stringify(names))
    return names
  }

  // The records, and this session's own among them.
  private view() {
    return this.serial(async () => {
      const { recs, bad } = await this.load()
      await this.sweep(recs)
      const pid = await this.pid()
      const start = pid === undefined ? undefined : (await this.starts([pid])).get(pid)
      const [name, me] = (pid === undefined ? undefined : this.mine(recs, pid, start)) ?? [undefined, undefined]
      return { recs, bad, name, me }
    })
  }

  async report(dir: string): Promise<string> {
    const here = await this.where(dir)
    if (here === undefined) return 'cc-tuner: not in a git repository'
    const { recs, bad, name, me } = await this.view()
    const lines = bad.map(n => `note: skipped malformed record ${n}`)
    const found = await this.peers(recs, name, here)
    if (found.length === 0) return [...lines, 'no live peers'].join('\n')
    const mineSha = await this.git(here[0], 'rev-parse', 'HEAD')
    const myClaims = Object.values(me?.claims ?? {}).filter(c => c.repo === here[1]).flatMap(c => c.paths)
    lines.push(`${found.length} live peer${found.length === 1 ? '' : 's'}`)
    for (const [r, cos] of found) {
      for (const [top, co] of cos) {
        lines.push(`pid ${r.pid}  ${await this.branch(top, co.expected) || '(detached)'}  ${top}`)
        const theirs = Object.values(r.claims).filter(c => c.repo === co.repo).flatMap(c => c.paths)
        if (theirs.length > 0) lines.push(`  claims: ${theirs.join(', ')}`)
        if (co.paths.length > 0) lines.push(`  edited: ${co.paths.join(', ')}`)
        if (co.repo !== here[1]) continue
        const sha = mineSha === undefined ? undefined : await this.git(top, 'rev-parse', 'HEAD')
        if (mineSha !== undefined && sha !== undefined && sha !== mineSha) {
          const names = await this.conflicts(here[0], here[1], mineSha, sha)
          if (names === undefined) lines.push('  conflicts with HEAD: not computed (merge-tree failed)')
          else if (names.length > 0) lines.push(`  conflicts with HEAD: ${names.join(', ')}`)
        }
        const both = myClaims.flatMap(a => [...theirs, ...co.paths].filter(b => overlaps(a, b)).map(b => `${a} ~ ${b}`))
        if (both.length > 0) lines.push(`  overlap with your claims: ${both.join(', ')}`)
      }
    }
    return lines.join('\n')
  }

  // Publishes the open Owned paths of a plan as this session's claim, then reports their overlap.
  async claim(cwd: string, sid: string | null, plan: string): Promise<string> {
    const path = join(cwd, plan)
    const here = await this.where(dirname(path))
    if (here === undefined) return 'cc-tuner: not in a git repository'
    const text = await this.w.read(path).catch(() => undefined)
    if (text === undefined) return `cc-tuner: cannot read ${plan}`
    const paths = ownedOpen(text)
    const key = relpath(await this.real(path), here[0])
    const claimed = await this.serial(async () => {
      const { recs } = await this.load()
      const pid = await this.pid()
      if (pid === undefined) return false
      const [name, r] = await this.session(recs, pid, sid)
      await this.touch(r, here)
      if (paths.length > 0) r.claims[key] = { repo: here[1], paths }
      else delete r.claims[key]
      await this.save(name, r)
      return true
    })
    return claimed ? this.report(dirname(path)) : 'cc-tuner: no Claude process found for this session'
  }

  // --- resources ----------------------------------------------------------------------------------------
  // The other live sessions that use a shared resource, as `who` names them: those next to `at`, or every
  // one for the machine's.
  async users(recs: Map<string, Rec>, me: string | undefined, at: Where | undefined, machine: boolean): Promise<string[]> {
    if (!machine && at !== undefined) return (await this.peers(recs, me, at)).map(([r, cos]) => who(r, cos[0]![1]))
    const others = [...recs].filter(([n]) => n !== me).map(([, r]) => r)
    const live = await this.live(others)
    return others.filter(r => live.has(r)).map(r => who(r, Object.values(r.checkouts)[0]))
  }

  // The shared resource a command starts, and the checkout it ran in, when it starts one.
  async started(steps: readonly Step[], cwd: string): Promise<{ key: string; top: string | undefined } | undefined> {
    for (const st of steps) {
      const top = (await this.where(join(cwd, st.dir)))?.[0]
      for (const [res] of await this.rules(top)) {
        if (res.kind === 'shared' && res.start.some(p => prefixed(st.words, p))) return { key: res.key, top }
      }
    }
    return undefined
  }

  // Why a task that started a shared resource must not be stopped now, or undefined when it may be.
  async taskStop(task: string, key: string, top: string | undefined): Promise<string | undefined> {
    const { recs, name } = await this.view()
    const rule = (await this.rules(top)).find(([r]) => r.kind === 'shared' && r.key === key)
    if (rule === undefined) return undefined
    const [user] = await this.users(recs, name, top === undefined ? undefined : await this.where(top), rule[1])
    return user === undefined ? undefined
      : `cc-tuner: task ${task} runs ${key}, which ${user} also uses. Wait until it is done, or SendMessage it when that tool is available.`
  }

  // The tasks this session keeps running through /clear, for the next start line.
  async keep(tasks: string[]) {
    await this.serial(async () => {
      const { recs } = await this.load()
      const pid = await this.pid()
      const own = pid === undefined ? undefined : this.mine(recs, pid, (await this.starts([pid])).get(pid))
      if (own === undefined) return
      own[1].kept = tasks
      await this.save(...own)
    })
  }

  private async self(): Promise<[pid: number, start: string] | undefined> {
    const pid = await this.pid()
    return pid === undefined ? undefined : [pid, (await this.starts([pid])).get(pid) ?? '']
  }

  private async lock(key: string) { return `${await this.w.dir()}/lease.${key.replace(/[^A-Za-z0-9_.-]/g, '_')}` }

  // What a lock's holder file says, without a trailing newline: the shell compares it as `$(cat …)` does.
  private async held(lock: string) { return (await this.w.read(`${lock}/holder.json`).catch(() => '')).replace(/\n+$/, '') }

  // The lease of every exclusive resource this tool belongs to: the first call takes it, the holder keeps it.
  async lease(tool: string, cwd: string, sid: string | null): Promise<Verdict> {
    const hits = (await this.rules((await this.where(cwd))?.[0])).filter(([r]) => r.kind === 'exclusive' && r.tools.some(t => glob(t).test(tool)))
    if (hits.length === 0) return { decision: 'allow' }
    return this.serial(async () => {
      const me = await this.self()
      if (me === undefined) return { decision: 'allow' }
      const notes: string[] = []
      for (const [{ key }] of hits) {
        const v = await this.hold(key, me, sid)
        if (v.decision === 'stop') return v
        if (v.reason !== undefined) notes.push(v.reason)
      }
      return notes.length > 0 ? { decision: 'note', reason: notes.join(' ') } : { decision: 'allow' }
    })
  }

  private async hold(key: string, [pid, start]: [number, string], sid: string | null): Promise<Verdict> {
    const lock = await this.lock(key)
    const [text, st] = [await this.held(lock), await this.w.stat(lock)]
    const [cur, now] = [holder(text), this.now()]
    const mine = JSON.stringify({ key, pid, start, session: sid, last: now })
    if (cur?.pid === pid && cur.start === start) {
      await this.w.write(`${lock}/holder.json`, mine)
      return { decision: 'allow' }
    }
    if (st !== undefined) {
      // A lock nobody wrote into yet is as old as its directory.
      const last = cur?.last ?? Math.floor((st.mtimeMs ?? now * 1000) / 1000)
      const gone = cur !== undefined && (await this.starts([cur.pid])).get(cur.pid) !== cur.start
      if (!gone && now - last < LEASE_IDLE) return this.leased(key, cur, now)
    }
    const r = await this.w.run(['/bin/sh', '-c', TAKE, 'sh', lock, text, mine])
    if (r.exitCode !== 0) return this.leased(key, holder(await this.held(lock)), now)
    return { decision: 'note', reason: `cc-tuner: you hold ${key}; release it with peers_release when you are done.` }
  }

  private leased(key: string, h: Holder | undefined, now: number): Verdict {
    const by = h === undefined ? 'another session' : `pid ${h.pid}, used ${now - h.last} s ago`
    return { decision: 'stop', reason: `cc-tuner: ${key} is leased to ${by}. Wait for it, or SendMessage it when that tool is available.` }
  }

  // Frees the lease only for its holder, checked against the holder file the shell removes it under.
  async release(key: string): Promise<string> {
    const refused = `cc-tuner: ${key} is not leased to this session.`
    return this.serial(async () => {
      const [me, lock] = [await this.self(), await this.lock(key)]
      const text = await this.held(lock)
      const cur = holder(text)
      if (me === undefined || cur?.pid !== me[0] || cur.start !== me[1]) return refused
      return (await this.w.run(['/bin/sh', '-c', RELEASE, 'sh', lock, text])).exitCode === 0 ? `cc-tuner: released ${key}.` : refused
    })
  }

  // --- the guard ----------------------------------------------------------------------------------------
  // One event: update this session's record and answer allow, note or stop. A stopped call marks no writer.
  async check(ev: Event): Promise<Verdict & { line?: string }> {
    const sid = ev.session_id || null
    const target = ev.path ? join(ev.cwd, ev.path) : undefined
    const here = await this.where(target !== undefined ? dirname(target) : ev.cwd)
    const plan: { st: Partial<Step>; writes: boolean; switch: boolean; blind: boolean; at: Where | undefined; d: string }[] = []
    if (ev.phase === 'before' && ev.tool === 'Bash') {
      for (const st of ev.steps ?? [{} as Partial<Step>]) {
        const blind = st.dir === UNKNOWN
        const d = join(ev.cwd, blind ? '' : st.dir ?? '')
        const [writes, sw] = [!readOnly(st), switches(st)]
        plan.push({ st, writes, switch: sw, blind: blind && writes, at: !blind && (writes || sw) ? await this.where(d) : undefined, d })
      }
    }
    if ((here === undefined && !plan.some(p => p.at !== undefined)) || (sid === null && ev.phase === 'start')) return { decision: 'allow', line: '' }
    return this.serial(async () => {
      const { recs } = await this.load()
      await this.sweep(recs)
      const pid = await this.pid()
      if (pid === undefined) return { decision: 'allow', line: '' }
      const now = this.now()
      if (ev.phase === 'start') {
        const own = this.mine(recs, pid, (await this.starts([pid])).get(pid))
        if (own !== undefined && own[1].session_id !== sid) Object.assign(own[1], { session_id: sid, acks: {}, claims: {} })
      }
      const [name, r] = await this.session(recs, pid, sid)
      const co = here === undefined ? undefined : await this.touch(r, here)
      for (const { at } of plan) if (at !== undefined) await this.touch(r, at)
      for (const k of ev.acks ?? []) r.acks[k] = now
      let verdict: Verdict = { decision: 'allow' }
      if (ev.phase === 'before') verdict = await new Guard(this, recs, name, r, pid, here, now).judge(ev, plan, target)
      const seen: Record<string, string> = {}
      if (verdict.decision !== 'stop') {
        for (const { at, writes, switch: sw } of plan) {
          if (at !== undefined && writes) r.checkouts[at[0]]!.writer = now
          if (at !== undefined && sw) seen[at[0]] = await this.branch(at[0])
        }
        if (ev.phase === 'after' && ev.tool !== undefined && EDITS.has(ev.tool) && ev.ok !== false && target !== undefined && here !== undefined && co !== undefined) {
          const rel = relpath(await this.real(target), here[0])
          if (!co.paths.includes(rel)) co.paths.push(rel)
          co.writer = now
        }
        if (ev.phase === 'after' && ev.tool === 'Bash') {
          for (const [top, old] of Object.entries(ev.seen ?? {})) {
            const head = await this.branch(top)
            if (r.checkouts[top] !== undefined && head !== '' && head !== old) r.checkouts[top].expected = head
          }
        }
      }
      r.acks = Object.fromEntries(Object.entries(r.acks).filter(([, t]) => now - t < NOTE_TTL))
      await this.save(name, r)
      const out: Verdict & { line?: string } = { ...verdict }
      if (Object.keys(seen).length > 0) out.seen = seen
      if (ev.phase === 'start' && here !== undefined) out.line = await this.startLine(recs, name, r, here)
      return out
    })
  }

  private async startLine(recs: Map<string, Rec>, name: string, r: Rec, here: Where): Promise<string> {
    const parts: string[] = []
    const peers: string[] = []
    for (const [p, cos] of await this.peers(recs, name, here)) {
      for (const [top, co] of cos) peers.push(`${await this.branch(top, co.expected) || 'detached'} (${basename(top)}, pid ${p.pid})`)
    }
    if (peers.length > 0) parts.push(`live peers: ${peers.join(', ')}`)
    if (r.kept.length > 0) parts.push(`kept at /clear: ${r.kept.join(', ')}`)
    return parts.length === 0 ? '' : `cc-tuner: ${parts.join('; ')}. More: the peers_report tool.`
  }

  async status(top: string, staged: readonly string[]): Promise<[string, string, string][]> {
    const out = (await this.w.run([...GIT, '-C', top, 'status', '--porcelain=v1', '-z'], { env: GIT_ENV })).stdout.split('\0')
    let found: [string, string, string][] = []
    for (let i = 0; i < out.length; i++) {
      const e = out[i]!
      if (e.length > 3) {
        found.push([e[0]!, e[1]!, e.slice(3)])
        if ('RC'.includes(e[0]!)) i++
      }
    }
    for (const p of staged) found = [...found.filter(e => e[2] !== p), ['A', ' ', p]]
    return found
  }

  async pidsOf(argv: readonly string[]): Promise<number[] | undefined> {
    try {
      const r = await this.w.run(argv)
      return r.exitCode > 1 ? undefined : r.stdout.split(/\s+/).filter(x => /^\d+$/.test(x)).map(Number)
    } catch {
      return undefined
    }
  }

  isDir = async (p: string) => (await this.w.stat(p))?.kind === 'dir'
}

// The open slices' Owned paths of a plan, in plan order: a slice is open while one of its criteria is not
// ticked, or it has none.
export function ownedOpen(text: string): string[] {
  const slices: { owned: string[]; total: number; done: number }[] = []
  for (const line of text.split('\n')) {
    if (/^##[ \t]+Slice[ \t]+\d+/.test(line)) slices.push({ owned: [], total: 0, done: 0 })
    const cur = slices[slices.length - 1]
    if (cur === undefined) continue
    const owned = /^[ \t]*Owned paths[ \t]*:(.*)$/.exec(line)
    if (owned !== null) cur.owned = owned[1]!.split(',').map(p => p.trim()).filter(Boolean)
    const box = /^[ \t]*-[ \t]*\[([ xX])\]/.exec(line)
    if (box !== null) { cur.total++; if (box[1] !== ' ') cur.done++ }
  }
  const paths: string[] = []
  for (const s of slices) if (s.total === 0 || s.done < s.total) for (const p of s.owned) if (!paths.includes(p)) paths.push(p)
  return paths
}

// One call's decisions: a stop throws Halt, a note is kept and the call goes on.
class Guard {
  private notes: string[] = []
  private moved = new Set<string>()
  private staged = new Map<string, string[]>()

  constructor(private readonly p: Peers, private readonly recs: Map<string, Rec>, private readonly name: string,
    private readonly r: Rec, private readonly pid: number, private readonly here: Where | undefined, private readonly now: number) {}

  async judge(ev: Event, plan: { st: Partial<Step>; blind: boolean; at: Where | undefined; d: string }[], target: string | undefined): Promise<Verdict> {
    try {
      if (ev.tool === 'Bash') {
        let prev: string[] = []
        for (const { st, at, d, blind } of plan) {
          const w = st.words ?? []
          if (w.length > 0) await this.step(w, at, d, prev, blind)
          prev = w
        }
      } else if (target !== undefined && this.here !== undefined) {
        await this.edit(this.here, relpath(await this.p.real(target), this.here[0]))
      }
    } catch (err) {
      if (err instanceof Halt) return { decision: 'stop', reason: err.message }
      throw err
    }
    return this.notes.length > 0 ? { decision: 'note', reason: this.notes.join(' ') } : { decision: 'allow' }
  }

  private peers(at: Where) { return this.p.peers(this.recs, this.name, at) }
  private note(text: string) { this.notes.push(`cc-tuner: ${text}`) }

  private once(key: string, text: string) {
    if (this.now - (this.r.acks[key] ?? 0) >= NOTE_TTL) {
      this.r.acks[key] = this.now
      this.note(text)
    }
  }

  private stop(action: string, target: string, text: string) {
    const k = crc32(`${action}|${target}`)
    if (this.now - (this.r.acks[k] ?? 0) >= ACK_TTL) {
      throw new Halt(`cc-tuner: ${text} To go on, run the same command prefixed CC_TUNER_ACK=${k}. ` +
        'Re-running it is your choice, not a question for the user.')
    }
  }

  // git and gh act on the checkout of their directory; rm and kill reach past it, so outside a repository
  // they are read from the cwd's.
  private async step(w: string[], at: Where | undefined, d: string, prev: string[], blind: boolean) {
    const name = basename(w[0]!)
    const scope = at ?? this.here
    await this.shared(w, at)
    if (blind && (name === 'git' || name === 'gh' || name === 'rm')) this.note(`could not read the directory of \`${w.join(' ').slice(0, 60)}\`; if a peer works there, check first.`)
    else if (name === 'git' && at !== undefined) await this.git(w, at, d)
    else if (name === 'gh' && at !== undefined) await this.gh(w, at)
    else if (name === 'kill' || name === 'pkill' || name === 'killall') { if (scope !== undefined) await this.kill(name, w.slice(1), scope, prev) }
    else if (name === 'rm' && has(w.slice(1), '--recursive', 'rR')) { if (scope !== undefined) await this.remove(scope, d, w.join(' ').slice(0, 60), operands(w.slice(1))) }
    else if (OPAQUE.has(name) && NAMES_A_COMMAND.test(w.slice(1).join(' '))) this.note(`could not read \`${w.join(' ').slice(0, 60)}\`; if a peer works here, check first.`)
  }

  // A shared resource's stop command, while another session uses the resource.
  private async shared(w: string[], at: Where | undefined) {
    for (const [res, machine] of await this.p.rules(at?.[0])) {
      if (res.kind !== 'shared' || !res.stop.some(p => prefixed(w, p))) continue
      const [user] = await this.p.users(this.recs, this.name, at, machine)
      if (user !== undefined) this.stop('stop', res.key, `\`${w.join(' ').slice(0, 60)}\` would stop ${res.key}, which ${user} also uses.`)
    }
  }

  private async git(w: string[], at: Where, d: string) {
    const top = at[0]
    if (w.length < 2) return
    const [sub, a, label] = [w[1]!, w.slice(2), w.join(' ').slice(0, 60)]
    const after = a.includes('--') ? a.slice(a.indexOf('--') + 1) : undefined
    if (sub.startsWith('-')) {
      this.note(`could not read \`${label}\`; if a peer works in ${top}, check first.`)
    } else if (sub === 'checkout' && (a.includes('--') || a.includes('.'))) {
      await this.lose(at, d, label, 'checkout', 'overwrite', 'tracked', after ?? ['.'])
    } else if (sub === 'switch' || sub === 'checkout') {
      await this.switch(at)
      this.moved.add(top)
    } else if (sub === 'reset' && a.includes('--hard')) {
      await this.lose(at, d, label, 'reset', 'discard', 'tracked')
    } else if (sub === 'stash') {
      const op = a.length > 0 && !a[0]!.startsWith('-') ? a[0] : 'push'
      if (op === 'drop' || op === 'clear') await this.stashDrop(at, label)
      else if (op === 'push' || op === 'save') {
        const wide = has(a, '--include-untracked', 'u') || has(a, '--all', 'a')
        await this.lose(at, d, label, 'stash', 'stash away', wide ? 'all' : 'tracked', after)
      }
    } else if (sub === 'clean' && !has(a, '--dry-run', 'n')) {
      await this.lose(at, d, label, 'clean', 'delete', 'untracked', operands(a).length > 0 ? operands(a) : ['.'])
    } else if (sub === 'restore') {
      await this.lose(at, d, label, 'restore', 'overwrite', 'tracked', operands(a))
    } else if (sub === 'commit') {
      await this.drift(at, label, 'commit')
      await this.lose(at, d, label, 'commit', 'commit', has(a, '--all', 'a') ? 'tracked' : 'staged')
    } else if (sub === 'add') {
      const args = operands(a)
      const wide: string[] = []
      for (const x of args) if (x === '.' || /[*?[]/.test(x) || await this.p.isDir(join(d, x))) wide.push(x)
      const staged = this.staged.get(top) ?? []
      for (const x of args) if (!wide.includes(x)) staged.push(relpath(await this.p.real(join(d, x)), top))
      this.staged.set(top, staged)
      if (has(a, '--all', 'A')) await this.lose(at, d, label, 'add', 'stage', 'all')
      else if (has(a, '--update', 'u')) await this.lose(at, d, label, 'add', 'stage', 'tracked', args.length > 0 ? args : undefined)
      else if (wide.length > 0) await this.lose(at, d, label, 'add', 'stage', 'all', wide)
    } else if (sub === 'push') {
      await this.drift(at, label, 'push')
      if (has(a, '--delete', 'd')) await this.delete(at, operands(a).slice(1), label)
      await this.delete(at, operands(a).filter(x => x.startsWith(':')).map(x => x.slice(1)), label)
    } else if (sub === 'branch' && has(a, '--delete', 'dD')) {
      await this.delete(at, operands(a), label)
    } else if (sub === 'worktree' && a[0] === 'remove') {
      await this.remove(at, d, label, operands(a.slice(1)))
    }
  }

  private async gh(w: string[], at: Where) {
    if (w.length < 3 || w[1] !== 'pr' || (w[2] !== 'create' && w[2] !== 'merge')) return
    const label = w.join(' ').slice(0, 60)
    await this.drift(at, label, `gh pr ${w[2]}`)
    if (w[2] !== 'merge' || !has(w.slice(3), '--delete-branch', 'd')) return
    const sel: string[] = []
    let skip = false
    for (const x of w.slice(3)) {
      if (skip) skip = false
      else if (VALUED.has(x)) skip = true
      else if (!x.startsWith('-')) sel.push(x)
    }
    if (sel.length === 0) await this.delete(at, [await this.p.branch(at[0])], label)
    else if (/^\d+$|^https?:\/\//.test(sel[0]!)) this.note(`\`${label}\` deletes a branch it does not name; if a peer works on it, check first.`)
    else await this.delete(at, [sel[0]!], label)
  }

  private async switch(at: Where) {
    const top = at[0]
    const here = (await this.peers(at)).flatMap(([r, cos]) => cos.filter(([t]) => t === top).map(([, co]) => [r, co] as const))
    const busy = here.filter(([, co]) => co.writer !== null && this.now - co.writer < WRITER_WINDOW)
    if (busy.length > 0) this.stop('switch', top, `${who(...busy[0]!)} works in ${top}; switching branches there changes its files.`)
    else if (here.length > 0) this.note(`${who(...here[0]!)} has its cwd in ${top}; switching branches there changes its files.`)
  }

  private async drift(at: Where, label: string, action: string) {
    const top = at[0]
    const [head, want] = [await this.p.branch(top), this.r.checkouts[top]!.expected]
    if (!this.moved.has(top) && head !== want) {
      this.stop(`${action} on ${top}`, top, `\`${label}\` would run on ${head || 'a detached HEAD'} in ${top}, not on ${want || 'a detached HEAD'}, ` +
        'where this session started; someone else switched it.')
    }
  }

  // The changed files of a checkout this session did not edit, within the paths a command reaches.
  private async foreign(top: string, kinds: string, specs: readonly string[] | undefined, d: string): Promise<string[]> {
    const mine = this.r.checkouts[top]?.paths ?? []
    const reach = specs === undefined ? undefined : await Promise.all(specs.map(async x => relpath(await this.p.real(join(d, x)), top)))
    return (await this.p.status(top, this.staged.get(top) ?? []))
      .filter(([x]) => !((kinds === 'tracked' && x === '?') || (kinds === 'untracked' && x !== '?') || (kinds === 'staged' && ' ?'.includes(x))))
      .map(([, , f]) => f)
      .filter(f => !owns(mine, f) && (reach === undefined || reach.some(x => covers(x, f))))
  }

  private async owner(top: string, files: string[]): Promise<string> {
    const names = [...this.recs].filter(([n, r]) => n !== this.name && r.checkouts[top] !== undefined
      && files.some(f => owns(r.checkouts[top]!.paths, f)))
    const live = await this.p.starts(names.map(([, r]) => r.pid))
    return names.map(([, r]) => (live.get(r.pid) === r.start ? who(r, r.checkouts[top]!) : `pid ${r.pid}, exited`)).join(', ') || 'unknown owner'
  }

  private async lose(at: Where, d: string, label: string, action: string, verb: string, kinds: string, specs?: readonly string[]) {
    const top = at[0]
    const files = await this.foreign(top, kinds, specs, d)
    if (files.length > 0) this.stop(action, top, `\`${label}\` would ${verb} ${listing(files)} in ${top} (${await this.owner(top, files)}).`)
  }

  private async stashDrop(at: Where, label: string) {
    for (const [r, cos] of await this.peers(at)) {
      for (const [top, co] of cos) {
        if (co.repo === at[1] && co.writer !== null) this.stop('stash drop', at[1], `\`${label}\` would drop a stash that ${who(r, co)} shares, working in ${top}.`)
      }
    }
  }

  private async delete(at: Where, names: readonly string[], label: string) {
    for (const name of names) {
      for (const [r, cos] of await this.peers(at)) {
        for (const [top, co] of cos) {
          if (co.repo === at[1] && co.expected === name) {
            this.stop('delete branch', `${at[1]}:${name}`, `\`${label}\` would delete ${name}, the branch ${who(r, co)} works on in ${top}.`)
          }
        }
      }
    }
  }

  private async remove(at: Where, d: string, label: string, paths: readonly string[]) {
    for (const p of paths) {
      const path = await this.p.real(join(d, p))
      const there = await this.p.where(path)
      for (const [r, cos] of await this.peers(there ?? at)) {
        for (const [top, co] of cos) {
          if (top === path || top.startsWith(`${path}/`)) this.stop('remove', path, `\`${label}\` would remove ${path}, where ${who(r, co)} works.`)
        }
      }
      if (there !== undefined && there[0] === path) {
        const files = await this.foreign(path, 'all', undefined, path)
        if (files.length > 0) this.stop('remove', path, `\`${label}\` would delete ${listing(files)} in ${path} (${await this.owner(path, files)}).`)
      }
    }
  }

  private async kill(name: string, a: string[], at: Where, prev: string[]) {
    if (probes(name, a)) return
    const peers = new Map<number, [Rec, Checkout]>()
    for (const [r, cos] of await this.peers(at)) for (const [, co] of cos) peers.set(r.pid, [r, co])
    if (peers.size === 0) return
    let pids: number[] | undefined
    if (name === 'kill') {
      const named = a.filter(x => /^\d+$/.test(x)).map(Number)
      pids = named.length > 0 ? named : prev[0] === 'lsof' || prev[0] === 'pgrep' ? await this.p.pidsOf(prev) : undefined
    } else if (name === 'pkill') {
      pids = await this.p.pidsOf(['pgrep', ...a.filter(x => !SIGNAL.test(x))])
    } else {
      pids = []
      for (const x of operands(a)) pids.push(...(await this.p.pidsOf(['pgrep', '-x', x]) ?? []))
    }
    const label = [name, ...a].join(' ').slice(0, 60)
    if (pids === undefined) return this.note(`could not tell which process \`${label}\` stops; if a peer's, check first.`)
    const table = await this.p.table()
    for (const pid of pids) {
      let [p, hops] = [pid, 0]
      while (table.has(p) && p > 1 && p !== this.pid && !peers.has(p) && hops < 64) [p, hops] = [table.get(p)!.ppid, hops + 1]
      if (peers.has(p)) this.stop('kill', String(pid), `\`${label}\` would stop process ${pid}, which belongs to ${who(...peers.get(p)!)}.`)
    }
  }

  private async edit(at: Where, rel: string) {
    const [top, common] = at
    for (const [r, cos] of await this.peers(at)) {
      for (const [t, co] of cos) {
        if (t === top && co.writer !== null) this.once(`note:${r.pid}:${top}`, `${who(r, co)} also writes in ${top}; its edits may land next to yours.`)
      }
      for (const [plan, c] of Object.entries(r.claims).sort(([x], [y]) => (x < y ? -1 : 1))) {
        for (const p of c.paths) {
          if (c.repo === common && overlaps(rel, p)) this.once(`note:${r.pid}:${p}`, `${who(r, cos[0]![1])} claims ${p} (${plan}); this edit may conflict with it.`)
        }
      }
    }
  }
}
