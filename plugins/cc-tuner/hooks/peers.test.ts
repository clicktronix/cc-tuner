import type { On, PromptSubmitInput } from 'claude-code'
import { expect, test } from 'claude-code/testing'
import { Peers, UNKNOWN, ownedOpen, type Event, type Rec, type Step, type World } from './peers'

// A machine in memory: files, git checkouts, a process table, and the answers of the few commands the guard
// runs (`ps`, `git status`, `git rev-parse`, merge-tree, `pgrep`, `lsof`). Every session is a real Peers over
// it with its own Claude pid, so records are written by the code that writes them in a session. Real git,
// `ps` and the engine's `$.fs` are driven end to end by tests/flow/test_peers.sh.
const DIR = '/peers'
const USER = '/user/resources.json'
const LSTART = 'Sat Nov 14 00:07:21 2026'

class Machine {
  files = new Map<string, { text: string; mtimeMs: number }>()
  dirs = new Set<string>(['/'])
  procs = new Map<number, { ppid: number; start: string; name: string; args: string }>()
  status = new Map<string, string[]>()
  shas = new Map<string, string>()
  merges = new Map<string, string>()
  ports = new Map<number, number>()
  stopped: string[] = []
  dirTimes = new Map<string, number>()
  clock = 1_800_000_000_000
  ran: string[][] = []
  refs = new Set<string>()
  symbolic = new Map<string, string>()
  halfOnce = new Set<string>()
  envs: Record<string, Record<string, string> | undefined> = {}
  failing = new Map<string, number>()
  private tick = 1
  private nextPid = 1000

  mkdir(p: string) { for (let d = p; d !== '/' && !this.dirs.has(d); d = d.slice(0, d.lastIndexOf('/')) || '/') this.dirs.add(d) }
  put(p: string, text: string) { this.mkdir(p.slice(0, p.lastIndexOf('/')) || '/'); this.files.set(p, { text, mtimeMs: this.tick++ }) }
  advance(seconds: number) { this.clock += seconds * 1000 }
  // What `$(cat file)` gives in the shell: the text without its trailing newlines.
  cat(p: string) { return (this.files.get(p)?.text ?? '').replace(/\n+$/, '') }
  drop(dir: string) {
    for (const p of [...this.files.keys()]) if (p.startsWith(`${dir}/`)) this.files.delete(p)
    this.dirs.delete(dir)
  }

  // A process: a stand-in Claude by default, its start time distinct from every other one.
  spawn(ppid = 1, name = 'sleep', args = name): number {
    const pid = this.nextPid++
    this.procs.set(pid, { ppid, start: `Sat Nov 14 00:${String(Math.floor(pid / 60) % 60).padStart(2, '0')}:${String(pid % 60).padStart(2, '0')} 2026`, name, args })
    return pid
  }
  // The process ends, and the minute a start time is kept for passes.
  end(pid: number) { this.procs.delete(pid); this.advance(61) }

  repo(top: string, branch = 'main'): string {
    this.mkdir(`${top}/.git`)
    this.put(`${top}/.git/HEAD`, `ref: refs/heads/${branch}\n`)
    this.shas.set(top, `sha-${top}`)
    return top
  }
  worktree(main: string, top: string, branch: string): string {
    const gd = `${main}/.git/worktrees/${top.slice(top.lastIndexOf('/') + 1)}`
    this.mkdir(top)
    this.put(`${top}/.git`, `gitdir: ${gd}\n`)
    this.put(`${gd}/HEAD`, `ref: refs/heads/${branch}\n`)
    this.put(`${gd}/commondir`, '../..\n')
    this.shas.set(top, `sha-${top}`)
    return top
  }
  head(top: string, branch: string | undefined) {
    const git = this.files.get(`${top}/.git`)
    const gd = git === undefined ? `${top}/.git` : git.text.slice(7).trim()
    this.put(`${gd}/HEAD`, branch === undefined ? 'abc123\n' : `ref: refs/heads/${branch}\n`)
  }
  dirty(top: string, ...entries: string[]) { this.status.set(top, [...(this.status.get(top) ?? []), ...entries]) }

  rec(name: string): Rec { return JSON.parse(this.files.get(`${DIR}/${name}.json`)!.text) as Rec }
  edit(name: string, change: (r: Rec) => void) { const r = this.rec(name); change(r); this.put(`${DIR}/${name}.json`, JSON.stringify(r)) }
  records(pid: number) { return [...this.files].filter(([p, f]) => p.startsWith(`${DIR}/`) && p.endsWith('.json') && f.text.includes(`"pid":${pid},`)).length }

  ps(pids?: number[]): string {
    return [...this.procs].filter(([p]) => pids === undefined || pids.includes(p)).map(([p, x]) => `${p} ${x.ppid} ${x.start} /bin/${x.name}`).join('\n')
  }

  world(pid: number): World {
    return {
      dir: async () => DIR,
      config: async () => USER,
      read: async p => {
        const f = this.files.get(p)
        if (f === undefined) throw new Error(`ENOENT ${p}`)
        return this.halfOnce.delete(p) ? f.text.slice(0, 20) : f.text
      },
      write: async (p, text) => this.put(p, text),
      list: async d => {
        if (!this.dirs.has(d)) throw new Error(`ENOENT ${d}`)
        const files = [...this.files].filter(([p]) => p.slice(0, p.lastIndexOf('/')) === d)
          .map(([p, f]) => ({ name: p.slice(d.length + 1), kind: 'file', size: f.text.length, mtimeMs: f.mtimeMs }))
        const dirs = [...this.dirs].filter(p => p !== '/' && p.slice(0, p.lastIndexOf('/')) === d).map(p => ({ name: p.slice(d.length + 1), kind: 'dir', size: 0, mtimeMs: 0 }))
        return [...files, ...dirs]
      },
      stat: async p => {
        const f = this.files.get(p)
        return this.dirs.has(p) ? { kind: 'dir', realPath: p, mtimeMs: this.dirTimes.get(p) } : f === undefined ? undefined : { kind: 'file', realPath: p, mtimeMs: f.mtimeMs, size: f.text.length }
      },
      run: async (argv, init) => {
        this.ran.push([...argv])
        this.envs[argv[0]!] = init?.env
        const bare = argv[0] === 'git' ? argv.filter((x, i) => x !== '-c' && argv[i - 1] !== '-c') : argv
        return { exitCode: this.failing.get(bare[0] === 'git' ? `git ${bare[3]}` : bare[0]!) ?? 0, ...this.answer(pid, bare) }
      },
      now: () => this.clock,
    }
  }

  private answer(pid: number, argv: readonly string[]): { exitCode?: number; stdout: string } {
    const [cmd, ...a] = argv
    if (cmd === '/bin/sh' && a[1] === 'echo $PPID') return { stdout: `${pid}\n` }
    if (cmd === 'ps') return { stdout: this.ps(a.includes('-p') ? a[a.indexOf('-p') + 1]!.split(',').map(Number) : undefined) }
    if (cmd === 'git' && a[2] === 'status') {
      const spec = a.includes('--') ? a.slice(a.indexOf('--') + 1) : undefined
      return { stdout: (this.status.get(a[1]!) ?? []).filter(e => spec === undefined || spec.includes(e.slice(3))).map(e => `${e}\0`).join('') }
    }
    if (cmd === 'git' && a[2] === 'rev-parse' && a.includes('--verify')) return this.refs.has(a[a.length - 1]!) ? { stdout: 'sha\n' } : { exitCode: 1, stdout: '' }
    if (cmd === 'git' && a[2] === 'rev-parse') return { stdout: `${this.shas.get(a[1]!) ?? ''}\n` }
    if (cmd === 'git' && a[2] === 'symbolic-ref') return this.symbolic.has(a[1]!) ? { stdout: `${this.symbolic.get(a[1]!)}\n` } : { exitCode: 1, stdout: '' }
    // The lease scripts, as the shell runs them: one atomic step each.
    if (cmd === '/bin/sh' && a[1]?.includes('printf %s')) {
      const [lock, seen, info] = a.slice(3) as [string, string, string]
      if (!this.dirs.has(lock.slice(0, lock.lastIndexOf('/')))) return { exitCode: 1, stdout: '' }
      const old = this.clock - (this.dirTimes.get(lock) ?? 0) > 540_000
      if (this.dirs.has(lock) && this.cat(`${lock}/holder.json`) === seen && (seen !== '' || old)) this.drop(lock)
      if (this.dirs.has(lock)) return { exitCode: 1, stdout: '' }
      this.put(`${lock}/holder.json`, info)
      this.dirTimes.set(lock, this.clock)
      return { stdout: '' }
    }
    if (cmd === '/bin/sh' && a[1]?.includes('holder.json') && a[1].includes('rm -rf')) {
      if (this.cat(`${a[3]}/holder.json`) !== a[4]) return { exitCode: 1, stdout: '' }
      this.drop(a[3]!)
      return { stdout: '' }
    }
    if (cmd === '/bin/sh' && a[1]?.includes('merge-tree')) {
      const out = this.merges.get(`${a[6]}-${a[7]}`)
      return out === undefined ? { exitCode: 0, stdout: 'tree\n' } : { exitCode: 1, stdout: `tree\n${out}\n\nCONFLICT\n` }
    }
    if (cmd === '/bin/sh' && a[1]?.includes('mkdir -p')) { this.mkdir(a[3]!); return { stdout: '' } }
    if (cmd === '/bin/sh' && a[1]?.includes('rm -f')) {
      for (const n of a.slice(4)) this.files.delete(`${a[3]}/${n}`)
      return { stdout: '' }
    }
    if (cmd === 'pgrep') {
      const [mode, pat] = a.includes('-x') ? ['x', a[a.indexOf('-x') + 1]!] : ['f', a[a.length - 1]!]
      return { stdout: [...this.procs].filter(([, x]) => (mode === 'x' ? x.name === pat : x.args.includes(pat))).map(([p]) => p).join('\n') }
    }
    if (cmd === 'lsof') return { stdout: `${this.ports.get(Number(a[a.length - 1]!.slice(1))) ?? ''}\n` }
    return { exitCode: 127, stdout: '' }
  }
}

// A session of the machine: its Claude pid, and the events it sends as the adapter sends them.
class Session {
  readonly peers: Peers
  constructor(readonly m: Machine, readonly pid: number, readonly sid: string) { this.peers = new Peers(m.world(pid)) }
  check(ev: Partial<Event> & { cwd: string }) { return this.peers.check({ session_id: this.sid, phase: 'before', ...ev }) }
  // A call with no steps the adapter could read: a writer call, as any unknown command is.
  async touch(cwd: string) {
    const v = await this.check({ tool: 'Bash', cwd })
    if (v.decision !== 'stop') await this.check({ phase: 'after', tool: 'Bash', cwd })
    return v
  }
  // The guard's `before`, as the adapter sends it, and its `after` once the engine let the call run.
  before(cwd: string, ...steps: (string | Partial<Step>)[]) {
    return this.check({ tool: 'Bash', cwd, steps: steps.map(s => (typeof s === 'string' ? step(s) : { ...step(''), ...s })) })
  }
  after(cwd: string, steps: (string | Partial<Step>)[], seen?: Record<string, string>, ok = true) {
    return this.check({ phase: 'after', tool: 'Bash', cwd, steps: steps.map(s => (typeof s === 'string' ? step(s) : { ...step(''), ...s })), seen, ok })
  }
  async bash(cwd: string, ...steps: (string | Partial<Step>)[]) {
    const v = await this.before(cwd, ...steps)
    if (v.decision !== 'stop') await this.after(cwd, steps, v.seen)
    return v
  }
  edited(cwd: string, path: string, tool = 'Edit') { return this.check({ phase: 'after', tool, cwd, path }) }
  start(cwd: string, sid = this.sid) { return this.peers.check({ session_id: sid, phase: 'start', cwd }) }
  report(cwd: string) { return this.peers.report(cwd) }
}
const step = (text: string, dir = ''): Step => ({ words: text === '' ? [] : text.split(' '), dir, writes: false })

function machine() {
  const m = new Machine()
  m.mkdir(DIR)
  let n = 0
  const session = (sid = `s${++n}`, pid = m.spawn()) => new Session(m, pid, sid)
  return { m, session }
}

// A Bash call as the adapter makes it: `before`, the command's effect on the machine, then `after` with
// what `before` saw.
async function call(s: Session, cwd: string, steps: (string | Partial<Step>)[], effect?: () => void, ok = true) {
  const v = await s.before(cwd, ...steps)
  if (v.decision !== 'stop') {
    effect?.()
    await s.after(cwd, steps, v.seen, ok)
  }
  return v
}
const at = (dir: string, text: string): Partial<Step> => step(text, dir)
const then = (text: string): Partial<Step> => step(text)
const writes = (text: string): Partial<Step> => ({ ...step(text), writes: true })

