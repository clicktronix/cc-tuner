import type { EngineInterface } from 'claude-code'

// Sessions of one product see each other: who is live next to this session, on which branch, claiming and
// editing which paths, and what the guard decides for a call (allow, a note, or a stop with its reason).
//
// One JSON record per Claude session in the record directory (CC_TUNER_PEERS_DIR, default
// ~/.cache/cc-tuner/sessions). A session writes only its own record, one write at a time in this
// process; other records are only read, and one that does not parse or has the wrong shape or version is skipped and
// noted. A session is its Claude process, pid plus start time; a nested `claude -p` is a session of its own, a peer of the
// process that started it. A record whose process is gone, or is another process now, is a tombstone: no
// longer a peer, its edited paths still on disk. A tombstone untouched for 24 h is removed; a resumed
// session with the same session_id adopts it, also in a running process (`/resume`). `/clear` drops acks and claims.
//
//   {v: 1, session_id, pid, start, seen, claims: {<plan>: {repo, paths}}, acks: {<key>: <epoch>}, kept: [{id, key, top}],
//    checkouts: {<toplevel>: {repo, expected, writer, paths}}}
//
// kept are the shared-resource tasks this process started: /clear leaves them running, and so does a reload of the module.
// repo is the git common directory, so worktrees of one repository share it. expected is the branch at
// first touch (any git step touches its checkout, a read-only one too), moved only by this session's own call that held a switch-like step, when HEAD changed during it or
// the step named the branch HEAD holds; writer the epoch of the last call the guard let through that could write
// (marked before it runs); paths what Edit/Write changed. acks also hold the hourly notes. `seen` is the epoch of the
// session's last call of any tool (renewed at most once a minute); a session whose `seen` is 8 h old is idle: it blocks nothing that depends only on its being alive, and its edited paths stay protected.
//
// Resources are declared, not detected: `<toplevel>/.claude/cc-tuner-resources.json` (`product` and `resources`)
// and the machine's own file (CC_TUNER_PEERS_CONFIG, else $XDG_CONFIG_HOME or ~/.config, cc-tuner/resources.json),
// each read again when its mtime changes. `"guard": false` in either turns the guard off there (records and the report
// stay); the machine's `products` maps names to paths (`~` allowed), a repository file's `product` winning. A shared resource (`start` and `stop` command prefixes) is not stopped
// while another session of the product is live; the machine's, while any session is. An exclusive one (`tools`,
// MCP tool-name patterns) is leased to the first session that calls one: a lock directory `lease.<key>` in the
// record directory, made by an atomic `mkdir` that carries {v, key, pid, start, session, last use}. The holder renews it
// at most once a minute; a takeover, a renewal and a release each run under one cross-process mutex and compare the holder
// they read. The lease moves on the holder's `peers_release`, after 10 minutes of its silence, or when its process is gone.
//
// A process runs only for what a decision needs: `ps` (start times kept for a minute), `git status`
// before a command that could lose or commit files (and, limited to one path, before the first edit of it in an
// hour), and the reads `peers_report` and `kill` need. Every git read takes its attributes from the empty tree and ignores
// submodules, so inspecting runs no filter or merge driver of the repository's, the user's or a submodule's.

// A step's directory when a `cd` could not be read: the checkout it acts on is not known.
export const UNKNOWN = '\0'
// op joins a step to the one before it: `&&`, `||`, `;` or `|`, empty for the first.
export interface Step { words: string[]; dir: string; op: string; writes: boolean; scope?: number; config?: string[] }
export interface Event {
  session_id?: string; phase: 'before' | 'after' | 'start'; tool?: string; cwd: string
  path?: string; steps?: Step[]; seen?: Record<string, string>; acks?: string[]; ok?: boolean
}
export interface Resource { key: string; kind: 'shared' | 'exclusive'; start: string[]; stop: string[]; tools: string[] }
interface Config { product?: string; off: boolean; products: Record<string, string[]>; resources: Resource[] }
interface Holder { v: 1; key: string; pid: number; start: string; session: string | null; last: number }
export interface Verdict { decision: 'allow' | 'note' | 'stop'; reason?: string; seen?: Record<string, string> }
export interface Kept { id: string; key: string; top?: string }
// `since` and `found`: when the session first touched the checkout and the files already changed then; absent in a
// record from before them. `mixed`: another session has written there since, or a live one ever did.
interface Checkout { repo: string; expected: string; writer: number | null; paths: string[]; since?: number; found?: string[]; mixed?: boolean }
export interface Rec {
  v: 1; session_id: string | null; pid: number; start: string; seen: number
  claims: Record<string, { repo: string; paths: string[] }>; acks: Record<string, number>; kept: Kept[]
  checkouts: Record<string, Checkout>
  // The session's own Bash calls that may write, as [start ms, end ms], newest last.
  calls?: [number, number][]
}
type Where = readonly [top: string, common: string]

// What the guard reads and runs, from the engine in a session and from a fake in the tests.
export interface World {
  dir: () => Promise<string>
  config: () => Promise<string>
  home: () => Promise<string | undefined>
  read: (path: string) => Promise<string>
  write: (path: string, text: string) => Promise<void>
  list: (dir: string) => Promise<readonly { name: string; kind: string; size: number; mtimeMs: number }[]>
  stat: (path: string) => Promise<{ kind: string; realPath?: string; mtimeMs?: number; size?: number } | undefined>
  run: (argv: readonly string[], init?: { env?: Record<string, string> }) => Promise<{ exitCode: number; stdout: string; isStdoutTruncated?: boolean }>
  now: () => number
}