// --- the adapter: the hooks module in front of the guard ----------------------------------------------------
// The module reads and writes records with $.fs and runs `ps` and git with $.process.run; the test's hooks
// stand for those, backed by the machine.
let sessionId = 'e1'
let peersDir: string | undefined = DIR
const logged: string[] = []
function engine(on: On, m: Machine, pid: number, effect: (command: string) => void = () => {}, broken = () => false,
  task: (command: string) => string | undefined = () => undefined) {
  const w = m.world(pid)
  sessionId = 'e1'
  peersDir = DIR
  logged.length = 0
  on('prompt.submit', (_, e) => ({ text: e.text, context: e.context }))
  on('session.id', () => ({ value: sessionId }))
  on('session.cwd', () => ({ value: '/w/r' }))
  on('ui.log', (_, e) => { logged.push(e.text); return { value: undefined } })
  on('env.get', (_, e) => ({ value: e.name === 'CC_TUNER_PEERS_DIR' ? peersDir : e.name === 'CC_TUNER_PEERS_CONFIG' ? USER : undefined }))
  on('fs.read', async (_, e) => ({ value: await w.read(e.path) }))
  on('fs.write', async (_, e) => { await w.write(e.path, e.text); return { value: undefined } })
  on('fs.list', async (_, e) => ({ value: (await w.list(e.path ?? '.')).map(x => ({ ...x, kind: x.kind as 'file' | 'dir', isLink: false })) }))
  on('fs.stat', async (_, e) => {
    const st = await w.stat(e.path)
    if (st === undefined) throw new Error(`ENOENT ${e.path}`)
    return { value: { kind: st.kind as 'file' | 'dir', size: st.size ?? 0, mtimeMs: st.mtimeMs ?? 0, isLink: false, realPath: st.realPath } }
  })
  on('process.run', async (_, e) => {
    if (broken()) throw new Error('injected process failure')
    return { value: { ...await w.run(e.argv), stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  const ran: string[] = []
  on('tool.call', { tool: 'Bash' }, (_, e) => {
    if (e.command === 'denied') return { deny: 'denied by the engine' }
    ran.push(e.command)
    effect(e.command)
    return { result: { stdout: '', stderr: '', interrupted: false, backgroundTaskId: task(e.command) } }
  })
  on('tool.call', { tool: 'TaskStop' }, (_, e) => { m.stopped.push(String(e.task_id)); return { result: { message: 'stopped', task_id: String(e.task_id), task_type: 'bash' } } })
  on('session.end', (_, e) => ({ sessionId: e.sessionId }))
  on('tool.call', { tool: /^mcp__(?!cc-tuner__)/ }, (_, e) => { ran.push(e.tool); return { result: {} } })
  const answer = (path: string) => (path.endsWith('.fail') ? { result: {}, isError: true as const } : { result: {} })
  on('tool.call', { tool: 'Edit' }, (_, e) => answer(e.file_path))
  on('tool.call', { tool: 'Write' }, (_, e) => answer(e.file_path))
  on('tool.call', { tool: 'NotebookEdit' }, (_, e) => answer(e.notebook_path))
  return ran
}

test('record-written: a Bash call writes the session record through $.fs, with no python', async ($, on) => {
  const { m } = machine()
  m.repo('/w/r')
  const me = m.spawn()
  engine(on, m, me)
  await $.tool.call({ tool: 'Bash', command: 'npm test' })
  expect(m.files.has(`${DIR}/e1.json`), 'record-written').toBe(true)
  expect(m.rec('e1')).toMatchObject({ session_id: 'e1', pid: me, checkouts: { '/w/r': { expected: 'main' } } })
  expect(m.ran.some(argv => argv.join(' ').includes('peers.sh') || argv[0] === 'python3')).toBe(false)
})

test('the module stops a switch next to a writer, and the command never runs', async ($, on) => {
  const { m, session } = machine()
  m.repo('/w/r')
  await session('peer').bash('/w/r', 'npm test')
  const ran = engine(on, m, m.spawn())
  const { deny } = await $.tool.call({ tool: 'Bash', command: 'git switch x' })
  expect(deny).toContain('switching branches there changes its files')
  expect(deny).toContain('CC_TUNER_ACK=')
  expect(ran).toEqual([])
})

test('the module moves the expectation only when HEAD changed during its own switch', async ($, on) => {
  const { m } = machine()
  m.repo('/w/r')
  engine(on, m, m.spawn(), command => { if (command.includes('switch -c x')) m.head('/w/r', 'x') })
  await $.tool.call({ tool: 'Bash', command: 'git status' })
  await $.tool.call({ tool: 'Bash', command: 'git switch -c x && git commit -m m' })
  expect(m.rec('e1').checkouts['/w/r']!.expected).toBe('x')
})

test('the Claude pid is read once per module load', async ($, on) => {
  const { m } = machine()
  m.repo('/w/r')
  engine(on, m, m.spawn())
  for (const command of ['ls', 'git status', 'npm test']) await $.tool.call({ tool: 'Bash', command })
  expect(m.ran.filter(argv => argv[0] === '/bin/sh' && argv[2] === 'echo $PPID').length).toBe(1)
})

test('an edit records its path only after it succeeded', async ($, on) => {
  const { m } = machine()
  m.repo('/w/r')
  engine(on, m, m.spawn())
  await $.tool.call({ tool: 'Edit', file_path: '/w/r/a.ts', old_string: 'a', new_string: 'b' })
  await $.tool.call({ tool: 'Write', file_path: '/w/r/b.ts', content: 'b' })
  await $.tool.call({ tool: 'NotebookEdit', notebook_path: '/w/r/c.ipynb', new_source: 'c' })
  await $.tool.call({ tool: 'Write', file_path: '/w/r/d.fail', content: 'd' })
  expect(m.rec('e1').checkouts['/w/r']!.paths).toEqual(['a.ts', 'b.ts', 'c.ipynb'])
})

test('a note rides after the result of a Bash call and of an edit, and the call runs', async ($, on) => {
  const { m, session } = machine()
  m.repo('/w/r')
  await session('peer').bash('/w/r', 'npm test')
  const ran = engine(on, m, m.spawn())
  const edit = await $.tool.call({ tool: 'Edit', file_path: '/w/r/a.ts', old_string: 'a', new_string: 'b' })
  expect(edit.context?.join(' ')).toContain('also writes in /w/r')
  const bash = await $.tool.call({ tool: 'Bash', command: 'git -c x=y reset --hard' })
  expect(bash.deny).toBeUndefined()
  expect((await $.tool.call({ tool: 'Bash', command: 'git --git-dir=x status' })).context?.join(' ')).toContain('could not read')
  expect((await $.tool.call({ tool: 'Bash', command: 'git status' })).context).toBeUndefined()
  expect(ran).toEqual(['git -c x=y reset --hard', 'git --git-dir=x status', 'git status'])
})

test('an ack is recorded from the prefix and stripped before the command runs; only an assignment is one', async ($, on) => {
  const { m } = machine()
  m.repo('/w/r')
  m.dirty('/w/r', ' M f')
  const ran = engine(on, m, m.spawn())
  const { deny } = await $.tool.call({ tool: 'Bash', command: 'git reset --hard' })
  const key = /CC_TUNER_ACK=([0-9a-f]{8})/.exec(deny ?? '')![1]!
  expect((await $.tool.call({ tool: 'Bash', command: `CC_TUNER_ACK=${key} git reset --hard` })).deny).toBeUndefined()
  expect(typeof m.rec('e1').acks[key]).toBe('number')
  expect(ran).toEqual(['git reset --hard'])
  await $.tool.call({ tool: 'Bash', command: 'echo CC_TUNER_ACK=00000000 git reset --hard' })
  await $.tool.call({ tool: 'Bash', command: 'FOO=1 CC_TUNER_ACK=11111111 ls' })
  expect(Object.keys(m.rec('e1').acks).sort()).toEqual([key, '11111111'].sort())
  expect(ran.slice(1)).toEqual(['echo CC_TUNER_ACK=00000000 git reset --hard', 'FOO=1 CC_TUNER_ACK=11111111 ls'])
})

test('a secret dump is refused before the guard, acked or not', async ($, on) => {
  const { m } = machine()
  m.repo('/w/r')
  const ran = engine(on, m, m.spawn())
  for (const command of ['CC_TUNER_ACK=ab12cd34 env', 'cd app && env']) {
    expect((await $.tool.call({ tool: 'Bash', command })).deny).toContain("awk 'BEGIN { for (k in ENVIRON) print k }'")
  }
  expect(ran).toEqual([])
  expect(m.ran).toEqual([])
})

test('a guard that fails never blocks the call', async ($, on) => {
  const { m } = machine()
  m.repo('/w/r')
  const ran = engine(on, m, m.spawn(), undefined, () => true)
  m.files.delete('/w/r/.git/HEAD')
  m.dirs.delete(DIR)
  const first = await $.tool.call({ tool: 'Bash', command: 'npm test' })
  expect(first.deny).toBeUndefined()
  expect(ran).toEqual(['npm test'])
  expect(first.context?.join(' '), 'guard-failure-is-said-once').toContain('the peers guard is inactive (')
  expect(logged.some(l => l.includes('peers guard failed: ')), 'guard-failure-is-logged').toBe(true)
  expect((await $.tool.call({ tool: 'Bash', command: 'npm test' })).context).toBeUndefined()
})

const prompt = async ($: { prompt: { submit(input: PromptSubmitInput): Promise<{ context?: readonly string[] }> } }, text = 'go') =>
  ((await $.prompt.submit({ text, wait: false, origin: { kind: 'composer' } })).context ?? []).join('\n')

test('the start line reaches the model from the first prompt after a start, a clear and a resume, once each', async ($, on) => {
  const { m, session } = machine()
  m.repo('/w/r')
  await session('peer').touch('/w/r')
  engine(on, m, m.spawn())
  expect(await prompt($), 'startup').toContain('cc-tuner: live peers: main (r, pid')
  expect(await prompt($), 'the second prompt of the session').toBe('')
  await $.session.end({ sessionId: 'e1', resume: { id: 'e1' }, reason: 'clear' })
  sessionId = 'e2'
  expect(await prompt($), 'clear').toContain('cc-tuner: live peers: main (r, pid')
  expect(await prompt($), 'the second prompt after the clear').toBe('')
  sessionId = 'e3'
  expect(await prompt($), 'resume').toContain('cc-tuner: live peers: main (r, pid')
})

test('the start line is silent without peers', async ($, on) => {
  const { m } = machine()
  m.repo('/w/r')
  engine(on, m, m.spawn())
  expect(await prompt($)).toBe('')
})

test('peers_report, peers_claim and peers_release are tools the module answers', async ($, on) => {
  const { m, session } = machine()
  m.repo('/w/r')
  await session('peer').touch('/w/r')
  m.put('/w/r/plan.md', '## Slice 1 — A\nOwned paths: lib/\n- [ ] a\n')
  engine(on, m, m.spawn())
  expect((await $.tool.call({ tool: 'mcp__cc-tuner__peers_report' })).result).toContain('1 live peer')
  expect((await $.tool.call({ tool: 'mcp__cc-tuner__peers_claim', plan: 'plan.md' })).result).toContain('1 live peer')
  expect(m.rec('e1').claims['plan.md']?.paths).toEqual(['lib/'])
  expect((await $.tool.call({ tool: 'mcp__cc-tuner__peers_release', key: 'chrome' })).result).toBe('cc-tuner: chrome is not leased to this session.')
})

// --- records ---------------------------------------------------------------------------------------------
test('record: written on first touch with the pid, start time, session and first branch', async () => {
  const { m, session } = machine()
  const r1 = m.repo('/w/r1')
  const s1 = session('s1')
  expect(await s1.touch(r1)).toEqual({ decision: 'allow' })
  expect(m.rec('s1')).toMatchObject({ pid: s1.pid, start: m.procs.get(s1.pid)!.start, session_id: 's1' })
  expect(m.rec('s1').checkouts[r1]!.expected, 'record-expected-first-touch').toBe('main')
  m.head(r1, 'other')
  await s1.touch(r1)
  expect(m.rec('s1').checkouts[r1]!.expected, 'record-expected-stays').toBe('main')
})

test('record: edited paths are recorded after a successful edit, under the target\'s checkout', async () => {
  const { m, session } = machine()
  const [r1, r2] = [m.repo('/w/r1'), m.repo('/w/r2')]
  const s1 = session('s1')
  const paths = (top: string) => m.rec('s1').checkouts[top]?.paths
  await s1.check({ tool: 'Edit', cwd: r1, path: `${r1}/src/a.txt` })
  expect(paths(r1), 'record-edit-before-is-not-recorded').toEqual([])
  await s1.edited(r1, `${r1}/src/a.txt`)
  await s1.edited(r1, 'src/b.txt', 'Write')
  expect(paths(r1)).toEqual(['src/a.txt', 'src/b.txt'])
  await s1.check({ phase: 'after', tool: 'Edit', cwd: r1, path: `${r1}/src/c.txt`, ok: false })
  await s1.check({ phase: 'after', tool: 'Bash', cwd: r1, path: `${r1}/src/d.txt` })
  expect(paths(r1), 'record-failed-or-bash-call-adds-no-path').toEqual(['src/a.txt', 'src/b.txt'])
  await s1.edited(r1, `${r2}/other.txt`)
  expect(paths(r2), 'record-scope-is-the-target-not-the-cwd').toEqual(['other.txt'])
  await s1.edited(r1, `${r1}/n.ipynb`, 'NotebookEdit')
  expect(paths(r1)).toContain('n.ipynb')
  expect(typeof m.rec('s1').checkouts[r1]!.writer, 'guard-edit-makes-a-writer').toBe('number')
})

test('record: parallel calls of one session lose no path and make one record', async () => {
  const { m, session } = machine()
  const r1 = m.repo('/w/r1')
  const s2 = session('s2')
  await Promise.all(Array.from({ length: 12 }, (_, i) => s2.edited(r1, `${r1}/p${i}.txt`)))
  expect(m.rec('s2').checkouts[r1]!.paths.length).toBe(12)
  expect(m.records(s2.pid)).toBe(1)
})

test('record: a dead pid is a tombstone, no longer a peer, its edits kept', async () => {
  const { m, session } = machine()
  const r1 = m.repo('/w/r1')
  const [s3, me] = [session('s3'), session('me')]
  await s3.edited(r1, `${r1}/src/a.txt`)
  await me.touch(r1)
  expect(await me.report(r1)).toContain(`pid ${s3.pid}`)
  m.end(s3.pid)
  expect(await me.report(r1)).not.toContain(`pid ${s3.pid}`)
  expect(m.rec('s3').checkouts[r1]!.paths).toEqual(['src/a.txt'])
})

test('liveness-pid-reuse', async () => {
  const { m, session } = machine()
  const r1 = m.repo('/w/r1')
  const [s4, me] = [session('s4'), session('me')]
  await s4.touch(r1)
  await me.touch(r1)
  expect(await me.report(r1), 'liveness-control-matching-start-is-live').toContain(`pid ${s4.pid}`)
  m.edit('s4', r => { r.start = 'Mon Jan  1 00:00:00 2001' })
  expect(await me.report(r1), 'a record whose pid was reused reads as live').not.toContain(`pid ${s4.pid}`)
})

test('record: a tombstone untouched for 24 h is removed, and kept before', async () => {
  const { m, session } = machine()
  const r1 = m.repo('/w/r1')
  const [a, b, me] = [session('a'), session('b'), session('me')]
  await a.touch(r1)
  await b.touch(r1)
  m.end(a.pid)
  m.end(b.pid)
  const now = Math.floor(m.clock / 1000)
  m.edit('a', r => { r.seen = now - 25 * 3600 })
  m.edit('b', r => { r.seen = now - 23 * 3600 })
  await me.report(r1)
  expect(m.files.has(`${DIR}/a.json`), 'record-tombstone-expires-after-24h').toBe(false)
  expect(m.files.has(`${DIR}/b.json`), 'record-tombstone-kept-within-24h').toBe(true)
})

test('record: resume adopts the tombstone of its session id', async () => {
  const { m, session } = machine()
  const r1 = m.repo('/w/r1')
  const old = session('s5')
  await old.edited(r1, `${r1}/kept.txt`)
  m.end(old.pid)
  const resumed = session('s5')
  await resumed.start(r1)
  expect(m.rec('s5')).toMatchObject({ pid: resumed.pid, start: m.procs.get(resumed.pid)!.start })
  expect(m.rec('s5').checkouts[r1]!.paths).toEqual(['kept.txt'])
  expect(m.records(resumed.pid)).toBe(1)
})

test('record: a new session id in the same process (/clear) drops acks and claims, keeps the kept task, and follows the id', async () => {
  const { m, session } = machine()
  const r1 = m.repo('/w/r1')
  const s6 = session('s6')
  await s6.touch(r1)
  m.edit('s6', r => { r.acks = { k: 1 }; r.claims = { 'plan.md': { repo: 'x', paths: ['a'] } }; r.kept = [{ id: 'b1', key: 'dev server' }] })
  await s6.start(r1, 's6b')
  expect(m.rec('s6')).toMatchObject({ acks: {}, claims: {}, kept: [{ id: 'b1', key: 'dev server' }], session_id: 's6b' })
  expect(m.records(s6.pid)).toBe(1)
})

test('record: a malformed or half-written record is skipped with a note', async () => {
  const { m, session } = machine()
  const r1 = m.repo('/w/r1')
  const [peer, me] = [session('peer'), session('me')]
  await peer.touch(r1)
  await me.touch(r1)
  m.put(`${DIR}/bad.json`, '{not json')
  m.put(`${DIR}/shape.json`, '[]')
  m.put(`${DIR}/half.json`, m.files.get(`${DIR}/peer.json`)!.text.slice(0, 20))
  const out = await me.report(r1)
  for (const name of ['bad.json', 'shape.json', 'half.json']) expect(out).toContain(`note: skipped malformed record ${name}`)
  expect(out, 'record-malformed-skips-only-itself').toContain(`pid ${peer.pid}`)
})

test('record: a nested claude -p counts as the outermost claude above it', async () => {
  const { m } = machine()
  const r1 = m.repo('/w/r1')
  const outer = m.spawn(1, 'claude')
  const shell = m.spawn(outer, 'bash')
  const inner = m.spawn(shell, 'claude')
  await new Session(m, inner, 's7').touch(r1)
  expect(m.rec('s7').pid).toBe(outer)
  await new Session(m, outer, 's7').touch(r1)
  expect(m.records(outer)).toBe(1)
})

// --- report: peers by repository and by product, their claims, edits and conflicts ------------------------
function products() {
  const { m, session } = machine()
  const [ra, rb, rc, rd] = ['/w/ra', '/w/rb', '/w/rc', '/w/rd'].map(r => m.repo(r)) as [string, string, string, string]
  const wa = m.worktree(ra, '/w/wa', 'feat-a')
  const wb = m.worktree(ra, '/w/wb', 'feat-b')
  for (const [top, p] of [[ra, 'acme'], [wa, 'acme'], [wb, 'acme'], [rb, 'acme'], [rc, 'other']]) m.put(`${top}/.claude/cc-tuner-resources.json`, JSON.stringify({ product: p }))
  const [sr, sa, sw, sb, sc, sd] = ['sr', 'sa', 'sw', 'sb', 'sc', 'sd'].map(n => session(n)) as Session[] as [Session, Session, Session, Session, Session, Session]
  return { m, session, ra, rb, rc, rd, wa, wb, sr, sa, sw, sb, sc, sd }
}

test('report: peers of the repository, its worktrees and its product; not others', async () => {
  const { ra, rb, rc, rd, wa, wb, sr, sa, sw, sb, sc, sd } = products()
  for (const [s, top] of [[sr, ra], [sa, wa], [sw, wb], [sb, rb], [sc, rc], [sd, rd]] as const) await s.touch(top)
  const out = await sr.report(ra)
  expect(out).toContain(`pid ${sa.pid}  feat-a  ${wa}`)
  expect(out).toContain(`pid ${sw.pid}  feat-b  ${wb}`)
  expect(out).toContain(`pid ${sb.pid}  main  ${rb}`)
  for (const s of [sc, sd, sr]) expect(out).not.toContain(`pid ${s.pid} `)
  expect(await sd.report(rd)).toContain('no live peers')
  const back = await sb.report(rb)
  expect(back, 'report-product-is-symmetric').toContain(`pid ${sr.pid}`)
  expect(back, 'report-product-reaches-the-worktrees').toContain(`pid ${sa.pid}`)
})

test('report: claims, edited paths, and merge-tree conflicts of same-repository branches only, cached per SHA pair', async () => {
  const { m, ra, rb, wa, wb, sr, sa, sw, sb } = products()
  for (const [s, top] of [[sr, ra], [sa, wa], [sw, wb], [sb, rb]] as const) await s.touch(top)
  m.edit('sa', r => { r.claims = { 'plan.md': { repo: r.checkouts[wa]!.repo, paths: ['docs/', 'lib/x.ts'] } } })
  await sa.edited(wa, `${wa}/lib/x.ts`)
  m.merges.set(`sha-${ra}-sha-${wa}`, 'f.txt')
  m.shas.set(rb, `sha-${ra}`)
  const out = await sr.report(ra)
  expect(out).toContain('claims: docs/, lib/x.ts')
  expect(out).toContain('edited: lib/x.ts')
  expect(out).toContain('conflicts with HEAD: f.txt')
  expect(out.split('\n').filter(l => l.includes('conflicts with HEAD')).length).toBe(1)
  expect(m.ran.filter(a => a[2]?.includes('merge-tree')).map(a => a[8])).toEqual([`sha-${wa}`, `sha-${wb}`])
  expect(m.files.has(`${DIR}/merge/v1/sha-${ra}-sha-${wa}`), 'report-caches-per-sha-pair').toBe(true)
  m.put(`${DIR}/merge/v1/sha-${ra}-sha-${wa}`, '["cached.txt"]')
  expect(await sr.report(ra)).toContain('conflicts with HEAD: cached.txt')
})

test('claim publishes the open Owned paths and prints their overlap', async () => {
  const { m, ra, wa, sr, sa } = products()
  await sr.touch(ra)
  await sa.touch(wa)
  await sa.edited(wa, `${wa}/lib/x.ts`)
  const plan = (first: string, second: string) => ['**Spec:** s.md', '', '## Slice 1 — Old', 'Owned paths: src/old/', `- [${first}] a`, '',
    '## Slice 2 — New', 'Blocked by: 1', 'Owned paths: lib/, docs/y.md', `- [${second}] b`].join('\n')
  m.put(`${ra}/docs/task-plans/p.md`, plan('x', ' '))
  const out = await sr.peers.claim(ra, 'sr', 'docs/task-plans/p.md')
  expect(m.rec('sr').claims['docs/task-plans/p.md']?.paths).toEqual(['lib/', 'docs/y.md'])
  expect(out).toContain('overlap with your claims: lib/ ~ lib/x.ts')
  expect(out).toContain(`pid ${sa.pid}`)
  expect(out).not.toContain('src/old')
  expect(out.split('\n').filter(l => l.includes('overlap with your claims')).length).toBe(1)
  m.put(`${ra}/docs/task-plans/p.md`, plan('x', 'x'))
  await sr.peers.claim(ra, 'sr', 'docs/task-plans/p.md')
  expect(m.rec('sr').claims).toEqual({})
  expect(await sr.peers.claim(ra, 'sr', 'docs/task-plans/missing.md')).toBe('cc-tuner: cannot read docs/task-plans/missing.md')
  expect(ownedOpen('## Slice 1 — A\nOwned paths: a/, b\n- [X] t\n## Slice 2 — B\nOwned paths: c\n')).toEqual(['c'])
})

// --- the start line ----------------------------------------------------------------------------------------
test('start: the line appears only with live peers or a kept task', async () => {
  const { m, session } = machine()
  const rs = m.repo('/w/rs')
  const [p1, p2] = [session('t1'), session('t2')]
  expect((await p1.start(rs)).line).toBe('')
  const { line } = await p2.start(rs)
  expect(line).toBe(`cc-tuner: live peers: main (rs, pid ${p1.pid}). More: the peers_report tool.`)
  expect((await p2.start(rs, 't2c')).line).toContain('live peers: main')
  expect((await p2.start(rs, 't2c')).line).toContain('live peers: main')
  m.edit('t2', r => { r.kept = [{ id: 'b1', key: 'dev server' }] })
  m.end(p1.pid)
  const kept = (await p2.start(rs, 't2c')).line!
  expect(kept).toContain('kept at /clear: dev server (b1)')
  expect(kept).not.toContain('live peers')
  m.edit('t2', r => { r.kept = [] })
  expect((await p2.start(rs, 't2c')).line).toBe('')
})

test('start: the line reaches the product, and skips an unrelated one', async () => {
  const { ra, rb, rc, sr, sb, sc } = products()
  await sr.touch(ra)
  expect((await sb.start(rb)).line).toContain('live peers:')
  expect((await sc.start(rc)).line).toBe('')
})

// --- the guard learns from commands: writers, and the branch a session expects ------------------------------
const writerOf = (m: Machine, sid: string, top: string) => m.rec(sid).checkouts[top]?.writer ?? null

test('guard: a known read-only form is no writer; any other form, a redirection or an unknown command is', async () => {
  const { m, session } = machine()
  const rg = m.repo('/w/rg')
  const g = session('g1')
  await g.bash(rg, 'git status')
  for (const form of ['git status', 'git log --oneline', 'git diff', 'git show HEAD', 'ls -la', 'cat x', 'grep -r a .', 'rg a', 'find . -name x']) {
    m.edit('g1', r => { r.checkouts[rg]!.writer = null })
    await g.bash(rg, form)
    expect(writerOf(m, 'g1', rg), form).toBeNull()
  }
  for (const steps of [['npm test'], ['git commit -m m'], ['find . -delete'], ['find . -exec rm {} ;'], ['rg --pre cmd a'], ['git diff --output=f'],
    ['git'], ['git --git-dir=x log'], ['sed -i s/a/b/ f'], [writes('cat x')], ['git status', then('npm test')]] as (string | Partial<Step>)[][]) {
    m.edit('g1', r => { r.checkouts[rg]!.writer = null })
    await g.bash(rg, ...steps)
    expect(typeof writerOf(m, 'g1', rg), JSON.stringify(steps)).toBe('number')
  }
  m.edit('g1', r => { r.checkouts[rg]!.writer = null })
  await g.check({ tool: 'Bash', cwd: rg, steps: [] })
  expect(writerOf(m, 'g1', rg), 'guard-no-command-step-is-no-writer').toBeNull()
})

test('guard: a step\'s directory decides its checkout', async () => {
  const { m, session } = machine()
  const [rg, rx, ry] = [m.repo('/w/rg'), m.repo('/w/rx'), m.repo('/w/ry')]
  const g = session('g1')
  await g.bash(rg, 'git status')
  await g.bash(rg, at(rx, 'npm test'))
  expect(typeof writerOf(m, 'g1', rx)).toBe('number')
  expect(writerOf(m, 'g1', rg)).toBeNull()
  await g.bash(rg, at(`${rg}/sub/../`, 'npm test'))
  expect(typeof writerOf(m, 'g1', rg)).toBe('number')
  await g.bash(rg, at(ry, 'git status'))
  expect(m.rec('g1').checkouts[ry], 'guard-read-only-step-elsewhere-does-not-touch-it').toBeUndefined()
})

test('guard: the expected branch moves only when HEAD changed during this session\'s own switch', async () => {
  const { m, session } = machine()
  const [re, rw] = [m.repo('/w/re'), m.repo('/w/rw')]
  const g = session('g2')
  const expected = (top = re) => m.rec('g2').checkouts[top]!.expected
  const state = (want: string, head: string) => { m.head(re, head); m.edit('g2', r => { r.checkouts[re]!.expected = want }) }
  await call(g, re, ['git status'])
  expect(expected()).toBe('main')
  state('a', 'a')
  await call(g, re, ['git switch -c x', then('git commit -m m')], () => m.head(re, 'x'))
  expect(expected(), 'guard-switch-and-commit-moves-the-expectation').toBe('x')
  state('a', 'a')
  await call(g, re, ['git switch -c y', then('false')], () => m.head(re, 'y'))
  expect(expected(), 'guard-switch-then-failing-step-moves-the-expectation').toBe('y')
  state('a', 'a')
  await call(g, re, ['git add f', then('git commit -m m')], () => m.head(re, 'b'))
  expect(expected(), 'guard-head-changed-without-a-switch-step-keeps-it').toBe('a')
  expect(await g.bash(re, 'git add f'), 'guard-no-switch-step-takes-no-snapshot').toEqual({ decision: 'allow' })
  state('a', 'b')
  await call(g, re, ['git switch nosuch'])
  expect(expected(), 'guard-drifted-failed-switch-keeps-it').toBe('a')
  await call(g, re, ['git switch nosuch', then('true')])
  expect(expected(), 'guard-drifted-failed-switch-then-true-keeps-it').toBe('a')
  await call(g, re, ['false', then('git switch c')])
  expect(expected(), 'guard-drifted-skipped-switch-keeps-it').toBe('a')
  await call(g, re, ['git switch c'], () => m.head(re, 'c'))
  expect(expected(), 'guard-drifted-successful-switch-moves-it').toBe('c')
  state('a', 'b')
  await call(g, re, ['git checkout --detach'], () => m.head(re, undefined))
  expect(expected(), 'guard-detaching-moves-it-to-the-detached-head').toBe('')
  state('a', 'a')
  await call(g, re, [at(rw, 'git switch other')], () => m.head(rw, 'other'))
  expect(expected(rw), 'guard-switch-elsewhere-moves-that-checkout').toBe('other')
  expect(expected(), 'guard-switch-elsewhere-leaves-the-cwd-checkout').toBe('a')
  state('a', 'b')
  await call(g, re, ['git switch b'])
  expect(expected(), 'guard-a-switch-to-the-branch-head-holds-adopts-it').toBe('b')
  state('a', 'b')
  await call(g, re, ['git switch b'], undefined, false)
  expect(expected(), 'a call the engine denied adopts nothing').toBe('a')
  for (const [command, to] of [['gh pr checkout 5', 'pr5'], ['gh pr merge 5', 'main2'], ['git branch -m renamed', 'renamed'], ['git checkout -b nb', 'nb']] as const) {
    state('a', 'a')
    await call(g, re, [command], () => m.head(re, to))
    expect(expected(), `guard-switch-like-step-moves-it: ${command}`).toBe(to)
  }
  state('a', 'a')
  await g.after(re, ['git switch a'])
  expect(expected(), 'guard-after-without-before-still-reconciles: a no-op').toBe('a')
  m.head(re, 'c')
  await g.after(re, ['git switch c'])
  expect(expected(), 'guard-after-without-before-still-reconciles: the named branch').toBe('c')
})

// --- the guard stops what would destroy a peer's checkout, files, branch or process ------------------------------
// A repository where a live peer is a writer and this session has been.
function world() {
  const { m, session } = machine()
  const r = m.repo('/w/r')
  const [peer, me] = [session('peer'), session('me')]
  const ready = (async () => { await peer.touch(r); await me.bash(r, 'git status') })()
  const decide = async (cwd: string, ...steps: (string | Partial<Step>)[]) => me.bash(cwd, ...steps)
  const acked = (cwd: string, ack: string, ...steps: string[]) => me.check({ tool: 'Bash', cwd, steps: steps.map(s => step(s)), acks: [ack] })
  const other = (n = 0) => m.repo(`/w/other${n}`)
  return { m, session, r, peer, me, ready, decide, acked, other }
}
const now = (m: Machine) => Math.floor(m.clock / 1000)

test('guard: a switch next to a writer stops with a short reason; idle, cwd-only or dead peers do not', async () => {
  const { m, r, peer, me, ready, decide, other } = world()
  await ready
  for (const c of ['git switch x', 'git switch -c y', 'git checkout x', 'git checkout -b y', 'git switch --detach']) expect((await decide(r, c)).decision, c).toBe('stop')
  const { reason } = await decide(r, 'git switch x')
  for (const part of [`pid ${peer.pid}`, 'main', r, 'run the same command prefixed CC_TUNER_ACK=', 'not a question for the user']) expect(reason).toContain(part)
  expect(reason!.length).toBeLessThan(300)
  expect((await decide(r, at(other(), 'git switch x'))).decision, 'guard-switch-elsewhere-is-allowed').toBe('allow')
  expect((await decide(r, 'git status', then('git switch x'))).decision).toBe('stop')
  expect((await decide(other(1), at(r, 'git switch x'))).decision, 'behind git -C').toBe('stop')
  expect((await decide(r, at(`${r}/sub/..`, 'git switch x'))).decision, 'behind cd').toBe('stop')
  m.edit('peer', x => { x.checkouts[r]!.writer = now(m) - 3 * 3600 })
  const idle = await decide(r, 'git switch x')
  expect(idle.decision, 'guard-switch-after-2h-idle-is-a-note').toBe('note')
  expect(idle.reason).toContain(`pid ${peer.pid}`)
  m.edit('peer', x => { x.checkouts[r]!.writer = now(m) - 3600 })
  expect((await decide(r, 'git switch x')).decision, 'guard-switch-after-1h-idle-still-stops').toBe('stop')
  m.edit('peer', x => { x.checkouts[r]!.writer = null })
  expect((await decide(r, 'git switch x')).decision, 'guard-switch-next-to-a-cwd-is-a-note').toBe('note')
  m.edit('peer', x => { x.checkouts[r]!.writer = now(m) })
  m.end(peer.pid)
  expect((await decide(r, 'git switch x')).decision, 'guard-switch-with-a-dead-peer-is-allowed').toBe('allow')
  void me
})

test('guard: a stopped call marks no writer; an allowed writer call does', async () => {
  const { m, r, ready, decide } = world()
  await ready
  expect((await decide(r, 'git switch x')).decision).toBe('stop')
  expect(writerOf(m, 'me', r)).toBeNull()
  expect((await decide(r, 'git branch y')).decision).toBe('allow')
  expect(typeof writerOf(m, 'me', r)).toBe('number')
})

const FOREIGN = ['git reset --hard', 'git reset --hard HEAD~1', 'git stash', 'git stash push', 'git stash -u', 'git restore .flow-seed',
  'git restore .', 'git checkout -- .flow-seed', 'git checkout .', 'git clean -fd', 'git commit -a -m m', 'git commit -am m',
  'git add -A', 'git add --all', 'git add .', 'git add -u', 'git add sub']

test('guard: discarding or committing a foreign file stops, with no peer needed; neighbours pass', async () => {
  const { m, r, peer, me, ready, decide, other } = world()
  await ready
  m.mkdir(`${r}/sub`)
  m.dirty(r, ' M .flow-seed', '?? u.txt', '?? sub/n.txt')
  m.end(peer.pid)
  for (const c of FOREIGN) expect((await decide(r, c)).decision, c).toBe('stop')
  const { reason } = await decide(r, 'git reset --hard')
  expect(reason).toContain('.flow-seed')
  expect(reason).toContain('unknown owner')
  expect((await decide(other(), at(r, 'git reset --hard'))).decision, 'behind git -C').toBe('stop')
  expect((await decide(r, at('../x', 'git status'), step('echo'), then('git reset --hard'))).decision, 'behind wrappers').toBe('stop')
  expect((await decide(r, 'git status', then('git reset --hard'))).decision, 'in a compound').toBe('stop')
  for (const c of ['git clean -n', 'git clean -nd', 'git stash list', 'git status', 'git restore g.txt', 'git checkout -- g.txt', 'git add g.txt', 'git add sub/s.txt', 'git stash show']) {
    expect((await decide(r, c)).decision, c).toBe('allow')
  }
  expect((await decide(other(1), 'git reset --hard')).decision, 'a clean checkout').toBe('allow')
  m.status.set(r, ['M  .flow-seed', '?? u.txt', '?? sub/n.txt'])
  expect((await decide(r, 'git commit -m m')).decision, 'guard-foreign-staged-commit-stops').toBe('stop')
  expect((await decide(r, 'git commit --amend --no-edit')).decision, 'guard-foreign-staged-amend-stops').toBe('stop')
  m.status.set(r, [' M .flow-seed', '?? u.txt', '?? sub/n.txt'])
  expect((await decide(r, 'git add .flow-seed', then('git commit -m m'))).decision, 'guard-add-f-then-commit-stops-for-a-foreign-f').toBe('stop')
  expect((await decide(r, 'git add .flow-seed')).decision, 'guard-add-alone-of-a-named-file-allows').toBe('allow')
  for (const f of ['.flow-seed', 'u.txt', 'sub/n.txt']) await me.edited(r, `${r}/${f}`)
  for (const c of FOREIGN) expect((await decide(r, c)).decision, `own: ${c}`).toBe('allow')
  m.status.set(r, ['M  .flow-seed', '?? u.txt', '?? sub/n.txt'])
  expect((await decide(r, 'git commit -m m')).decision, 'guard-own-staged-commit-allows').toBe('allow')
  expect((await decide(r, 'git add .flow-seed', then('git commit -m m'))).decision).toBe('allow')
  m.dirty(r, ' M g.txt')
  expect((await decide(r, 'git restore g.txt')).decision, 'guard-restore-of-a-dirty-file-nobody-edited-stops').toBe('stop')
})

test('guard: a foreign stop names the peer that edited the file; a dead peer\'s files stay protected', async () => {
  const { m, r, peer, ready, decide } = world()
  await ready
  m.dirty(r, ' M .flow-seed')
  await peer.edited(r, `${r}/.flow-seed`)
  const live = await decide(r, 'git reset --hard')
  expect(live.decision).toBe('stop')
  expect(live.reason).toContain(`pid ${peer.pid} on main`)
  m.end(peer.pid)
  const dead = await decide(r, 'git reset --hard')
  expect(dead.decision).toBe('stop')
  expect(dead.reason).toContain(`pid ${peer.pid}, exited`)
})

test('guard: stash drop and clear stop while a peer works in the repository, past its 2 h window too', async () => {
  const { m, r, peer, ready, decide, other } = world()
  await ready
  for (const c of ['git stash drop', 'git stash clear', 'git stash drop stash@{1}']) expect((await decide(r, c)).decision, c).toBe('stop')
  expect((await decide(other(), at(r, 'git stash drop'))).decision).toBe('stop')
  expect((await decide(r, 'git stash list')).decision).toBe('allow')
  m.edit('peer', x => { x.checkouts[r]!.writer = now(m) - 3 * 3600 })
  expect((await decide(r, 'git stash drop')).decision).toBe('stop')
  m.end(peer.pid)
  expect((await decide(r, 'git stash drop')).decision).toBe('allow')
})

test('guard: commit, push and PR run on the branch this session expects, whoever switched it', async () => {
  const { m, r, peer, ready, decide, other } = world()
  await ready
  m.end(peer.pid)
  for (const c of ['git commit -m m', 'git push origin main', 'gh pr create --fill', 'gh pr merge 5', 'gh pr merge --squash']) expect((await decide(r, c)).decision, c).toBe('allow')
  m.head(r, 'x')
  for (const c of ['git commit -m m', 'git push origin x', 'gh pr create --fill', 'gh pr merge 5', 'gh pr merge --squash']) expect((await decide(r, c)).decision, c).toBe('stop')
  const { reason } = await decide(r, 'git commit -m m')
  expect(reason).toContain('on x')
  expect(reason).toContain('not on main')
  expect((await decide(other(), at(r, 'git commit -m m'))).decision).toBe('stop')
  expect((await decide(r, 'git status')).decision).toBe('allow')
  expect((await decide(r, 'git switch main', then('git commit -m m'))).decision).toBe('allow')
  m.head(r, 'main')
  expect((await decide(r, 'git switch -c z', then('git commit -m m'))).decision).toBe('allow')
  m.head(r, undefined)
  expect((await decide(r, 'git commit -m m')).decision, 'guard-detached-head-commit-stops-too').toBe('stop')
})

test('guard: deleting a peer\'s expected branch stops', async () => {
  const { m, r, peer, ready, decide, other } = world()
  await ready
  m.edit('peer', x => { x.checkouts[r]!.expected = 'feat-p' })
  for (const c of ['git branch -D feat-p', 'git branch -d feat-p', 'git branch --delete feat-p spare', 'git push origin --delete feat-p',
    'git push origin :feat-p', 'gh pr merge --squash --delete-branch feat-p']) expect((await decide(r, c)).decision, c).toBe('stop')
  const behind = await decide(other(), at(r, 'git branch -D feat-p'))
  expect(behind.decision).toBe('stop')
  expect(behind.reason).toContain(`pid ${peer.pid}`)
  for (const c of ['git branch -D spare', 'git push origin --delete spare', 'gh pr merge --squash feat-p', 'git branch --list']) expect((await decide(r, c)).decision, c).toBe('allow')
  expect((await decide(r, 'gh pr merge 7 --delete-branch')).decision).toBe('note')
  m.end(peer.pid)
  expect((await decide(r, 'git branch -D feat-p')).decision).toBe('allow')
})

test('guard: removing a worktree that is a peer\'s cwd, or holds foreign files, stops', async () => {
  const { m, r, peer, me, ready, decide } = world()
  await ready
  const wt = m.worktree(r, '/w/t/wt', 'wt')
  await peer.touch(wt)
  for (const c of [`git worktree remove ${wt}`, `git worktree remove --force ${wt}`, `rm -rf ${wt}`, `rm -r ${wt}`, `rm -fr ${wt}/`, 'rm -rf /w/t']) {
    expect((await decide(r, c)).decision, c).toBe('stop')
  }
  const wrapped = await decide(r, at('/w/t', 'rm -rf wt'))
  expect(wrapped.decision).toBe('stop')
  expect(wrapped.reason).toContain(`pid ${peer.pid}`)
  expect((await decide(r, `rm -rf ${r}/build`)).decision).toBe('allow')
  expect((await decide(r, `rm ${wt}/x`)).decision).toBe('allow')
  const wt2 = m.worktree(r, '/w/t/wt2', 'wt2')
  expect((await decide(r, `git worktree remove ${wt2}`)).decision).toBe('allow')
  m.dirty(wt2, '?? foreign.txt')
  expect((await decide(r, `git worktree remove --force ${wt2}`)).decision).toBe('stop')
  const rm = await decide(r, `rm -rf ${wt2}`)
  expect(rm.decision).toBe('stop')
  expect(rm.reason).toContain('foreign.txt')
  await me.edited(wt2, `${wt2}/foreign.txt`, 'Write')
  expect((await decide(r, `git worktree remove --force ${wt2}`)).decision).toBe('allow')
  m.end(peer.pid)
  expect((await decide(r, `git worktree remove ${wt}`)).decision).toBe('allow')
})

test('guard: kill of a process that descends from a peer stops; its own or an unrelated one does not', async () => {
  const { m, session, other } = machine() as ReturnType<typeof machine> & { other?: never }
  void other
  const r = m.repo('/w/r')
  const p = m.spawn()
  const pc = m.spawn(p, 'sleep', 'sleep 3737')
  const me = m.spawn()
  const mc = m.spawn(me, 'sleep', 'sleep 3838')
  const un = m.spawn()
  const [peer, mine] = [session('peer', p), session('me', me)]
  await peer.touch(r)
  await mine.touch(r)
  const decide = async (cwd: string, ...steps: (string | Partial<Step>)[]) => (await mine.bash(cwd, ...steps)).decision
  expect(await decide(r, `kill ${pc}`)).toBe('stop')
  expect((await mine.bash(r, `kill ${pc}`)).reason).toContain(`pid ${p}`)
  expect(await decide(r, `kill -9 ${pc}`)).toBe('stop')
  expect(await decide(r, `kill ${p}`)).toBe('stop')
  expect(await decide(m.repo('/w/x'), at(r, `kill ${pc}`))).toBe('stop')
  expect(await decide(r, `kill ${mc}`)).toBe('allow')
  expect(await decide(r, `kill ${un}`)).toBe('allow')
  expect(await decide(r, 'pkill -f 3737')).toBe('stop')
  expect(await decide(r, 'pkill -9 -f 3737')).toBe('stop')
  expect(await decide(r, 'pkill -f 3838')).toBe('allow')
  expect(await decide(r, 'pkill -f 3939')).toBe('allow')
  m.spawn(p, 'peersleep')
  m.spawn(me, 'mysleep')
  expect(await decide(r, 'killall peersleep')).toBe('stop')
  expect(await decide(r, 'killall mysleep')).toBe('allow')
  m.ports.set(4000, pc)
  expect(await decide(r, 'lsof -ti :4000', 'kill')).toBe('stop')
  expect(await decide(r, 'lsof -ti :4000', then('kill'))).toBe('stop')
  expect(await decide(r, 'lsof -ti :1', 'kill')).toBe('allow')
  expect(await decide(r, 'kill $PID')).toBe('note')
  m.end(p)
  expect(await decide(r, `kill ${pc}`)).toBe('allow')
})

test('guard: signal 0 is a liveness probe and stops nothing, in any spelling kill accepts', async () => {
  const { m, session } = machine()
  const r = m.repo('/w/r')
  const p = m.spawn()
  const pc = m.spawn(p, 'sleep', 'sleep 3737')
  const me = m.spawn()
  const [peer, mine] = [session('peer', p), session('me', me)]
  await peer.touch(r)
  await mine.touch(r)
  const decide = async (...steps: (string | Partial<Step>)[]) => (await mine.bash(r, ...steps)).decision
  for (const probe of [`kill -0 ${pc}`, `kill -00 ${pc}`, `kill -s 0 ${pc}`, `kill -n 0 ${pc}`, `kill --signal 0 ${pc}`, `kill -0 -- ${pc}`, `kill -0 ${p} ${pc}`, `pkill -0 -f 3737`, `kill -0 $PID`]) {
    expect(await decide(probe), probe).toBe('allow')
  }
  m.ports.set(4000, pc)
  expect(await decide('lsof -ti :4000', 'kill -0'), 'lsof | kill -0').toBe('allow')
  for (const stops of [`kill -9 ${pc}`, `kill -s 9 ${pc}`, `kill -s KILL ${pc}`, `kill -n 15 ${pc}`, `kill -10 ${pc}`, `kill -0 -9 ${pc}`, `kill -s 0 -s 9 ${pc}`, `kill --signal 9 ${pc}`]) {
    expect(await decide(stops), stops).toBe('stop')
  }
})

test('guard: an edit next to a writer or of a claimed path is a note, said once an hour', async () => {
  const { m, r, peer, me, ready, other } = world()
  await ready
  const edit = (path: string) => me.check({ tool: 'Edit', cwd: r, path })
  const first = await edit(`${r}/a.txt`)
  expect(first.decision).toBe('note')
  expect(first.reason).toContain(`pid ${peer.pid}`)
  expect((await edit(`${r}/b.txt`)).decision, 'guard-edit-note-once-an-hour').toBe('allow')
  m.edit('me', x => { x.acks = Object.fromEntries(Object.keys(x.acks).map(k => [k, 1])) })
  expect((await edit(`${r}/b.txt`)).decision, 'guard-edit-note-again-after-the-hour').toBe('note')
  expect(writerOf(m, 'me', r), 'guard-edit-before-marks-no-writer').toBeNull()
  m.edit('peer', x => { x.claims = { 'plan.md': { repo: x.checkouts[r]!.repo, paths: ['lib/'] } }; x.checkouts[r]!.writer = null })
  const claimed = await edit(`${r}/lib/x.ts`)
  expect(claimed.decision).toBe('note')
  expect(claimed.reason).toContain('lib/')
  expect((await edit(`${r}/src/x.ts`)).decision).toBe('allow')
  expect((await me.check({ tool: 'Edit', cwd: r, path: `${other()}/a.txt` })).decision, 'guard-edit-in-another-repository-allows').toBe('allow')
  m.end(peer.pid)
  expect((await edit(`${r}/lib/y.ts`)).decision, 'guard-edit-with-a-dead-peer-allows').toBe('allow')
})

test('guard: an edit of a dirty or untracked file this session did not edit is a note, once per path per hour', async () => {
  const { m, session } = machine()
  const r = m.repo('/w/r')
  const [peer, me] = [session('peer'), session('me')]
  await me.bash(r, 'git status')
  m.dirty(r, ' M a.txt', '?? u.txt', ' M p.txt', ' M own.txt')
  await peer.edited(r, `${r}/p.txt`)
  m.edit('peer', x => { x.checkouts[r]!.writer = null })
  await me.edited(r, `${r}/own.txt`)
  const edit = (path: string, tool = 'Edit') => me.check({ tool, cwd: r, path: `${r}/${path}` })
  const first = await edit('a.txt')
  expect(first.decision, 'guard-edit-of-a-dirty-file-nobody-here-edited-is-a-note').toBe('note')
  expect(first.reason).toContain('a.txt')
  expect(first.reason).toContain('unknown owner')
  expect((await edit('a.txt')).decision, 'guard-dirty-file-note-once-an-hour').toBe('allow')
  expect((await edit('u.txt', 'Write')).decision, 'guard-untracked-file-is-foreign-too').toBe('note')
  expect((await edit('n.ipynb', 'NotebookEdit')).decision, 'guard-clean-or-new-file-allows').toBe('allow')
  expect((await edit('p.txt')).reason, 'guard-dirty-file-names-the-peer-that-edited-it').toContain(`pid ${peer.pid}`)
  m.ran.length = 0
  expect((await edit('own.txt')).decision, 'guard-own-edited-file-allows').toBe('allow')
  expect(m.ran, 'guard-own-edited-file-runs-no-git').toEqual([])
  m.advance(3601)
  expect((await edit('a.txt')).decision, 'guard-dirty-file-note-again-after-the-hour').toBe('note')
  m.failing.set('git status', 128)
  expect((await edit('u.txt', 'Write')).decision, 'guard-unreadable-status-adds-no-note').toBe('allow')
})

test('guard: "guard": false in the repository file or the machine file turns the guard off there; records and the report stay', async () => {
  const { m, session } = machine()
  const [r, q] = [m.repo('/w/r'), m.repo('/w/q')]
  const [peer, me] = [session('peer'), session('me')]
  await peer.touch(r)
  await peer.touch(q)
  m.dirty(r, ' M f.txt')
  m.dirty(q, ' M f.txt')
  await me.bash(q, 'git status')
  const calls = async (top: string) => [(await me.bash(top, 'git switch x')).decision, (await me.bash(top, 'git reset --hard')).decision,
    (await me.bash(top, 'git stash drop')).decision, (await me.check({ tool: 'Edit', cwd: top, path: `${top}/f.txt` })).decision]
  expect(await calls(r), 'the guard is on by default').toEqual(['stop', 'stop', 'stop', 'note'])
  m.put(`${r}/.claude/cc-tuner-resources.json`, JSON.stringify({ guard: false }))
  m.edit('me', x => { x.acks = {} })
  expect(await calls(r), 'guard-off-in-the-repository-file').toEqual(['allow', 'allow', 'allow', 'allow'])
  expect(m.rec('me').checkouts[r], 'guard-off-keeps-the-record').toMatchObject({ expected: 'main' })
  expect(typeof writerOf(m, 'me', r), 'guard-off-still-marks-the-writer').toBe('number')
  expect(await me.report(r), 'guard-off-keeps-the-report').toContain(`pid ${peer.pid}`)
  expect((await me.bash(q, 'git switch x')).decision, 'guard-off-is-per-repository').toBe('stop')
  m.put(`${r}/.claude/cc-tuner-resources.json`, JSON.stringify({ guard: true }))
  expect((await me.bash(r, 'git switch x')).decision, 'only false turns it off').toBe('stop')
  m.put(USER, JSON.stringify({ guard: false }))
  expect(await calls(q), 'guard-off-in-the-machine-file').toEqual(['allow', 'allow', 'allow', 'allow'])
  m.put(USER, JSON.stringify({ resources: [CHROME] }))
  expect((await me.bash(q, 'git switch x')).decision, 'the machine file back on').toBe('stop')
})

test('guard: off, a lease and a TaskStop of a shared task stop nothing either', async ($, on) => {
  const { m, session } = machine()
  m.repo('/w/r')
  declare(m, '/w/r', STACK)
  declareMachine(m, CHROME)
  const peer = session('peer')
  await peer.touch('/w/r')
  await peer.peers.lease(CLICK, '/w/r', 'peer')
  engine(on, m, m.spawn(), undefined, undefined, command => (command === 'stack up' ? 'b1' : undefined))
  await $.tool.call({ tool: 'Bash', command: 'stack up', run_in_background: true })
  expect((await $.tool.call({ tool: CLICK })).deny).toContain('leased')
  expect((await $.tool.call({ tool: 'TaskStop', task_id: 'b1' })).deny).toContain('also uses')
  m.put(USER, JSON.stringify({ guard: false, resources: [CHROME] }))
  expect((await $.tool.call({ tool: CLICK })).deny, 'guard-off-lease').toBeUndefined()
  expect((await $.tool.call({ tool: 'TaskStop', task_id: 'b1' })).deny, 'guard-off-taskstop').toBeUndefined()
})

test('guard: a git command with an option first is a note', async () => {
  const { r, ready, decide } = world()
  await ready
  expect((await decide(r, 'git --git-dir=x reset --hard')).decision).toBe('note')
})

test('ack: the printed key passes that action on that target for 30 min, and nothing else', async () => {
  const { m, r, me, ready, decide, acked, other } = world()
  await ready
  const r2 = other()
  m.dirty(r, ' M .flow-seed', '?? u.txt')
  m.dirty(r2, ' M .flow-seed')
  await me.touch(r2)
  const k = /CC_TUNER_ACK=([0-9a-f]+)/.exec((await decide(r, 'git reset --hard')).reason!)![1]!
  expect(k).toHaveLength(8)
  expect((await acked(r, k, 'git reset --hard')).decision).toBe('allow')
  expect(typeof m.rec('me').acks[k]).toBe('number')
  expect((await decide(r, 'git reset --hard')).decision, 'holds without the prefix').toBe('allow')
  expect((await decide(r, 'git clean -fd')).decision, 'another action').toBe('stop')
  expect((await decide(r2, 'git reset --hard')).decision, 'another target').toBe('stop')
  expect((await decide(other(1), at(r2, 'git reset --hard'))).decision, 'another checkout by git -C').toBe('stop')
  expect((await decide(other(1), at(r, 'git reset --hard'))).decision, 'the same action by git -C').toBe('allow')
  expect((await acked(r2, 'deadbeef', 'git reset --hard')).decision).toBe('stop')
  m.edit('me', x => { x.acks[k] = now(m) - 31 * 60 })
  expect((await decide(r, 'git reset --hard')).decision, 'guard-ack-expires-after-30-min').toBe('stop')
  expect((await acked(r, k, 'git reset --hard')).decision, 'guard-ack-prefix-renews-it').toBe('allow')
  m.edit('me', x => { x.acks = {} })
  expect((await acked(r, '00000000', 'git reset --hard')).decision).toBe('stop')
  await me.start(r, 'me2')
  expect(m.rec('me').acks).toEqual({})
})

test('a decision spawns only the processes it needs: ps once a minute, git status before losing files', async () => {
  const { m, r, ready, decide } = world()
  await ready
  m.ran.length = 0
  for (const c of ['ls', 'npm test', 'git switch x', 'git commit -m m']) await decide(r, c)
  expect(m.ran.map(a => a.slice(0, 8).join(' '))).toEqual([`git -c core.fsmonitor=false -c core.untrackedCache=false -C ${r} status`])
  m.advance(61)
  await decide(r, 'npm test')
  expect(m.ran.slice(1).map(a => a[0]), 'its own start time is read once').toEqual([])
  await decide(r, 'git switch x')
  expect(m.ran.slice(1).map(a => a[0]), 'a peer\'s start time is read again after a minute').toEqual(['ps'])
})

// --- resources: a shared one is not stopped under a live peer, an exclusive one is used by one session at a time ----
const STACK = { key: 'stack', kind: 'shared', start: ['stack up'], stop: ['stack down', 'docker compose down'] }
const CHROME = { key: 'chrome', kind: 'exclusive', tools: ['mcp__chrome-devtools__*'] }
const CLICK = 'mcp__chrome-devtools__click'
const declare = (m: Machine, top: string, ...resources: object[]) => m.put(`${top}/.claude/cc-tuner-resources.json`, JSON.stringify({ product: 'acme', resources }))
const declareMachine = (m: Machine, ...resources: object[]) => m.put(USER, JSON.stringify({ resources }))

test('resource: a shared stop command stops while a product session is live, and runs when none is', async () => {
  const { m, ra, rb, rc, rd, sr, sb, sc, sd } = products()
  declare(m, ra, STACK)
  for (const [s, top] of [[sr, ra], [sb, rb], [sc, rc], [sd, rd]] as const) await s.touch(top)
  for (const c of ['stack down', 'docker compose down -v']) expect((await sr.bash(ra, c)).decision, c).toBe('stop')
  const { reason } = await sr.bash(ra, 'stack down')
  for (const part of ['stack', `pid ${sb.pid}`, 'run the same command prefixed CC_TUNER_ACK=']) expect(reason).toContain(part)
  expect((await sr.bash(rc, at(ra, 'stack down'))).decision, 'behind git -C or cd').toBe('stop')
  expect((await sr.bash(ra, 'bash', at(ra, 'stack down'))).decision, 'behind a wrapper').toBe('stop')
  for (const c of ['stack up', 'stack status', 'docker compose up']) expect((await sr.bash(ra, c)).decision, c).toBe('allow')
  expect((await sd.bash(rd, 'stack down')).decision, 'resource-a-repository-without-the-file-adds-no-rules').toBe('allow')
  const key = /CC_TUNER_ACK=([0-9a-f]{8})/.exec(reason!)![1]!
  expect((await sr.check({ tool: 'Bash', cwd: ra, steps: [step('stack down')], acks: [key] })).decision, 'resource-shared-stop-takes-an-ack').toBe('allow')
  m.edit('sr', r => { r.acks = {} })
  m.end(sb.pid)
  expect((await sr.bash(ra, 'stack down')).decision, 'the peer of the product has gone').toBe('allow')
})

test('resource: a machine resource applies in a repository without the file, and counts every live session', async () => {
  const { m, session } = machine()
  const [rx, ry] = [m.repo('/w/rx'), m.repo('/w/ry')]
  declareMachine(m, { key: 'ports', kind: 'shared', stop: ['pnpm stack:down'] })
  const [sx, sy] = [session('sx'), session('sy')]
  await sx.touch(rx)
  await sy.touch(ry)
  const { decision, reason } = await sx.bash(rx, 'pnpm stack:down')
  expect(decision).toBe('stop')
  expect(reason).toContain(`pid ${sy.pid}`)
  m.end(sy.pid)
  expect((await sx.bash(rx, 'pnpm stack:down')).decision).toBe('allow')
})

test('resource: two simultaneous first users get one lease, across products', async () => {
  const { m, ra, rc, sr, sc } = products()
  declareMachine(m, CHROME)
  const [a, b] = await Promise.all([sr.peers.lease(CLICK, ra, 'sr'), sc.peers.lease(CLICK, rc, 'sc')])
  expect([a.decision, b.decision].sort(), 'resource-two-first-users-get-one-lease').toEqual(['note', 'stop'])
  const [holder, loser] = a.decision === 'note' ? [sr, b] : [sc, a]
  expect(JSON.parse(m.files.get(`${DIR}/lease.chrome/holder.json`)!.text)).toMatchObject({ key: 'chrome', pid: holder.pid, start: m.procs.get(holder.pid)!.start })
  expect(loser.reason).toContain(`pid ${holder.pid}`)
})

test('resource: a machine lease applies to sessions outside any repository', async () => {
  const { m, sr, sc } = products()
  declareMachine(m, CHROME)
  const [a, b] = [await sr.peers.lease(CLICK, '/w', 'sr'), await sc.peers.lease(CLICK, '/tmp', 'sc')]
  expect([a.decision, b.decision], 'resource-lease-outside-a-repository').toEqual(['note', 'stop'])
})

test('resource: the lease is the holder\'s until its release, 10 min of silence or its death; no ack passes it', async () => {
  const { m, ra, rc, sr, sc } = products()
  declareMachine(m, CHROME)
  const use = (s: Session, top: string, tool = CLICK) => s.peers.lease(tool, top, s.sid)
  const taken = await use(sr, ra)
  expect(taken.decision).toBe('note')
  expect(taken.reason).toContain('peers_release')
  expect((await use(sr, ra)).decision, 'the holder goes on').toBe('allow')
  expect((await use(sc, rc, 'mcp__other__x')).decision, 'a tool no resource names').toBe('allow')
  const denied = await use(sc, rc)
  expect(denied.decision).toBe('stop')
  for (const part of [`pid ${sr.pid}`, 'chrome', 'SendMessage']) expect(denied.reason).toContain(part)
  expect(denied.reason, 'a lease offers no ack').not.toContain('CC_TUNER_ACK')
  expect(await sc.peers.release('chrome'), 'resource-non-holder-release-is-refused').toBe('cc-tuner: chrome is not leased to this session.')
  m.advance(599)
  expect((await use(sc, rc)).decision, 'resource-lease-held-within-10-min').toBe('stop')
  expect((await use(sr, ra)).decision).toBe('allow')
  m.advance(601)
  expect((await use(sc, rc)).decision, 'resource-lease-moves-after-10-min-of-silence').toBe('note')
  expect(await sr.peers.release('chrome'), 'resource-former-holder-release-is-refused').toBe('cc-tuner: chrome is not leased to this session.')
  expect((await use(sr, ra)).decision, 'the former holder is a non-holder now').toBe('stop')
  expect(await sc.peers.release('chrome')).toBe('cc-tuner: released chrome.')
  expect((await use(sr, ra)).decision, 'resource-lease-moves-on-release').toBe('note')
  m.end(sr.pid)
  expect((await use(sc, rc)).decision, 'resource-lease-moves-on-death').toBe('note')
})

test('resource: a repository resource is leased too, and a lock with no holder file yet is not up for grabs', async () => {
  const { m, session } = machine()
  const r = m.repo('/w/r')
  declare(m, r, { key: 'db', kind: 'exclusive', tools: ['mcp__db__*'] })
  const [s1, s2] = [session('s1'), session('s2')]
  m.dirs.add(`${DIR}/lease.db`)
  m.dirTimes.set(`${DIR}/lease.db`, m.clock)
  expect((await s1.peers.lease('mcp__db__query', r, 's1')).decision, 'a lock just made, its holder not written yet').toBe('stop')
  m.advance(601)
  expect((await s1.peers.lease('mcp__db__query', r, 's1')).decision, 'a lock nobody ever wrote to').toBe('note')
  expect((await s2.peers.lease('mcp__chrome-devtools__click', r, 's2')).decision, 'another repository\'s resource does not apply').toBe('allow')
})

test('resource: a holder file with a trailing newline still lets a dead holder\'s lease move', async () => {
  const { m, session } = machine()
  const r = m.repo('/w/r')
  declareMachine(m, CHROME)
  const [s1, s2] = [session('s1'), session('s2')]
  await s1.peers.lease(CLICK, r, 's1')
  m.put(`${DIR}/lease.chrome/holder.json`, `${m.files.get(`${DIR}/lease.chrome/holder.json`)!.text}\n`)
  m.end(s1.pid)
  expect((await s2.peers.lease(CLICK, r, 's2')).decision).toBe('note')
  expect(await s2.peers.release('chrome')).toBe('cc-tuner: released chrome.')
})

test('resource: the module denies an MCP tool leased to another session, and answers peers_release', async ($, on) => {
  const { m, session } = machine()
  m.repo('/w/r')
  declareMachine(m, CHROME)
  const peer = session('peer')
  await peer.peers.lease(CLICK, '/w/r', 'peer')
  const ran = engine(on, m, m.spawn())
  const { deny } = await $.tool.call({ tool: CLICK })
  expect(deny).toContain(`chrome is leased to pid ${peer.pid}`)
  expect((await $.tool.call({ tool: 'mcp__chrome-devtools__list' })).deny).toContain('leased')
  expect(ran).toEqual([])
  expect((await $.tool.call({ tool: 'mcp__cc-tuner__peers_release', key: 'chrome' })).result).toBe('cc-tuner: chrome is not leased to this session.')
  expect(await peer.peers.release('chrome')).toBe('cc-tuner: released chrome.')
  const ok = await $.tool.call({ tool: CLICK })
  expect(ok.deny).toBeUndefined()
  expect(ok.context?.join(' ')).toContain('peers_release')
  expect(ran).toEqual([CLICK])
  expect((await $.tool.call({ tool: 'mcp__cc-tuner__peers_release', key: 'chrome' })).result).toBe('cc-tuner: released chrome.')
})

test('resource: TaskStop of a shared task is denied with no ack while a product session is live', async ($, on) => {
  const { m, session } = machine()
  m.repo('/w/r')
  declare(m, '/w/r', STACK)
  engine(on, m, m.spawn(), undefined, undefined, command => command.split(' ')[0] === 'stack' ? command.split(' ')[2] : command.startsWith('sleep') ? 'b9' : undefined)
  await $.tool.call({ tool: 'Bash', command: 'stack up one', run_in_background: true })
  await $.tool.call({ tool: 'Bash', command: 'stack up two', run_in_background: true })
  await $.tool.call({ tool: 'Bash', command: 'sleep 9', run_in_background: true })
  expect((await $.tool.call({ tool: 'TaskStop', task_id: 'one' })).deny, 'resource-taskstop-runs-when-none-is-live').toBeUndefined()
  const peer = session('peer')
  await peer.touch('/w/r')
  const { deny } = await $.tool.call({ tool: 'TaskStop', task_id: 'two' })
  for (const part of ['two', 'stack', `pid ${peer.pid}`, 'SendMessage']) expect(deny).toContain(part)
  expect(deny, 'resource-taskstop-offers-no-ack').not.toContain('CC_TUNER_ACK')
  expect((await $.tool.call({ tool: 'TaskStop', task_id: 'b9' })).deny, 'a task that ran no shared start').toBeUndefined()
  expect(m.stopped).toEqual(['one', 'b9'])
})

test('resource: /clear keeps a shared task running, and the next start line names it', async ($, on) => {
  const { m } = machine()
  m.repo('/w/r')
  declare(m, '/w/r', STACK)
  engine(on, m, m.spawn(), undefined, undefined, command => (command === 'stack up' ? 'b1' : command === 'npm run dev' ? 'b2' : undefined))
  await $.tool.call({ tool: 'Bash', command: 'stack up', run_in_background: true })
  await $.tool.call({ tool: 'Bash', command: 'npm run dev', run_in_background: true })
  await $.session.end({ sessionId: 'e1', resume: { id: 'e1' }, reason: 'clear' })
  expect(m.stopped, 'resource-clear-stops-only-what-is-not-shared').toEqual(['b2'])
  expect(m.rec('e1').kept, 'resource-kept-task-is-in-the-record').toEqual([{ id: 'b1', key: 'stack', top: '/w/r' }])
  sessionId = 'e2'
  expect(await prompt($), 'resource-clear-start-line-names-the-task').toContain('kept at /clear: stack (b1)')
})

// --- the guard runs nothing the model chose, and reads git inertly -------------------------------------------------
test('guard: only the fixed lsof and pgrep are run for a kill; a path to one is not', async () => {
  const { m, session } = machine()
  const r = m.repo('/w/r')
  const p = m.spawn()
  const [peer, mine] = [session('peer', p), session('me')]
  await peer.touch(r)
  await mine.touch(r)
  for (const first of ['./x/pgrep -f 3737', 'node_modules/.bin/lsof -ti :4000', '/tmp/pgrep -f a']) {
    m.ran.length = 0
    const v = await mine.bash(r, first, then('kill'))
    expect(v.decision, first).toBe('note')
    expect(m.ran.filter(a => a[0]!.includes('/') && a[0] !== '/bin/sh'), `guard-runs-no-path-from-the-command: ${first}`).toEqual([])
  }
  m.ran.length = 0
  await mine.bash(r, 'pgrep -f 3737', then('kill'))
  expect(m.ran.map(a => a[0]), 'the fixed name still runs').toContain('pgrep')
})

test('guard: a pgrep that failed to run is not an empty answer', async () => {
  const { m, session } = machine()
  const r = m.repo('/w/r')
  const p = m.spawn()
  m.spawn(p, 'sleep', 'sleep 3737')
  const [peer, mine] = [session('peer', p), session('me')]
  await peer.touch(r)
  await mine.touch(r)
  expect((await mine.bash(r, 'pkill -f 3737')).decision).toBe('stop')
  m.failing.set('pgrep', 2)
  expect((await mine.bash(r, 'pkill -e -f 3737')).decision, 'guard-pgrep-usage-error-notes').toBe('note')
  m.failing.set('pgrep', 1)
  expect((await mine.bash(r, 'pkill -f 3939')).decision, 'no match is exit 1: nothing to stop').toBe('allow')
})

test('guard: every git call runs with the config that could run a command off', async () => {
  const { m, session } = machine()
  const [r, other] = [m.repo('/w/r'), m.repo('/w/o')]
  const [peer, mine] = [session('peer'), session('me')]
  m.dirty(r, ' M f')
  await peer.touch(r)
  await mine.touch(r)
  await mine.bash(r, 'git reset --hard')
  await mine.touch(other)
  m.shas.set(other, 'sha-other')
  await mine.report(r)
  const git = m.ran.filter(a => a[0] === 'git' || a.some(x => x.includes('merge-tree')))
  expect(git.length).toBeGreaterThan(1)
  for (const argv of git) expect(argv.join(' '), 'guard-git-runs-with-fsmonitor-off').toMatch(/core\.fsmonitor=false.*core\.untrackedCache=false/)
})

test('an ack is a printed key, as a prefix or on any step, and nothing a quoted value holds', async ($, on) => {
  const { m } = machine()
  m.repo('/w/r')
  m.dirty('/w/r', ' M f')
  const ran = engine(on, m, m.spawn())
  const { deny } = await $.tool.call({ tool: 'Bash', command: 'git reset --hard' })
  const key = /CC_TUNER_ACK=([0-9a-f]{8})/.exec(deny ?? '')![1]!
  const odd = 'CC_TUNER_ACK="k rm -rf ~ #" echo hi'
  await $.tool.call({ tool: 'Bash', command: odd })
  expect(ran, 'guard-ack-prefix-is-only-the-key-format').toEqual([odd])
  expect(Object.keys(m.rec('e1').acks)).toEqual([])
  expect((await $.tool.call({ tool: 'Bash', command: `true && CC_TUNER_ACK=${key} git reset --hard` })).deny, 'guard-ack-on-a-later-step').toBeUndefined()
  expect(typeof m.rec('e1').acks[key]).toBe('number')
})

// --- scope comes from the target, also outside a repository --------------------------------------------------------
test('guard: a step that targets a repository is decided there, from a cwd that is none', async () => {
  const { m, session } = machine()
  const r1 = m.repo('/w/r1')
  m.mkdir('/w')
  const [peer, me] = [session('peer'), session('me')]
  await peer.bash(r1, 'npm test')
  await me.touch(r1)
  for (const c of ['git switch x', 'git branch -m y']) expect((await me.bash('/w', at(r1, c))).decision, `guard-outside-a-repository: ${c}`).toBe(c === 'git switch x' ? 'stop' : 'allow')
  expect(m.rec('me').checkouts[r1], 'the checkout it acted on is recorded').toBeDefined()
  m.dirty(r1, ' M f')
  expect((await me.bash('/w', at(r1, 'git reset --hard'))).decision).toBe('stop')
  expect((await me.bash('/w', 'git reset --hard')).decision, 'no checkout at all').toBe('allow')
  const fresh = session('fresh')
  expect((await fresh.bash('/w', at(r1, 'git reset --hard'))).decision, 'a session that has no record yet').toBe('stop')
})

test('claim and report read the repository from the plan, not the session cwd', async () => {
  const { m, session } = machine()
  const [r1, r2] = [m.repo('/w/r1'), m.repo('/w/r2')]
  m.mkdir('/w')
  const [peer, me] = [session('peer'), session('me')]
  await peer.touch(r1)
  m.put(`${r1}/docs/p.md`, '## Slice 1 — A\nOwned paths: lib/\n- [ ] a\n')
  const out = await me.peers.claim('/w', 'me', 'r1/docs/p.md')
  expect(out, 'claim-from-a-workspace-root').toContain(`pid ${peer.pid}`)
  expect(m.rec('me').claims['docs/p.md']).toMatchObject({ paths: ['lib/'] })
  expect(await me.peers.claim(r2, 'me', '../r1/docs/p.md'), 'claim-of-another-repository-plan').toContain(`pid ${peer.pid}`)
  expect(await me.peers.claim('/w', 'me', 'r1/docs/none.md')).toBe('cc-tuner: cannot read r1/docs/none.md')
})

test('guard: a step after a cd it could not read is a note, not a decision against the wrong checkout', async () => {
  const { m, session } = machine()
  const r = m.repo('/w/r')
  const [peer, me] = [session('peer'), session('me')]
  await peer.touch(r)
  await me.touch(r)
  m.dirty(r, ' M f')
  const blind = await me.bash(r, at(UNKNOWN, 'git reset --hard'))
  expect(blind.decision, 'guard-unknown-directory-is-a-note').toBe('note')
  expect(blind.reason).toContain('could not read the directory')
  expect((await me.bash(r, at(UNKNOWN, 'git status'))).decision, 'a read-only step needs no directory').toBe('allow')
  expect((await me.bash(r, at(UNKNOWN, 'npm test'))).decision).toBe('allow')
})

test('guard: a wrapper that starts another command it cannot unwrap is a note when that command is git, gh or kill', async () => {
  const { r, ready, decide } = world()
  await ready
  for (const c of ['sudo git reset --hard', 'eval git reset --hard', 'eval git switch x', 'sudo kill 1', 'bash run.sh git push', 'watch gh pr merge']) {
    const v = await decide(r, c)
    expect(v.decision, `guard-opaque-wrapper: ${c}`).toBe('note')
    expect(v.reason).toContain('could not read')
  }
  for (const c of ['sudo ls', 'echo git reset --hard', 'grep git README', 'bash deploy-git.sh', 'bash run.sh']) expect((await decide(r, c)).decision, c).toBe('allow')
})

// --- records are robust and versioned ------------------------------------------------------------------------------
test('record: a record of the wrong shape or version is skipped and noted once an hour, never a crash', async () => {
  const { m, r, peer, me, ready, decide } = world()
  await ready
  expect(m.rec('peer').v, 'record-is-versioned').toBe(1)
  m.dirty(r, ' M f')
  m.edit('peer', x => { delete (x.checkouts[r] as Partial<Rec['checkouts'][string]>).paths })
  const first = await decide(r, 'git status')
  expect(first.decision).toBe('note')
  expect(first.reason).toContain('skipped malformed peer record peer.json')
  expect((await decide(r, 'git status')).decision, 'said once an hour').toBe('allow')
  expect((await decide(r, 'git reset --hard')).reason, 'record-malformed-shape-is-not-a-peer').toContain('unknown owner')
  m.edit('peer', x => { x.checkouts[r] = { repo: 'x' } as unknown as Rec['checkouts'][string] })
  m.edit('me', x => { x.acks = {} })
  expect((await decide(r, 'git status')).reason).toContain('peer.json')
  for (const [field, value] of [['v', 2], ['seen', 'now'], ['acks', []], ['kept', {}], ['claims', { p: { repo: 1, paths: [] } }]] as const) {
    m.put(`${DIR}/x.json`, JSON.stringify({ ...m.rec('me'), [field]: value }))
    expect((await me.report(r)), `${field}=${JSON.stringify(value)}`).toContain('skipped malformed record x.json')
  }
  void peer
})

test('record: a record caught half written is read again once', async () => {
  const { m, session } = machine()
  const r1 = m.repo('/w/r1')
  const [peer, me] = [session('peer'), session('me')]
  await peer.touch(r1)
  m.halfOnce.add(`${DIR}/peer.json`)
  const out = await me.report(r1)
  expect(out, 'record-half-written-read-again').toContain(`pid ${peer.pid}`)
  expect(out).not.toContain('skipped')
})

test('guard: a git status that did not run is not a clean tree', async () => {
  const { m, r, me, ready, decide, acked } = world()
  await ready
  m.failing.set('git status', 1)
  for (const c of ['git reset --hard', 'git clean -fd', 'git commit -m m', 'git add -A']) {
    const v = await decide(r, c)
    expect(v.decision, `guard-unreadable-status-stops: ${c}`).toBe('stop')
    expect(v.reason).toContain('could not read git status')
  }
  const k = /CC_TUNER_ACK=([0-9a-f]{8})/.exec((await decide(r, 'git reset --hard')).reason!)![1]!
  expect((await acked(r, k, 'git reset --hard')).decision, 'an ack goes on').toBe('allow')
  m.failing.delete('git status')
  expect((await decide(r, 'git reset --hard')).decision, 'a clean tree').toBe('allow')
  void me
})

test('guard: git status lists every untracked file, and does not pair renames', async () => {
  const { m, r, ready, decide } = world()
  await ready
  m.ran.length = 0
  await decide(r, 'git reset --hard')
  const argv = m.ran.find(a => a.includes('status'))!
  expect(argv, 'guard-status-lists-untracked-files').toContain('--untracked-files=all')
  expect(argv).toContain('--no-renames')
})

test('resource: a fresh machine has the record directory made before the first lease, with mode 700 once per load', async () => {
  const m = new Machine()
  const r = m.repo('/w/r')
  declareMachine(m, CHROME)
  const s = new Session(m, m.spawn(), 's1')
  expect((await s.peers.lease(CLICK, r, 's1')).decision, 'lease-on-a-fresh-machine').toBe('note')
  await s.touch(r)
  await s.touch(r)
  expect(m.ran.filter(a => a[2]?.includes('umask 077')).length, 'record-dir-made-private-once').toBe(1)
})

test('record: ps reads in UTC and the C locale; the sweep removes old object directories', async () => {
  const { m, r, ready, decide } = world()
  await ready
  expect(m.envs.ps).toEqual({ LC_ALL: 'C', TZ: 'UTC' })
  m.advance(3601)
  await decide(r, 'git status')
  expect(m.ran.some(a => a[2]?.includes('.objects.') && a[2].includes('-mmin +60')), 'record-sweep-removes-old-object-dirs').toBe(true)
})

test('the module needs a place for records: no HOME and no CC_TUNER_PEERS_DIR leaves no record and says so', async ($, on) => {
  const { m } = machine()
  m.repo('/w/r')
  const ran = engine(on, m, m.spawn())
  peersDir = undefined
  const { context } = await $.tool.call({ tool: 'Bash', command: 'npm test' })
  expect(ran).toEqual(['npm test'])
  expect(context?.join(' '), 'record-no-home-no-records').toContain('the peers guard is inactive')
  expect([...m.files.keys()].filter(p => p.endsWith('.json'))).toEqual([])
})

// --- session identity across nested, resume and reload ----------------------------------------------------------
test('record: a nested claude -p neither resets the outer record nor takes its session id', async () => {
  const { m } = machine()
  const r1 = m.repo('/w/r1')
  const outer = m.spawn(1, 'claude')
  const inner = m.spawn(m.spawn(outer, 'bash'), 'claude')
  m.put(`${r1}/plan.md`, '## Slice 1 — A\nOwned paths: lib/\n- [ ] a\n')
  const [o, n] = [new Session(m, outer, 'a'), new Session(m, inner, 'b')]
  await o.peers.claim(r1, 'a', 'plan.md')
  await o.check({ cwd: r1, tool: 'Bash', steps: [step('git status')], acks: ['deadbeef'] })
  await n.start(r1)
  expect(m.rec('a'), 'record-nested-start-keeps-the-outer-record').toMatchObject({ session_id: 'a', claims: { 'plan.md': { paths: ['lib/'] } } })
  expect(typeof m.rec('a').acks.deadbeef).toBe('number')
  expect(m.records(outer)).toBe(1)
})

test('record: an in-process resume of an earlier session takes over that tombstone', async () => {
  const { m, session } = machine()
  const r1 = m.repo('/w/r1')
  const old = session('x')
  await old.edited(r1, `${r1}/kept.txt`)
  m.edit('x', r => { r.claims = { 'plan.md': { repo: r.checkouts[r1]!.repo, paths: ['lib/'] } }; r.checkouts[r1]!.expected = 'feat' })
  m.end(old.pid)
  const me = session('me')
  await me.edited(r1, `${r1}/mine.txt`)
  await me.start(r1, 'x')
  expect(m.rec('me'), 'record-resume-in-process-merges-the-tombstone').toMatchObject({
    session_id: 'x', claims: { 'plan.md': { paths: ['lib/'] } }, checkouts: { [r1]: { expected: 'feat', paths: ['kept.txt', 'mine.txt'] } },
  })
  expect(m.files.has(`${DIR}/x.json`), 'the tombstone is gone').toBe(false)
})

test('resource: a shared task is in the record, so a reload of the module still holds it; stopping it, or a new process, clears it', async ($, on) => {
  const { m, session } = machine()
  m.repo('/w/r')
  declare(m, '/w/r', STACK)
  engine(on, m, m.spawn(), undefined, undefined, command => (command.startsWith('stack') ? command.split(' ')[2] : undefined))
  await $.tool.call({ tool: 'Bash', command: 'npm test' })
  m.edit('e1', r => { r.kept = [{ id: 'two', key: 'stack', top: '/w/r' }, { id: 'one', key: 'stack', top: '/w/r' }] })
  expect((await $.tool.call({ tool: 'TaskStop', task_id: 'one' })).deny, 'no other session uses it').toBeUndefined()
  expect(m.rec('e1').kept.map(k => k.id), 'resource-stopped-task-leaves-the-record').toEqual(['two'])
  const peer = session('peer')
  await peer.touch('/w/r')
  expect((await $.tool.call({ tool: 'TaskStop', task_id: 'two' })).deny, 'resource-kept-task-denied-from-the-record').toContain('task two runs stack')
  expect((await prompt($)), 'the start line names what is left').toContain('kept at /clear: stack (two)')
})

test('record: a new process that adopts a tombstone does not inherit its kept tasks', async () => {
  const { m, session } = machine()
  const r1 = m.repo('/w/r1')
  const old = session('s9')
  await old.touch(r1)
  m.edit('s9', r => { r.kept = [{ id: 'b1', key: 'stack' }] })
  m.end(old.pid)
  const resumed = session('s9')
  expect((await resumed.start(r1)).line).toBe('')
  expect(m.rec('s9').kept, 'resource-adoption-empties-kept').toEqual([])
})

// --- the writer mark waits for the engine ------------------------------------------------------------------------
test('guard: a writer is marked after the call ran, not by a call the engine denied or one that was stopped', async () => {
  const { m, session } = machine()
  const r = m.repo('/w/r')
  const s = session('s')
  await s.before(r, 'npm test')
  expect(writerOf(m, 's', r), 'guard-writer-not-marked-before-the-call').toBeNull()
  await s.after(r, ['npm test'], undefined, false)
  expect(writerOf(m, 's', r), 'guard-writer-not-marked-by-a-failed-call').toBeNull()
  await s.after(r, ['git status'])
  expect(writerOf(m, 's', r), 'a read-only call marks none').toBeNull()
  await s.after(r, ['npm test'])
  expect(typeof writerOf(m, 's', r)).toBe('number')
})

test('the module marks a writer only for a call the engine let through', async ($, on) => {
  const { m } = machine()
  m.repo('/w/r')
  engine(on, m, m.spawn())
  expect((await $.tool.call({ tool: 'Bash', command: 'denied' })).deny).toBe('denied by the engine')
  expect(writerOf(m, 'e1', '/w/r'), 'guard-denied-call-marks-no-writer').toBeNull()
  await $.tool.call({ tool: 'Bash', command: 'npm test' })
  expect(typeof writerOf(m, 'e1', '/w/r')).toBe('number')
})

// --- guard semantics: what stops, and what the reason says ------------------------------------------------------
test('ack: the key names the files, so a file that appears later stops again', async () => {
  const { m, r, ready, decide, acked } = world()
  await ready
  m.dirty(r, ' M a.txt')
  const k = /CC_TUNER_ACK=([0-9a-f]{8})/.exec((await decide(r, 'git reset --hard')).reason!)![1]!
  expect((await acked(r, k, 'git reset --hard')).decision).toBe('allow')
  expect((await decide(r, 'git reset --hard')).decision).toBe('allow')
  m.dirty(r, ' M b.txt')
  const again = await decide(r, 'git reset --hard')
  expect(again.decision, 'guard-ack-key-includes-the-files').toBe('stop')
  expect(again.reason).not.toContain(`ACK=${k}`)
  const wt = m.worktree(r, '/w/t/wt', 'wt')
  m.dirty(wt, '?? one.txt')
  const rm = /CC_TUNER_ACK=([0-9a-f]{8})/.exec((await decide(r, `rm -rf ${wt}`)).reason!)![1]!
  m.dirty(wt, '?? two.txt')
  expect((await decide(r, `rm -rf ${wt}`)).reason, 'a removal asks again for a new file').not.toContain(`ACK=${rm}`)
})

test('guard: checkout of a path that is no ref is a discard, and a forced switch discards tracked changes', async () => {
  const { m, r, peer, me, ready, decide } = world()
  await ready
  m.end(peer.pid)
  m.put(`${r}/src/a.ts`, 'a')
  m.refs.add('feature')
  m.dirty(r, ' M src/a.ts')
  const path = await decide(r, 'git checkout src/a.ts')
  expect(path.decision, 'guard-checkout-of-a-path-without-dashes').toBe('stop')
  expect(path.reason).toContain('would overwrite src/a.ts')
  for (const c of ['git checkout feature', 'git checkout -b src/a.ts', 'git switch feature', 'git switch -c fresh', 'git checkout nosuchbranch']) expect((await decide(r, c)).decision, c).toBe('allow')
  for (const c of ['git switch -f feature', 'git switch --force feature', 'git switch --discard-changes feature', 'git checkout -f feature', 'git checkout --force feature']) {
    const v = await decide(r, c)
    expect(v.decision, `guard-forced-switch-discards: ${c}`).toBe('stop')
    expect(v.reason).toContain('src/a.ts')
  }
  await me.edited(r, `${r}/src/a.ts`)
  for (const c of ['git checkout src/a.ts', 'git switch -f feature', 'git checkout -f feature']) expect((await decide(r, c)).decision, `own: ${c}`).toBe('allow')
})

test('guard: a rebase in progress is not drift', async () => {
  const { m, r, peer, ready, decide } = world()
  await ready
  m.end(peer.pid)
  m.head(r, undefined)
  expect((await decide(r, 'git commit -m m')).decision).toBe('stop')
  m.mkdir(`${r}/.git/rebase-merge`)
  expect((await decide(r, 'git commit -m m')).decision, 'guard-rebase-in-progress-skips-drift').toBe('allow')
  m.drop(`${r}/.git/rebase-merge`)
  m.mkdir(`${r}/.git/rebase-apply`)
  expect((await decide(r, 'git push origin main')).decision).toBe('allow')
})

test('guard: the reasons name the safe way first, and the choice is the agent\'s only where a peer owns the files', async () => {
  const { m, r, peer, ready, decide } = world()
  await ready
  m.dirty(r, ' M mine.txt')
  const unknown = (await decide(r, 'git reset --hard')).reason!
  expect(unknown, 'guard-unknown-owner-may-be-the-users').toContain("user's own edits")
  expect(unknown).toContain('own paths')
  expect(unknown).not.toContain('not a question for the user')
  await peer.edited(r, `${r}/mine.txt`)
  const owned = (await decide(r, 'git reset --hard')).reason!
  expect(owned).toContain(`pid ${peer.pid} on main`)
  expect(owned).toContain('not a question for the user')
  m.end(peer.pid)
  m.head(r, 'x')
  const drift = (await decide(r, 'git commit -m m')).reason!
  expect(drift, 'guard-drift-names-the-way-back').toContain('git switch main')
  expect(drift.indexOf('git switch main')).toBeLessThan(drift.indexOf('CC_TUNER_ACK='))
})

test('record: a reftable HEAD is read through git', async () => {
  const { m, session } = machine()
  const r = m.repo('/w/r')
  m.put(`${r}/.git/HEAD`, 'ref: refs/heads/.invalid\n')
  m.symbolic.set(r, 'real')
  await session('s').touch(r)
  expect(m.rec('s').checkouts[r]!.expected, 'record-reftable-head').toBe('real')
})