export function world($: EngineInterface): World {
  return {
    dir: async () => {
      const home = await $.env.get('HOME')
      if (!(await $.env.get('CC_TUNER_PEERS_DIR')) && !home) throw new Error('no HOME and no CC_TUNER_PEERS_DIR')
      return (await $.env.get('CC_TUNER_PEERS_DIR')) || `${home}/.cache/cc-tuner/sessions`
    },
    config: async () => (await $.env.get('CC_TUNER_PEERS_CONFIG')) ||
      `${(await $.env.get('XDG_CONFIG_HOME')) || `${await $.env.get('HOME')}/.config`}/cc-tuner/resources.json`,
    home: () => $.env.get('HOME'),
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
// How many of its own calls a session remembers.
const CALLS = 200
// Whether a writer's mark may be a write after this checkout's first touch. Marks are whole seconds: one taken in the
// second before `since` may belong to a write after it.
const wroteSince = (them: Checkout, me: Checkout) => them.writer !== null && me.since !== undefined && them.writer >= me.since - 1
const CTIMES = 'if stat -f %Fc / >/dev/null 2>&1; then for f; do stat -f %Fc -- "$f" 2>/dev/null || echo -; done; ' +
  'else for f; do stat -c %.9Z -- "$f" 2>/dev/null || echo -; done; fi'
const CALL = '\u0000call'
const IDLE = 8 * 3600
const PS_TTL = 60
const LEASE_RENEW = 60
// Use is written at most once a minute, so ten minutes from the last use is up to a minute more from the last write.
const LEASE_IDLE = 10 * 60 + LEASE_RENEW
const NONE: Config = { off: false, products: {}, resources: [] }
// The lease scripts: each is one step in the shell, and each acts on a lock that exists only under LOCKED, the `.take`
// directory made by an atomic `mkdir` (exit 2 while another caller holds it; one left by a crashed caller goes after a
// minute). TAKE makes the lock with an atomic `mkdir`; a lock that exists is replaced only while it still holds the
// text the caller read (an empty lock only when it is old). RENEW and RELEASE act only while it holds the caller's own
// text, so neither lands on the lock of whoever took it over in between.
const LOCKED = 'find "$d.take" -maxdepth 0 -mmin +1 -exec rmdir {} + 2>/dev/null; mkdir "$d.take" 2>/dev/null || exit 2; trap \'rmdir "$d.take"\' EXIT; '
const TAKE = 'd="$1"; if mkdir "$d" 2>/dev/null; then printf %s "$3" > "$d/holder.json"; exit; fi; ' + LOCKED +
  '[ "$(cat "$d/holder.json" 2>/dev/null)" = "$2" ] && { [ -n "$2" ] || [ -n "$(find "$d" -maxdepth 0 -mmin +9)" ]; } || exit 1; ' +
  'rm -rf "$d" && mkdir "$d" 2>/dev/null && printf %s "$3" > "$d/holder.json"'
const RENEW = 'd="$1"; ' + LOCKED + '[ "$(cat "$d/holder.json" 2>/dev/null)" = "$2" ] && printf %s "$3" > "$d/holder.json" || exit 1'
const RELEASE = 'd="$1"; ' + LOCKED + '[ "$(cat "$d/holder.json" 2>/dev/null)" = "$2" ] && rm -rf "$d" || exit 1'
const SWEEP = 'cd "$1" || exit 0; shift; rm -f -- "$@"; find merge -type f -mmin +1440 -exec rm -f {} + 2>/dev/null; ' +
  'find . -maxdepth 1 -name ".objects.*" -mmin +60 -exec rm -rf {} + 2>/dev/null; exit 0'
// merge-tree in a bare repository of its own. `$1` is the record directory (the temporary repository is `.objects.*`
// there, which SWEEP removes once it is an hour old), `$2` the real repository's common directory.
const ISOLATED_MERGE = 'unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_NAMESPACE GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS ' +
  'GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES; export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1; ' +
  'd=$(mktemp -d "$1/.objects.XXXXXX") || exit 2; o="$2"; m="$3"; n="$4"; shift 4; ' +
  'git init -q --bare --template= "$d" && echo "$o/objects" > "$d/objects/info/alternates" && ' +
  'git "$@" --git-dir="$d" merge-tree --write-tree --name-only -z "$m" "$n"; rc=$?; rm -rf "$d"; exit $rc'
const PS_ENV = { LC_ALL: 'C', TZ: 'UTC' }
const EDITS = new Set(['Edit', 'Write', 'NotebookEdit'])
const READ_ONLY = new Set(['ls', 'cat', 'grep', 'rg', 'find'])
const READ_ONLY_GIT = new Set(['status', 'log', 'diff', 'show'])
const NO_OWNER = 'unknown owner'
const OPAQUE = new Set(['sudo', 'doas', 'su', 'eval', 'watch', 'bash', 'sh', 'zsh', 'dash'])
const NAMES_A_COMMAND = /(^|[\s/])(git|gh|kill|pkill|killall)(\s|$)/
const WRITING_ARGS = new Set(['-delete', '-exec', '-execdir', '-ok', '-okdir'])
const VALUED = new Set(['-t', '--subject', '-b', '--body', '-F', '--body-file', '-R', '--repo', '-A', '--author-email', '--match-head-commit'])
const SIGNAL = /^-(\d+|[A-Z][A-Z0-9]{2,})$/
const NULL_SIGNAL = /^0+$/
// Inspection is inert. The one command a config can start by itself is core.fsmonitor. A clean, smudge or process filter
// runs only when config defines the driver an attribute names, so `status` reads the real attributes (eol and text
// normalisation stay git's) with every filter driver config defines overridden on the command line, which beats every
// config source, an included file too: see `silenced`. A merge driver is the one thing config can select without
// attributes (`merge.default`, a driver named `text`), so merge-tree never runs in the repository: see ISOLATED_MERGE.
const GIT_ENV = { GIT_OPTIONAL_LOCKS: '0', GIT_ATTR_NOSYSTEM: '1' }
const INERT = ['-c', 'core.fsmonitor=false', '-c', 'core.untrackedCache=false', '-c', 'core.attributesFile=/dev/null']
// A command whose output the engine cut off answered nothing complete: it counts as failed.
const TRUNCATED = 124
const USAGE = 129
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
export const join = (a: string, b: string) => norm(b.startsWith("/") ? b : `${a}/${b}`)
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
// A pathspec that is not a literal path (magic such as `:(top)` or `:!`, a glob) cannot be resolved here: it reaches every file.
const unresolved = (spec: string) => spec.startsWith(':') || /[*?[]/.test(spec)
const covers = (spec: string, f: string) =>
  spec === '.' || f === spec || f.startsWith(`${spec.replace(/\/+$/, '')}/`) || (f.endsWith('/') && spec.startsWith(f))
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
// A step that may move HEAD: the ones this session's expected branch follows.
function switches(step: Partial<Step>): boolean {
  const [name, sub, rest] = [basename(step.words?.[0] ?? ''), step.words?.[1], step.words?.slice(2) ?? []]
  return (name === 'git' && (sub === 'switch' || sub === 'checkout' || (sub === 'branch' && has(rest, '--move', 'mM'))))
    || (name === 'gh' && sub === 'pr' && (rest[0] === 'checkout' || rest[0] === 'merge'))
}
// The steps a guard decision is about: a recursive removal, and what git or gh discards, overwrites, deletes, stashes,
// commits, stages or moves a branch of.
function destroys(w: readonly string[]): boolean {
  const [name, sub, a] = [basename(w[0] ?? ''), w[1] ?? '', w.slice(2)]
  if (name === 'rm') return has(w.slice(1), '--recursive', 'rR')
  if (name === 'gh') return sub === 'pr' && (a[0] === 'checkout' || (a[0] === 'merge' && has(a.slice(1), '--delete-branch', 'd')))
  if (name !== 'git') return false
  switch (sub) {
    case 'switch': case 'checkout': case 'restore': case 'commit': case 'add': return true
    case 'reset': return a.includes('--hard')
    case 'clean': return !has(a, '--dry-run', 'n')
    case 'stash': return ['push', 'save', 'drop', 'clear'].includes(a.length > 0 && !a[0]!.startsWith('-') ? a[0]! : 'push')
    case 'push': return has(a, '--delete', 'd') || operands(a).some(x => x.startsWith(':'))
    case 'branch': return has(a, '--delete', 'dD')
    case 'worktree': return a[0] === 'remove'
    default: return false
  }
}
// What a `git commit` says about its files: the paths it names, past the options that take a value and the message they
// carry (`-mmine`, `-m mine`, `-am mine`), whether it takes all tracked changes (`-a`) or the staged files too (`-i`),
// and whether it takes the staged files at all (`-o` ignores them, and with `--amend` and no paths commits none).
const COMMIT_VALUED = new Set(['--message', '--file', '--reuse-message', '--reedit-message', '--template', '--author', '--date', '--cleanup', '--fixup', '--squash', '--trailer'])
function commitArgs(a: readonly string[]) {
  const out = { paths: [] as string[], all: false, include: false, only: false, amend: false }
  for (let i = 0; i < a.length; i++) {
    const x = a[i]!
    if (x === '--') { out.paths.push(...a.slice(i + 1)); break }
    if (x === '--all') out.all = true
    else if (x === '--include') out.include = true
    else if (x === '--only') out.only = true
    else if (x === '--amend') out.amend = true
    else if (COMMIT_VALUED.has(x)) i++
    else if (x.startsWith('-') && !x.startsWith('--')) {
      const bundle = x.slice(1)
      const value = bundle.search(/[mFCct]/)
      const letters = value === -1 ? bundle : bundle.slice(0, value)
      if (letters.includes('a')) out.all = true
      if (letters.includes('i')) out.include = true
      if (letters.includes('o')) out.only = true
      if (value === bundle.length - 1) i++
    } else if (!x.startsWith('-')) out.paths.push(x)
  }
  return out
}
// The commit a forced switch or checkout puts in the tree: its start point after a new branch's name, else the branch it names, else HEAD.
const checkedOut = (a: readonly string[]) => operands(a)[has(a, '--create', 'cCbB') || has(a, '--force-create') ? 1 : 0] ?? 'HEAD'
// The branch a `git switch` or `git checkout` step names.
const named = (step: Partial<Step>) => (step.words?.[1] === 'switch' || step.words?.[1] === 'checkout' ? operands(step.words.slice(2))[0] : undefined)

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

const isObject = (x: unknown): x is Record<string, unknown> => typeof x === 'object' && x !== null && !Array.isArray(x)
const strings = (x: unknown) => Array.isArray(x) && x.every(v => typeof v === 'string')
const each = (x: unknown, ok: (v: Record<string, unknown>) => boolean) => isObject(x) && Object.values(x).every(v => isObject(v) && ok(v))

function valid(r: unknown): r is Rec {
  return isObject(r) && r.v === 1 && Number.isInteger(r.pid) && typeof r.start === 'string' && typeof r.seen === 'number'
    && (r.session_id === null || typeof r.session_id === 'string') && isObject(r.acks) && Object.values(r.acks).every(t => typeof t === 'number')
    && Array.isArray(r.kept) && r.kept.every(k => isObject(k) && typeof k.id === 'string' && typeof k.key === 'string')
    && each(r.claims, c => typeof c.repo === 'string' && strings(c.paths))
    && each(r.checkouts, c => typeof c.repo === 'string' && typeof c.expected === 'string' && (c.writer === null || typeof c.writer === 'number') && strings(c.paths)
      && (c.found === undefined || (strings(c.found) && typeof c.since === 'number')) && (c.mixed === undefined || typeof c.mixed === 'boolean'))
    && (r.calls === undefined || (Array.isArray(r.calls) && r.calls.every(c => Array.isArray(c) && c.length === 2 && c.every(n => typeof n === 'number'))))
}

function parseConfig(text: string): Config {
  const j = JSON.parse(text) as { product?: unknown; guard?: unknown; products?: unknown; resources?: unknown }
  const names = (x: unknown) => (Array.isArray(x) ? x.filter((v): v is string => typeof v === 'string') : [])
  const resources = (Array.isArray(j.resources) ? j.resources : []).flatMap((r: Record<string, unknown> | null): Resource[] =>
    typeof r?.key === 'string' && (r.kind === 'shared' || r.kind === 'exclusive')
      ? [{ key: r.key, kind: r.kind, start: names(r.start), stop: names(r.stop), tools: names(r.tools) }]
      : [])
  const products = Object.fromEntries(Object.entries(isObject(j.products) ? j.products : {}).map(([k, v]) => [k, names(v)]))
  return { product: typeof j.product === 'string' && j.product !== '' ? j.product : undefined, off: j.guard === false, products, resources }
}

function holder(text: string): Holder | undefined {
  try {
    const h = JSON.parse(text) as Holder
    return h.v === 1 && Number.isInteger(h.pid) && typeof h.start === 'string' && typeof h.last === 'number' ? h : undefined
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
  ms() { return this.w.now() }

  // The inode change time of each file in ms, read in one shell (a `stat` per file, so a missing one keeps the lines
  // aligned): unlike the modification time, no tool can set it back.
  async ctimes(files: readonly string[]): Promise<(number | undefined)[]> {
    const r = await this.run(['/bin/sh', '-c', CTIMES, 'sh', ...files]).catch(() => undefined)
    const lines = r?.exitCode === 0 ? r.stdout.split('\n') : []
    return files.map((_, i) => { const t = Number(lines[i]); return lines[i] && Number.isFinite(t) ? t * 1000 : undefined })
  }

  // A checkout of this session where another session wrote since it came, or where a live one ever wrote (its background
  // tasks may still), is mixed for good: a writer marks itself before it writes, so no write there goes unseen.
  private async mix(recs: Map<string, Rec>, me: [string, Rec] | undefined) {
    if (me === undefined) return
    const open = Object.entries(me[1].checkouts).filter(([, co]) => co.since !== undefined && co.mixed !== true)
    const others = [...recs].filter(([n]) => n !== me[0]).map(([, r]) => r)
    const writers = (top: string) => others.filter(r => (r.checkouts[top]?.writer ?? null) !== null)
    const live = await this.live(open.flatMap(([top]) => writers(top)))
    for (const [top, co] of open) {
      if (writers(top).some(r => live.has(r) || wroteSince(r.checkouts[top]!, co))) co.mixed = true
    }
  }

  // The record directory, made private the first time this load needs it.
  private made = false
  private async dir() {
    const dir = await this.w.dir()
    if (!this.made) {
      this.made = true
      await this.run(['/bin/sh', '-c', 'umask 077; mkdir -p -- "$1"', 'sh', dir])
    }
    return dir
  }

  // --- processes ----------------------------------------------------------------------------------------
  // pid -> (ppid, name) of every process; the start times it reads are kept like any other.
  async table(): Promise<Map<number, { ppid: number; name: string }>> {
    const out = (await this.run(['ps', '-A', '-o', 'pid=,ppid=,lstart=,comm='], { env: PS_ENV })).stdout
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
      const out = (await this.run(['ps', '-o', 'pid=,ppid=,lstart=,comm=', '-p', need.join(',')], { env: PS_ENV })).stdout
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

  // This session's Claude process, read once: the nearest `claude` at or above the caller (a nested `claude -p` is its
  // own session, so never the outermost). A caller with no `claude` above it (a stand-in) is itself.
  async pid(): Promise<number | undefined> {
    if (this.claude !== undefined) return this.claude
    const given = Number((await this.run(['/bin/sh', '-c', 'echo $PPID'])).stdout.trim())
    const table = await this.table()
    if (!table.has(given)) return undefined
    let found = given
    const seen = new Set<number>()
    for (let p = given; table.has(p) && !seen.has(p); p = table.get(p)!.ppid) {
      seen.add(p)
      if (/^claude(\.exe)?$/.test(table.get(p)!.name)) { found = p; break }
    }
    return (this.claude = found)
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

  // The branch HEAD names, read from the file; a reftable repository keeps a placeholder there, so git is asked.
  // `fallback` stands for a HEAD that could not be read; a detached one is ''.
  async branch(top: string, fallback = ''): Promise<string> {
    const gd = await this.gitdir(top)
    const raw = gd === undefined ? undefined : await this.w.read(`${gd}/HEAD`).catch(() => undefined)
    if (raw === undefined) return fallback
    const head = raw.trim()
    if (head === 'ref: refs/heads/.invalid') return (await this.git(top, 'symbolic-ref', '-q', '--short', 'HEAD')) ?? ''
    return head.startsWith('ref: refs/heads/') ? head.slice('ref: refs/heads/'.length) : ''
  }

  // The files of a commit's tree, or undefined when git did not answer.
  async tree(top: string, rev: string): Promise<Set<string> | undefined> {
    // NUL-separated names are read raw: trimming would turn a first name such as " f" into "f".
    const r = await this.read(top, 'ls-tree', '-r', '--name-only', '-z', rev).catch(() => undefined)
    return r === undefined || r.exitCode !== 0 ? undefined : new Set(r.stdout.split('\0').filter(Boolean))
  }

  // Whether `submodule.recurse` is on: the commands that take --recurse-submodules then recurse without it. The engine's
  // own git calls carry `-c submodule.recurse=false`, which is not the user's setting: the last value of another scope is.
  async recurses(top: string): Promise<boolean> {
    const out = await this.git(top, 'config', '--show-scope', '--type=bool', '--get-all', 'submodule.recurse')
    return out?.split('\n').filter(l => !l.startsWith('command\t')).pop()?.endsWith('\ttrue') ?? false
  }

  async rebasing(top: string): Promise<boolean> {
    const gd = await this.gitdir(top)
    return gd !== undefined && (await Promise.all(['rebase-merge', 'rebase-apply'].map(d => this.w.stat(`${gd}/${d}`)))).some(st => st !== undefined)
  }

  // Whether x names a file here that no ref of that name shadows: `git checkout x` then restores it.
  async isPath(top: string, dir: string, x: string | undefined): Promise<boolean> {
    return x !== undefined && (await this.git(top, 'rev-parse', '--verify', '--quiet', x)) === undefined && (await this.w.stat(join(dir, x))) !== undefined
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

  private async machine() { return this.config(this.user ??= await this.w.config()) }

  // `"guard": false` in the machine's file, or in the repository file of the checkout, turns the guard off there.
  async off(top: string | undefined): Promise<boolean> {
    return (await this.machine()).off || (top !== undefined && (await this.config(`${top}/.claude/cc-tuner-resources.json`)).off)
  }

  // The machine file's product paths, `~` and links resolved, read again with the file.
  private listed = new WeakMap<Config, [path: string, product: string][]>()
  private async listing(): Promise<[string, string][]> {
    const machine = await this.machine()
    let found = this.listed.get(machine)
    if (found === undefined) {
      const home = await this.w.home()
      found = []
      for (const [name, paths] of Object.entries(machine.products)) {
        for (const p of paths) {
          const abs = p === '~' || p.startsWith('~/') ? (home === undefined ? undefined : home + p.slice(1)) : p
          if (abs?.startsWith('/')) found.push([await this.real(norm(abs)), name])
        }
      }
      this.listed.set(machine, found)
    }
    return found
  }

  // The product of a checkout: its repository file's `product`, else the machine file's map, by the checkout or the
  // main worktree of its repository.
  private async product(top: string, common: string): Promise<string | undefined> {
    const own = (await this.config(`${top}/.claude/cc-tuner-resources.json`)).product
    if (own !== undefined) return own
    const listed = await this.listing()
    for (const x of [top, basename(common) === '.git' ? dirname(common) : undefined]) {
      const hit = x === undefined ? undefined : listed.find(([p]) => x === p || x.startsWith(`${p}/`))
      if (hit !== undefined) return hit[1]
    }
    return undefined
  }

  // The resources that apply at a checkout, with whether each is the machine's.
  async rules(top: string | undefined): Promise<[Resource, boolean][]> {
    const repo = top === undefined ? NONE : await this.config(`${top}/.claude/cc-tuner-resources.json`)
    const machine = await this.machine()
    return [...repo.resources.map(r => [r, false] as [Resource, boolean]), ...machine.resources.map(r => [r, true] as [Resource, boolean])]
  }

  // Whether an inspection met a git too old for it (merge-tree --write-tree needs 2.38): said once by the stop that follows.
  tooOld = false

  // Every command runs through here: output the engine cut off is no answer.
  private async run(argv: readonly string[], init?: { env?: Record<string, string> }) {
    const r = await this.w.run(argv, init)
    return r.isStdoutTruncated ? { ...r, exitCode: TRUNCATED } : r
  }

  // The `-c` overrides that silence every filter driver config defines, so `status` can read the real attributes: [] for
  // none, undefined when config could not be read or names a driver no `-c` key can spell.
  private async silenced(top: string): Promise<string[] | undefined> {
    const r = await this.run(['git', ...INERT, '-C', top, 'config', '-z', '--name-only', '--get-regexp', '^filter\\.'], { env: GIT_ENV }).catch(() => undefined)
    if (r === undefined || (r.exitCode !== 0 && r.exitCode !== 1)) return undefined
    const names = [...new Set(r.stdout.split('\0').filter(Boolean).map(k => k.slice('filter.'.length, k.lastIndexOf('.'))))]
    if (names.some(n => n === '' || n.includes('='))) return undefined
    return names.flatMap(n => [...['clean', 'smudge', 'process'].map(k => `filter.${n}.${k}=`), `filter.${n}.required=false`]).flatMap(x => ['-c', x])
  }

  // `status` runs only with every filter driver silenced; config that cannot be read leaves the tree unread.
  private async read(top: string, ...args: string[]) {
    const named = args[0] === 'status' ? await this.silenced(top) : []
    if (named === undefined) return { exitCode: 1, stdout: '' }
    const r = await this.run(['git', ...INERT, ...named, '-C', top, ...args], { env: GIT_ENV })
    if (r.exitCode === USAGE) this.tooOld = true
    return r
  }

  private async git(top: string, ...args: string[]): Promise<string | undefined> {
    const r = await this.read(top, ...args)
    return r.exitCode === 0 ? r.stdout.trim() : undefined
  }

  // --- records ------------------------------------------------------------------------------------------
  async load(): Promise<{ recs: Map<string, Rec>; bad: string[] }> {
    const dir = await this.dir()
    const entries = [...await this.w.list(dir).catch(() => [])].sort((a, b) => (a.name < b.name ? -1 : 1))
    const recs = new Map<string, Rec>()
    const bad: string[] = []
    for (const e of entries) {
      if (!e.name.endsWith('.json') || e.name.startsWith('.') || e.kind !== 'file') continue
      const key = `${e.mtimeMs}:${e.size}`
      const hit = this.cache.get(e.name)
      if (hit !== undefined && hit.key === key && e.mtimeMs > 0) { recs.set(e.name, hit.rec); continue }
      try {
        const read = async (): Promise<unknown> => JSON.parse(await this.w.read(`${dir}/${e.name}`))
        const r = await read().catch(read)
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
    await this.w.write(`${await this.dir()}/${name}`, JSON.stringify(r))
  }

  // Once an hour: tombstones untouched for 24 h are removed, and so are merge results that old.
  private async sweep(recs: Map<string, Rec>) {
    const now = this.now()
    if (now - this.swept < NOTE_TTL) return
    this.swept = now
    const live = await this.live([...recs.values()])
    // A tombstone whose writer mark keeps a live session's checkout from owning what it wrote stays until that session
    // has seen it (its next event marks the checkout mixed).
    const needed = (t: Rec) => [...live].some(x => x !== t && Object.entries(x.checkouts).some(([top, co]) =>
      co.mixed !== true && co.since !== undefined && t.checkouts[top] !== undefined && wroteSince(t.checkouts[top]!, co)))
    const old = [...recs].filter(([, r]) => !live.has(r) && now - (r.seen ?? 0) > DAY && !needed(r)).map(([n]) => n)
    await this.forget(recs, old)
  }

  // Removes records, and sweeps the directory's old merge results and object directories with them.
  private async forget(recs: Map<string, Rec>, names: string[]) {
    for (const n of names) recs.delete(n)
    await this.run(['/bin/sh', '-c', SWEEP, 'sh', await this.dir(), ...names])
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
      // What happened while the session was gone left no evidence it can read: nothing there is inferred any more.
      if (found !== undefined) {
        Object.assign(found[1], { pid, start, kept: [] })
        for (const co of Object.values(found[1].checkouts)) co.mixed = true
      }
    }
    if (found !== undefined) return found
    const base = (sid ?? '').replace(/[^A-Za-z0-9_.-]/g, '_').replace(/^\.+/, '') || `p${pid}`
    const name = recs.has(`${base}.json`) ? `${base}-${pid}.json` : `${base}.json`
    const r: Rec = { v: 1, session_id: sid, pid, start, seen: this.now(), claims: {}, acks: {}, kept: [], checkouts: {} }
    recs.set(name, r)
    return [name, r]
  }

  // A checkout's first touch also notes what was already changed there: those files are not this session's.
  private async touch(r: Rec, at: Where): Promise<Checkout> {
    r.seen = this.now()
    const [top, common] = at
    if (r.checkouts[top] === undefined) {
      const [expected, changed] = [await this.branch(top), await this.status(at, [])]
      r.checkouts[top] ??= { repo: common, expected, writer: null, paths: [], ...(changed && { since: this.now(), found: changed.map(([, , f]) => f) }) }
    }
    return r.checkouts[top]
  }

  // --- peers --------------------------------------------------------------------------------------------
  // The live sessions next to `here` (same repository, or a repository of the same product), with the
  // checkouts that make them so. A session with no call for 8 h is idle: `awake` leaves it out.
  async peers(recs: Map<string, Rec>, me: string | undefined, here: Where, awake = false): Promise<[Rec, [string, Checkout][]][]> {
    const product = await this.product(...here)
    const found: [Rec, [string, Checkout][]][] = []
    for (const [n, r] of recs) {
      if (n === me || (awake && this.now() - r.seen >= IDLE)) continue
      const cos: [string, Checkout][] = []
      for (const [top, co] of Object.entries(r.checkouts).sort(([a], [b]) => (a < b ? -1 : 1))) {
        if (co.repo === here[1] || (product !== undefined && await this.product(top, co.repo) === product)) cos.push([top, co])
      }
      if (cos.length > 0) found.push([r, cos])
    }
    const live = await this.live(found.map(([r]) => r))
    return found.filter(([r]) => live.has(r))
  }

  // merge-tree of the two commits in a temporary bare repository that borrows the repository's objects through
  // `objects/info/alternates`: it has no configuration, attributes or hooks of the real one (so no merge driver any
  // key of it names, `merge.default` included, can run), the user's and the system's config are not read, and the
  // result objects land in it alone. Cached per SHA pair.
  private async conflicts(common: string, mine: string, theirs: string): Promise<string[] | undefined> {
    const cache = `${await this.dir()}/merge/v2/${mine}-${theirs}`
    try {
      return JSON.parse(await this.w.read(cache)) as string[]
    } catch { /* not cached yet */ }
    const r = await this.run(['/bin/sh', '-c', ISOLATED_MERGE, 'sh', await this.dir(), common, mine, theirs, ...INERT], { env: GIT_ENV })
    if (r.exitCode === USAGE) this.tooOld = true
    if (r.exitCode !== 0 && r.exitCode !== 1) return undefined
    // NUL-separated: the tree, the conflicted names, an empty field, then messages. Names come raw, never quoted.
    const fields = r.stdout.split('\0')
    const names = fields.slice(1, fields.indexOf('', 1) < 0 ? undefined : fields.indexOf('', 1))
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
          const names = await this.conflicts(here[1], mineSha, sha)
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
    // The plan's real path: two repositories' plans of one relative path are two claims.
    const key = await this.real(path)
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
    if (!machine && at !== undefined) return (await this.peers(recs, me, at, true)).map(([r, cos]) => who(r, cos[0]![1]))
    const others = [...recs].filter(([n, r]) => n !== me && this.now() - r.seen < IDLE).map(([, r]) => r)
    const live = await this.live(others)
    return others.filter(r => live.has(r)).map(r => who(r, Object.values(r.checkouts)[0]))
  }

  // A task that started a shared resource goes into this session's record, where /clear and a reload leave it.
  async started(steps: readonly Step[], cwd: string, sid: string | null, id: string) {
    for (const st of steps) {
      const top = (await this.where(join(cwd, st.dir)))?.[0]
      const res = (await this.rules(top)).find(([r]) => r.kind === 'shared' && r.start.some(p => prefixed(st.words, p)))
      if (res !== undefined) return this.update(sid, r => { r.kept.push({ id, key: res[0].key, top }) })
    }
  }

  // Runs f on this session's record, made for the occasion when a session id is given, and saves it.
  private async update(sid: string | null | undefined, f: (r: Rec) => void) {
    await this.serial(async () => {
      const { recs } = await this.load()
      const pid = await this.pid()
      if (pid === undefined) return
      const own = sid === undefined ? this.mine(recs, pid, (await this.starts([pid])).get(pid)) : await this.session(recs, pid, sid)
      if (own === undefined) return
      f(own[1])
      await this.save(...own)
    })
  }

  // Any tool call shows the session is in use: its record's `seen` is renewed, at most once a minute.
  private beat = 0
  async alive() {
    const now = this.now()
    if (now - this.beat < PS_TTL) return
    await this.update(undefined, r => { r.seen = now; this.beat = now })
  }

  // The ids of the shared tasks this session keeps.
  async kept(): Promise<string[]> {
    return (await this.view()).me?.kept.map(k => k.id) ?? []
  }

  async unkeep(id: string) { await this.update(undefined, r => { r.kept = r.kept.filter(k => k.id !== id) }) }

  // Why a task that started a shared resource must not be stopped now, or undefined when it may be.
  async taskStop(task: string): Promise<string | undefined> {
    const { recs, name, me } = await this.view()
    const kept = me?.kept.find(k => k.id === task)
    if (kept === undefined || await this.off(kept.top)) return undefined
    const rule = (await this.rules(kept.top)).find(([r]) => r.kind === 'shared' && r.key === kept.key)
    if (rule === undefined) return undefined
    const [user] = await this.users(recs, name, kept.top === undefined ? undefined : await this.where(kept.top), rule[1])
    return user === undefined ? undefined
      : `cc-tuner: task ${task} runs ${kept.key}, which ${user} also uses. Wait, or SendMessage that session if you can.`
  }

  // What a lease goes by: this session's Claude process and its start time.
  private async self(): Promise<[pid: number, start: string] | undefined> {
    const pid = await this.pid()
    return pid === undefined ? undefined : [pid, (await this.starts([pid])).get(pid) ?? '']
  }

  // A machine resource's lock is one per machine; a repository's is one per product (or repository without one).
  private async lock(key: string, at?: Where) {
    const scope = at === undefined ? '' : `${(await this.product(...at)) ?? `repo-${crc32(at[1])}`}.`
    return `${await this.dir()}/lease.${(scope + key).replace(/[^A-Za-z0-9_.-]/g, '_')}`
  }

  // What a lock's holder file says, without a trailing newline: the shell compares it as `$(cat …)` does.
  private async held(lock: string) { return (await this.w.read(`${lock}/holder.json`).catch(() => '')).replace(/\n+$/, '') }

  // The lease of every exclusive resource this tool belongs to: the first call takes it, the holder keeps it.
  async lease(tool: string, cwd: string, sid: string | null): Promise<Verdict> {
    const at = await this.where(cwd)
    if (await this.off(at?.[0])) return { decision: 'allow' }
    const hits = (await this.rules(at?.[0])).filter(([r]) => r.kind === 'exclusive' && r.tools.some(t => glob(t).test(tool)))
    if (hits.length === 0) return { decision: 'allow' }
    return this.serial(async () => {
      const me = await this.self()
      if (me === undefined) return { decision: 'allow' }
      const notes: string[] = []
      const taken: string[] = []
      for (const [{ key }, machine] of hits) {
        const lock = await this.lock(key, machine ? undefined : at)
        const v = await this.hold(key, lock, me, sid)
        if (v.decision === 'stop') {
          // The call does not run, so what it took for itself goes back.
          for (const l of taken) await this.free(l, me)
          return v
        }
        if (v.reason !== undefined) { notes.push(v.reason); taken.push(lock) }
      }
      return notes.length > 0 ? { decision: 'note', reason: notes.join(' ') } : { decision: 'allow' }
    })
  }

  // The holder's call renews the lease at most once a minute. A renewal that stays busy past its retries is a takeover under
  // way that may still complete: the call stops (no ack) rather than allows, so the old and the new holder are never both
  // users. One that finds the lock changed re-reads it, and the lock's holder decides; a re-read that shows this session
  // still the holder allows only while the takeover mutex is free.
  private async hold(key: string, lock: string, me: [number, string], sid: string | null, renew = true): Promise<Verdict> {
    const [pid, start] = me
    const [text, st] = [await this.held(lock), await this.w.stat(lock)]
    const [cur, now] = [holder(text), this.now()]
    const mine = JSON.stringify({ v: 1, key, pid, start, session: sid, last: now })
    if (cur?.pid === pid && cur.start === start) {
      if (!renew) return (await this.w.stat(`${lock}.take`)) === undefined ? { decision: 'allow' } : this.taking(key)
      if (now - cur.last < LEASE_RENEW) return { decision: 'allow' }
      let rc = 2
      for (let i = 0; i < 3 && rc === 2; i++) rc = (await this.run(['/bin/sh', '-c', RENEW, 'sh', lock, text, mine])).exitCode
      if (rc === 2) return this.taking(key)
      return rc === 0 ? { decision: 'allow' } : this.hold(key, lock, me, sid, false)
    }
    if (st !== undefined) {
      // A lock nobody wrote into yet is as old as its directory.
      const last = cur?.last ?? Math.floor((st.mtimeMs ?? now * 1000) / 1000)
      const gone = cur !== undefined && (await this.starts([cur.pid])).get(cur.pid) !== cur.start
      if (!gone && now - last < LEASE_IDLE) return this.leased(key, cur, now)
    }
    const r = await this.run(['/bin/sh', '-c', TAKE, 'sh', lock, text, mine])
    if (r.exitCode !== 0) return this.leased(key, holder(await this.held(lock)), now)
    return { decision: 'note', reason: `cc-tuner: you hold ${key}; release it with peers_release when you are done.` }
  }

  private taking(key: string): Verdict {
    return { decision: 'stop', reason: `cc-tuner: ${key} is being taken or renewed by another session; try again shortly.` }
  }

  private leased(key: string, h: Holder | undefined, now: number): Verdict {
    const by = h === undefined ? 'another session' : `pid ${h.pid}, used ${now - h.last} s ago`
    return { decision: 'stop', reason: `cc-tuner: ${key} is leased to ${by}. Wait, or SendMessage that session if you can.` }
  }

  // Frees the lease only for its holder, checked against the holder file the shell removes it under: true when freed,
  // undefined when another session kept the lock busy.
  private async free(lock: string, me: [number, string]): Promise<boolean | undefined> {
    const text = await this.held(lock)
    const cur = holder(text)
    if (cur?.pid !== me[0] || cur.start !== me[1]) return false
    for (let i = 0; i < 3; i++) {
      const { exitCode } = await this.run(['/bin/sh', '-c', RELEASE, 'sh', lock, text])
      if (exitCode !== 2) return exitCode === 0
    }
    return undefined
  }

  // The lease of `key` as the cwd's resources scope it: the repository's (its product) first, then the machine's.
  async release(key: string, cwd: string): Promise<string> {
    const refused = `cc-tuner: ${key} is not leased to this session.`
    const at = await this.where(cwd)
    const rules = (await this.rules(at?.[0])).filter(([r]) => r.kind === 'exclusive' && r.key === key)
    const locks = await Promise.all((rules.length > 0 ? rules : [[undefined, true] as const]).map(([, machine]) => this.lock(key, machine ? undefined : at)))
    return this.serial(async () => {
      const me = await this.self()
      if (me === undefined) return refused
      for (const lock of locks) {
        const done = await this.free(lock, me)
        if (done === undefined) return `cc-tuner: ${key} is being taken or renewed by another session; try again shortly.`
        if (done) return `cc-tuner: released ${key}.`
      }
      return refused
    })
  }

  // --- the guard ----------------------------------------------------------------------------------------
  // One event: update this session's record and answer allow, note or stop. `before` decides and, for an allowed or
  // noted call, marks the writer, so a long call counts while it runs; a stopped one marks none. `after` records the
  // paths an edit changed and moves the expected branch, only for a call the engine let run.
  async check(ev: Event): Promise<Verdict & { line?: string }> {
    // A call's own writes are done before its `after` arrives, so its window closes here, before anything is read.
    const ended = this.ms()
    const sid = ev.session_id || null
    const target = ev.path ? join(ev.cwd, ev.path) : undefined
    const here = await this.where(target !== undefined ? dirname(target) : ev.cwd)
    const plan: { st: Partial<Step>; writes: boolean; switch: boolean; blind: boolean; at: Where | undefined; d: string }[] = []
    if (ev.phase !== 'start' && ev.tool === 'Bash') {
      for (const st of ev.steps ?? [{} as Partial<Step>]) {
        const blind = st.dir === UNKNOWN
        const d = join(ev.cwd, blind ? '' : st.dir ?? '')
        const [writes, sw] = [!readOnly(st), switches(st)]
        // A git step is recorded in its checkout though it only reads, so the first touch fixes the branch it started on.
        const known = !blind && (writes || sw || basename(st.words?.[0] ?? '') === 'git')
        plan.push({ st, writes, switch: sw, blind: blind && writes, at: known ? (d === norm(ev.cwd) ? here : await this.where(d)) : undefined, d })
      }
    }
    // Outside every repository only a step that finds its own targets matters: a command of the machine's shared
    // resources (a stop can be refused, and a start makes this session a user of the resource, with a record that has no
    // checkout), a removal, whose roots come from the records, and a destructive step in a directory nobody could tell. Nothing
    // that needs the cwd's checkout does.
    const bare = here === undefined && !plan.some(p => p.at !== undefined)
    if ((bare && !(ev.phase === 'before' && await this.finds(plan))) || (sid === null && ev.phase === 'start')) return { decision: 'allow', line: '' }
    return this.serial(async () => {
      const { recs, bad } = await this.load()
      const pid = await this.pid()
      if (pid === undefined) return { decision: 'allow', line: '' }
      const now = this.now()
      // A new session id in this process (/clear, an in-process resume) is followed on whatever event shows it first, so
      // a start that came where nothing is recorded cannot carry the old conversation's acks into the new one.
      if (sid !== null) {
        const own = this.mine(recs, pid, (await this.starts([pid])).get(pid))
        if (own !== undefined && own[1].session_id !== sid) await this.follow(recs, own, sid)
      }
      const [name, r] = await this.session(recs, pid, sid)
      const co = here === undefined ? undefined : await this.touch(r, here)
      for (const { at } of plan) if (at !== undefined) await this.touch(r, at)
      // Before anything is decided, and before a sweep: a checkout touched first in this very call is judged mixed too.
      await this.mix(recs, [name, r])
      await this.sweep(recs)
      for (const k of ev.acks ?? []) r.acks[k] = now
      let verdict: Verdict = { decision: 'allow' }
      if (ev.phase === 'before') verdict = await new Guard(this, recs, bad, name, r, pid, here, now).judge(ev, plan, target)
      const seen: Record<string, string> = {}
      if (ev.phase === 'before' && ev.tool === 'Bash' && verdict.decision !== 'stop' && plan.some(p => p.writes && p.at !== undefined)) {
        seen[CALL] = String(this.ms())
      }
      const opened = Number(ev.seen?.[CALL])
      if (ev.phase === 'after' && ev.tool === 'Bash' && ev.ok !== false && Number.isFinite(opened)) {
        (r.calls ??= []).push([opened, ended])
        r.calls.splice(0, Math.max(0, r.calls.length - CALLS))
      }
      const writing: Checkout[] = []
      if (verdict.decision !== 'stop') {
        for (const { at, writes, switch: sw } of plan) {
          if (at === undefined) continue
          if (ev.phase === 'before' && writes) writing.push(r.checkouts[at[0]]!)
          if (ev.phase === 'before' && sw) seen[at[0]] = await this.branch(at[0])
        }
        if (ev.phase === 'before' && ev.tool !== undefined && EDITS.has(ev.tool) && co !== undefined) writing.push(co)
        if (ev.phase === 'after' && ev.tool !== undefined && EDITS.has(ev.tool) && ev.ok !== false && target !== undefined && here !== undefined && co !== undefined) {
          const rel = relpath(await this.real(target), here[0])
          if (!co.paths.includes(rel)) co.paths.push(rel)
        }
        if (ev.phase === 'after' && ev.tool === 'Bash' && ev.ok !== false) {
          for (const { st, at, switch: sw } of plan) {
            if (at === undefined || !sw) continue
            const head = await this.branch(at[0])
            if (head !== (ev.seen?.[at[0]] ?? head) || head === named(st)) r.checkouts[at[0]]!.expected = head
          }
        }
      }
      r.acks = Object.fromEntries(Object.entries(r.acks).filter(([, t]) => now - t < NOTE_TTL))
      // The writer mark is the time the record is published, after every read this call waited on: a session that came
      // meanwhile has an earlier `since`, so it sees the mark as a write after it came.
      const stamp = this.now()
      for (const c of writing) c.writer = stamp
      await this.save(name, r)
      const out: Verdict & { line?: string } = { ...verdict }
      if (Object.keys(seen).length > 0) out.seen = seen
      if (ev.phase === 'start' && here !== undefined) out.line = await this.startLine(recs, name, r, here)
      return out
    })
  }

  private async finds(plan: { st: Partial<Step>; blind: boolean }[]): Promise<boolean> {
    return plan.some(p => (p.blind || basename(p.st.words?.[0] ?? '') === 'rm') && destroys(p.st.words ?? [])) || this.machineUse(plan.map(p => p.st.words ?? []))
  }

  // Whether a command starts or stops a shared resource the machine's own file declares.
  private async machineUse(steps: string[][]): Promise<boolean> {
    return (await this.machine()).resources.some(r => r.kind === 'shared' && [...r.start, ...r.stop].some(p => steps.some(w => prefixed(w, p))))
  }

  // A new session id in this process (/clear, /resume): acks and claims start over; a resumed session's tombstone
  // gives its paths, expected branches and claims back, and goes.
  private async follow(recs: Map<string, Rec>, [name, r]: [string, Rec], sid: string | null) {
    Object.assign(r, { session_id: sid, acks: {}, claims: {} })
    const same = [...recs].filter(([n, t]) => n !== name && sid !== null && t.session_id === sid)
    const live = await this.live(same.map(([, t]) => t))
    const tomb = same.find(([, t]) => !live.has(t))
    if (tomb === undefined) return
    for (const [top, c] of Object.entries(tomb[1].checkouts)) {
      c.mixed = true
      const mine = r.checkouts[top]
      const writer = Math.max(mine?.writer ?? -1, c.writer ?? -1)
      r.checkouts[top] = mine === undefined ? c : { ...c, writer: writer < 0 ? null : writer, paths: [...new Set([...c.paths, ...mine.paths])], mixed: true }
    }
    Object.assign(r.claims, tomb[1].claims)
    r.calls = [...(tomb[1].calls ?? []), ...(r.calls ?? [])].sort((x, y) => x[0] - y[0]).slice(-CALLS)
    await this.forget(recs, [tomb[0]])
  }

  private async startLine(recs: Map<string, Rec>, name: string, r: Rec, here: Where): Promise<string> {
    const parts: string[] = []
    const peers: string[] = []
    for (const [p, cos] of await this.peers(recs, name, here)) {
      for (const [top, co] of cos) peers.push(`${await this.branch(top, co.expected) || 'detached'} (${basename(top)}, pid ${p.pid})`)
    }
    if (peers.length > 0) parts.push(`live peers: ${peers.join(', ')}`)
    if (r.kept.length > 0) parts.push(`kept at /clear: ${r.kept.map(k => `${k.key} (${k.id})`).join(', ')}`)
    return parts.length === 0 ? '' : `cc-tuner: ${parts.join('; ')}. Details: peers_report.`
  }

  // The changed files as [index, worktree, path], or undefined when git did not answer: that is not a clean tree.
  async status([top]: Where, staged: readonly string[], path?: string): Promise<[string, string, string][] | undefined> {
    const spec = path === undefined ? [] : ['--', path]
    const r = await this.read(top, 'status', '--porcelain=v1', '-z', '--untracked-files=all', '--no-renames', '--ignore-submodules=all', ...spec).catch(() => undefined)
    if (r === undefined || r.exitCode !== 0) return undefined
    let found: [string, string, string][] = []
    for (const e of r.stdout.split('\0')) if (e.length > 3) found.push([e[0]!, e[1]!, e.slice(3)])
    for (const p of staged) found = [...found.filter(e => e[2] !== p), ['A', ' ', p]]
    return found
  }

  async pidsOf(argv: readonly string[]): Promise<number[] | undefined> {
    try {
      const r = await this.run(argv)
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
  // The checkouts a switch step of this call moves, for the steps that run only if it succeeded: an unbroken chain of `&&`
  // in the same scope (a substitution's steps are a scope of their own).
  private moved = new Set<string>()
  private chains = new Map<number, Set<string>>()
  private staged = new Map<string, string[]>()

  constructor(private readonly p: Peers, private readonly recs: Map<string, Rec>, private readonly bad: string[], private readonly name: string,
    private readonly r: Rec, private readonly pid: number, private readonly here: Where | undefined, private readonly now: number) {}

  async judge(ev: Event, plan: { st: Partial<Step>; blind: boolean; at: Where | undefined; d: string }[], target: string | undefined): Promise<Verdict> {
    try {
      if (this.bad.length > 0 && !await this.p.off(this.here?.[0])) this.once('bad', `skipped malformed peer record ${listing(this.bad)}.`)
      if (ev.tool === 'Bash') {
        let prev: string[] = []
        for (const { st, at, d, blind } of plan) {
          this.moved = this.chains.get(st.scope ?? 0) ?? new Set()
          this.chains.set(st.scope ?? 0, this.moved)
          if (st.op !== '&&') this.moved.clear()
          const w = st.words ?? []
          if (w.length > 0 && !await this.p.off((at ?? this.here)?.[0])) await this.step(w, at, d, prev, blind, st.config)
          prev = w
        }
      } else if (target !== undefined && this.here !== undefined && !await this.p.off(this.here[0])) {
        await this.edit(this.here, relpath(await this.p.real(target), this.here[0]))
      }
    } catch (err) {
      if (err instanceof Halt) return { decision: 'stop', reason: [...this.notes, err.message].join(' ') }
      throw err
    }
    return this.notes.length > 0 ? { decision: 'note', reason: this.notes.join(' ') } : { decision: 'allow' }
  }

  private peers(at: Where, awake = false) { return this.p.peers(this.recs, this.name, at, awake) }
  private note(text: string) { this.notes.push(`cc-tuner: ${text}`) }

  private once(key: string, text: string) {
    if (this.now - (this.r.acks[key] ?? 0) >= NOTE_TTL) {
      this.r.acks[key] = this.now
      this.note(text)
    }
  }

  // The safe way comes first; the ack is the way on, and its use is the agent's own call only where a peer owns what is at stake.
  private stop(action: string, target: string, text: string, safe = '', peer = true) {
    const k = crc32(`${action}|${target}`)
    if (this.now - (this.r.acks[k] ?? 0) >= ACK_TTL) {
      throw new Halt(`cc-tuner: ${text}${safe && ` ${safe}`} To go on, rerun it prefixed CC_TUNER_ACK=${k}.` +
        (peer ? " Your call, not the user's." : ''))
    }
  }

  // The git configuration the step in hand was given for itself (`-c`, `--config-env`, GIT_CONFIG*).
  private config: readonly string[] = []

  // That configuration is no setting the guard read and can change what a command reaches (`submodule.recurse`), so a
  // command that discards anything and carries it has an unread scope.
  private configured(top: string, label: string) {
    if (this.config.length === 0) return
    this.stop('git config', `${top}|config`, `\`${label}\` sets git config for itself (${listing([...new Set(this.config.map(x => x.split('=')[0]!))])}), which the guard does not read.`,
      'Drop -c, --config-env and GIT_CONFIG_*, or check the tree yourself.', false)
  }

  // git and gh act on the checkout of their directory; rm and kill reach past it, so outside a repository
  // they are read from the cwd's.
  private async step(w: string[], at: Where | undefined, d: string, prev: string[], blind: boolean, config: readonly string[] = []) {
    this.config = config
    const name = basename(w[0]!)
    const scope = at ?? this.here
    await this.shared(w, at)
    if (blind && (name === 'git' || name === 'gh' || name === 'rm')) {
      if (destroys(w)) await this.unresolved(w, scope)
      else await this.unsure(scope, `could not read the directory of \`${w.join(' ').slice(0, 60)}\`; peers_report shows who works there.`)
    }
    else if (name === 'git' && at !== undefined) await this.git(w, at, d)
    else if (name === 'gh' && at !== undefined) await this.gh(w, at, d)
    else if (name === 'kill' || name === 'pkill' || name === 'killall') { if (scope !== undefined) await this.kill(name, w.slice(1), scope, prev) }
    else if (name === 'rm' && has(w.slice(1), '--recursive', 'rR')) await this.remove(scope, d, w.join(' ').slice(0, 60), operands(w.slice(1)))
    else if (OPAQUE.has(name) && NAMES_A_COMMAND.test(w.slice(1).join(' '))) await this.unsure(scope, `could not read \`${w.join(' ').slice(0, 60)}\`; peers_report shows who works here.`)
  }

  // A destructive step in a directory nobody could tell (an earlier `cd` may have failed, or goes where the guard cannot read)
  // acts on a checkout nobody can name, so it stops. The absolute operands of a removal do not depend on the directory.
  private async unresolved(w: string[], scope: Where | undefined) {
    const label = w.join(' ').slice(0, 60)
    const rm = basename(w[0]!) === 'rm'
    const named = rm ? operands(w.slice(1)) : []
    const known = named.filter(x => x.startsWith('/'))
    if (rm) await this.remove(scope, '/', label, known)
    if (!rm || known.length < named.length) {
      this.stop('unresolved', `${this.here?.[0] ?? ''}|${w.join(' ')}`, `cannot tell which checkout \`${label}\` runs in: an earlier \`cd\` may have failed.`,
        'Use `cd <literal dir> && …` or `git -C <dir>`.', false)
    }
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
    // Paths listed in a file are never read: the file can change before the command reads it, so the scope is unresolved.
    const listed = a.some(x => x === '--pathspec-from-file' || x.startsWith('--pathspec-from-file='))
    const after = listed ? undefined : a.includes('--') ? a.slice(a.indexOf('--') + 1) : undefined
    const args = (x: readonly string[]) => (listed ? undefined : x)
    if (sub.startsWith('-')) {
      await this.unsure(at, `could not read \`${label}\`; peers_report shows who works in ${top}.`)
    } else if (sub === 'switch' || sub === 'checkout') {
      if (sub === 'checkout' && !has(a, '--orphan', 'bB') && (listed || after !== undefined || await this.p.isPath(top, d, operands(a)[0]))) {
        await this.recursing(at, label, 'checkout', a)
        await this.lose(at, d, label, 'checkout', 'overwrite', 'tracked', after ?? args(operands(a)))
      } else {
        if (has(a, '--force', 'f') || a.includes('--discard-changes')) {
          await this.recursing(at, label, sub, a)
          await this.lose(at, d, label, sub, 'discard', 'tracked', undefined, has(a, '--orphan') ? undefined : checkedOut(a))
        }
        await this.switch(at)
        this.moved.add(top)
      }
    } else if (sub === 'reset' && a.includes('--hard')) {
      await this.recursing(at, label, 'reset', a)
      await this.lose(at, d, label, 'reset', 'discard', 'tracked', undefined, operands(a.slice(0, a.includes('--') ? a.indexOf('--') : a.length))[0] ?? 'HEAD')
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
      await this.recursing(at, label, 'restore', a)
      await this.lose(at, d, label, 'restore', 'overwrite', 'tracked', args(operands(a)))
    } else if (sub === 'commit') {
      await this.drift(at, label, 'commit')
      const { paths, all, include, only, amend } = commitArgs(a)
      if (listed) await this.lose(at, d, label, 'commit', 'commit', 'tracked')
      else if (paths.length === 0) {
        if (!(only && amend && !all)) await this.lose(at, d, label, 'commit', 'commit', all ? 'tracked' : 'staged')
      } else {
        if (include) await this.lose(at, d, label, 'commit', 'commit', 'staged')
        await this.lose(at, d, label, 'commit', 'commit', 'tracked', paths)
      }
    } else if (sub === 'add') {
      const named = listed ? [] : operands(a)
      const wide: string[] = []
      for (const x of named) if (x === '.' || /[*?[]/.test(x) || await this.p.isDir(join(d, x))) wide.push(x)
      const staged = this.staged.get(top) ?? []
      for (const x of named) if (!wide.includes(x)) staged.push(relpath(await this.p.real(join(d, x)), top))
      this.staged.set(top, staged)
      if (has(a, '--all', 'A') || listed) await this.lose(at, d, label, 'add', 'stage', 'all')
      else if (has(a, '--update', 'u')) await this.lose(at, d, label, 'add', 'stage', 'tracked', named.length > 0 ? named : undefined)
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

  private async gh(w: string[], at: Where, d: string) {
    if (w.length < 3 || w[1] !== 'pr' || (w[2] !== 'create' && w[2] !== 'merge' && w[2] !== 'checkout')) return
    const label = w.join(' ').slice(0, 60)
    if (w[2] === 'checkout') {
      if (has(w.slice(3), '--force', 'f')) await this.lose(at, d, label, 'gh pr checkout', 'discard', 'tracked')
      await this.switch(at)
      this.moved.add(at[0])
      return
    }
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
    else if (/^\d+$|^https?:\/\//.test(sel[0]!)) await this.unsure(at, `\`${label}\` deletes a branch it does not name; peers_report shows who works on which.`)
    else await this.delete(at, [sel[0]!], label)
  }

  private async switch(at: Where) {
    const top = at[0]
    const here = (await this.peers(at)).flatMap(([r, cos]) => cos.filter(([t]) => t === top).map(([, co]) => [r, co] as const))
    const busy = here.filter(([, co]) => co.writer !== null && this.now - co.writer < WRITER_WINDOW)
    if (busy.length > 0) this.stop('switch', top, `${who(...busy[0]!)} works in ${top}; switching branches there changes its files.`, 'Take a worktree instead: `git worktree add <path> <branch>`.')
    else if (here.length > 0) this.note(`${who(...here[0]!)} has its cwd in ${top}; switching branches there changes its files.`)
  }

  private async drift(at: Where, label: string, action: string) {
    const top = at[0]
    const [head, want] = [await this.p.branch(top), this.r.checkouts[top]!.expected]
    if (!this.moved.has(top) && head !== want && !await this.p.rebasing(top)) {
      this.stop(`${action} on ${top}`, top, `\`${label}\` would run on ${head || 'a detached HEAD'} in ${top}; this session started on ${want || 'a detached HEAD'}.`,
        `${want === '' ? 'Join' : `Switch back with \`git switch ${want}\`, or join`} your own switch to the command with \`&&\`.`)
    }
  }

  // The paths this session edited in a checkout.
  private own(top: string): string[] {
    return this.r.checkouts[top]?.paths ?? []
  }

  // Whether a changed file is someone else's. This session's own are the paths it edited and, in a checkout no other
  // session writes in, the files whose inode last changed inside one of its own Bash calls; a file already changed when
  // it came never is. Anything changed between its calls (the user, a tool left running, a copy that kept old times) is not.
  private async others(at: Where, changed: readonly [string, string, string][]): Promise<(f: string) => boolean> {
    const top = at[0]
    const [mine, found] = [this.own(top), this.r.checkouts[top]?.found]
    const edited = [...this.recs].filter(([n]) => n !== this.name).flatMap(([, r]) => r.checkouts[top]?.paths ?? [])
    const calls = this.r.checkouts[top]?.mixed ? [] : this.r.calls ?? []
    const made = new Set<string>()
    if (found !== undefined && calls.length > 0) {
      const maybe = changed.filter(([x, y, f]) => !owns(mine, f) && !owns(found, f) && !owns(edited, f) && x !== 'D' && y !== 'D').map(([, , f]) => f)
      const times = maybe.length === 0 ? [] : await this.p.ctimes(maybe.map(f => join(top, f)))
      // Windows are whole milliseconds and file times finer, so a file time counts by the millisecond it falls in.
      maybe.forEach((f, i) => { const t = times[i]; if (t !== undefined && calls.some(([s, e]) => Math.floor(t) >= s && Math.floor(t) <= e)) made.add(f) })
    }
    return f => !owns(mine, f) && !made.has(f)
  }

  // A note that only matters next to a peer: a session alone in its product gets none.
  private async unsure(at: Where | undefined, text: string) {
    if (at === undefined || (await this.peers(at)).length > 0) this.note(text)
  }

  // The changed files of a checkout this session did not edit, within the paths a command reaches.
  // `into` is a commit about to be checked out over the tree: the untracked files its tree holds are overwritten too.
  private async foreign(at: Where, kinds: string, specs: readonly string[] | undefined, d: string, into?: string): Promise<string[] | undefined> {
    const top = at[0]
    const reach = specs === undefined || specs.some(unresolved) ? undefined : await Promise.all(specs.map(async x => relpath(await this.p.real(join(d, x)), top)))
    const changed = await this.p.status(at, this.staged.get(top) ?? [])
    if (changed === undefined) return undefined
    const theirs = await this.others(at, changed)
    const lost = changed
      .filter(([x]) => !((kinds === 'tracked' && x === '?') || (kinds === 'untracked' && x !== '?') || (kinds === 'staged' && ' ?'.includes(x))))
      .map(([, , f]) => f)
      .filter(f => theirs(f) && (reach === undefined || reach.some(x => covers(x, f))))
    const loose = into === undefined ? [] : changed.filter(([x, , f]) => x === '?' && theirs(f) && !lost.includes(f)).map(([, , f]) => f)
    if (loose.length === 0) return lost
    const tree = await this.p.tree(top, into!)
    if (tree === undefined) return undefined
    // A path collides when the tree holds it, a file above it, or a directory at it.
    const dirs = new Set<string>()
    for (const t of tree) for (let i = t.indexOf('/'); i !== -1; i = t.indexOf('/', i + 1)) dirs.add(t.slice(0, i))
    const above = (f: string) => [...f.matchAll(/\//g)].some(m => tree.has(f.slice(0, m.index)))
    return [...lost, ...loose.filter(f => tree.has(f) || dirs.has(f) || above(f))]
  }

  private unread(action: string, top: string, label: string) {
    if (this.p.tooOld) this.note('git 2.38 or newer is needed to inspect safely.')
    this.stop(action, `${top}|?`, `could not read git status in ${top}, so \`${label}\` may lose files nobody here edited.`)
  }

  private async owner(top: string, files: string[]): Promise<string> {
    const names = [...this.recs].filter(([n, r]) => n !== this.name && r.checkouts[top] !== undefined
      && files.some(f => owns(r.checkouts[top]!.paths, f)))
    const live = await this.p.starts(names.map(([, r]) => r.pid))
    return names.map(([, r]) => (live.get(r.pid) === r.start ? who(r, r.checkouts[top]!) : `pid ${r.pid}, exited`)).join(', ') || NO_OWNER
  }

  private async lose(at: Where, d: string, label: string, action: string, verb: string, kinds: string, specs?: readonly string[], into?: string) {
    const top = at[0]
    if (verb !== 'commit' && verb !== 'stage') this.configured(top, label)
    const files = await this.foreign(at, kinds, specs, d, into)
    if (files === undefined) this.unread(action, top, label)
    else if (files.length > 0) await this.foreignStop(action, top, files, `\`${label}\` would ${verb} ${listing(files)} in ${top}`)
  }

  // Status ignores submodules, so what a destructive command discards inside them is not inspected: a recursion stops.
  private async recursing(at: Where, label: string, action: string, a: readonly string[]) {
    this.configured(at[0], label)
    // The last recursion flag wins; an attached value turns it off only when it is a false word.
    const last = flags(a).filter(x => /^--(no-)?recurse-submodules(=|$)/.test(x)).pop()
    const off = last !== undefined && (last.startsWith('--no-') || /=(no|off|false|0)$/i.test(last))
    if (off || (last === undefined && !(await this.p.recurses(at[0])))) return
    this.stop(action, `${at[0]}|submodules`, `\`${label}\` reaches the submodules of ${at[0]}, which the guard does not inspect.`,
      'Add --no-recurse-submodules, or check them yourself.', false)
  }

  private async foreignStop(action: string, target: string, files: string[], text: string) {
    const owner = await this.owner(target, files)
    const unknown = owner === NO_OWNER
    this.stop(action, `${target}|${[...files].sort().join('|')}`, `${text} (${owner}).`,
      `Act on your own paths instead${unknown ? "; those files may be the user's own edits" : ''}.`, !unknown)
  }

  private async stashDrop(at: Where, label: string) {
    for (const [r, cos] of await this.peers(at, true)) {
      for (const [top, co] of cos) {
        if (co.repo === at[1] && co.writer !== null) this.stop('stash drop', at[1], `\`${label}\` would drop a stash that ${who(r, co)} shares, working in ${top}.`)
      }
    }
  }

  private async delete(at: Where, names: readonly string[], label: string) {
    for (const name of names) {
      for (const [r, cos] of await this.peers(at, true)) {
        for (const [top, co] of cos) {
          if (co.repo === at[1] && co.expected === name) {
            this.stop('delete branch', `${at[1]}:${name}`, `\`${label}\` would delete ${name}, the branch ${who(r, co)} works on in ${top}.`)
          }
        }
      }
    }
  }

  // The checkouts a recursive removal of `path` reaches: every root at or under it that a record names (live or a
  // tombstone), this session's own, the one holding the session's cwd and the step's own, and the target itself when it
  // is one. A parent of a checkout is removed with it, so each is read as a direct removal of it would be.
  private async roots(path: string, at: Where | undefined, there: Where | undefined): Promise<Where[]> {
    const prefix = path.endsWith('/') ? path : `${path}/`
    const tops = [...this.recs.values(), this.r].flatMap(r => Object.keys(r.checkouts)).concat(at?.[0] ?? [], this.here?.[0] ?? [], there?.[0] ?? [])
    const found: Where[] = []
    for (const top of [...new Set(tops)].filter(t => t === path || t.startsWith(prefix)).sort()) {
      const w = await this.p.where(top)
      if (w?.[0] === top) found.push(w)
    }
    return found
  }

  private async remove(at: Where | undefined, d: string, label: string, paths: readonly string[]) {
    for (const p of paths) {
      const path = await this.p.real(join(d, p))
      const there = await this.p.where(path)
      const roots = await this.roots(path, at, there)
      for (const w of there ?? at ? [...roots, (there ?? at)!] : roots) {
        for (const [r, cos] of await this.peers(w, true)) {
          for (const [top, co] of cos) {
            if (top === path || top.startsWith(`${path}/`)) this.stop('remove', path, `\`${label}\` would remove ${path}, where ${who(r, co)} works.`)
          }
        }
      }
      for (const w of roots) {
        const files = await this.foreign(w, 'all', undefined, w[0])
        if (files === undefined) this.unread('remove', w[0], label)
        else if (files.length > 0) await this.foreignStop('remove', w[0], files, `\`${label}\` would delete ${listing(files)} in ${w[0]}`)
      }
    }
  }

  private async kill(name: string, a: string[], at: Where, prev: string[]) {
    if (probes(name, a)) return
    const peers = new Map<number, [Rec, Checkout]>()
    for (const [r, cos] of await this.peers(at, true)) for (const [, co] of cos) peers.set(r.pid, [r, co])
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
    if (pids === undefined) return this.note(`could not tell which process \`${label}\` stops; peers_report shows each peer's pid.`)
    const table = await this.p.table()
    for (const pid of pids) {
      let [p, hops] = [pid, 0]
      while (table.has(p) && p > 1 && p !== this.pid && !peers.has(p) && hops < 64) [p, hops] = [table.get(p)!.ppid, hops + 1]
      if (peers.has(p)) this.stop('kill', String(pid), `\`${label}\` would stop process ${pid}, which belongs to ${who(...peers.get(p)!)}.`)
    }
  }

  private async edit(at: Where, rel: string) {
    const [top, common] = at
    const key = `dirty:${top}|${rel}`
    const changed = owns(this.own(top), rel) || this.now - (this.r.acks[key] ?? 0) < NOTE_TTL ? [] : (await this.p.status(at, [], rel)) ?? []
    if (changed.length > 0 && (await this.others(at, changed))(rel)) {
      this.once(key, `${rel} has uncommitted changes this session did not make (${await this.owner(top, [rel])}); read it before overwriting.`)
    }
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
