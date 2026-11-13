import type { On } from 'claude-code'
import { expect, test } from 'claude-code/testing'
import { Peers, ownedOpen, type Event, type Rec, type Step, type World } from './peers'

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
      read: async p => { const f = this.files.get(p); if (f === undefined) throw new Error(`ENOENT ${p}`); return f.text },
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
      run: async argv => {
        this.ran.push([...argv])
        return { exitCode: 0, ...this.answer(pid, argv) }
      },
      now: () => this.clock,
    }
  }

  private answer(pid: number, argv: readonly string[]): { exitCode?: number; stdout: string } {
    const [cmd, ...a] = argv
    if (cmd === '/bin/sh' && a[1] === 'echo $PPID') return { stdout: `${pid}\n` }
    if (cmd === 'ps') return { stdout: this.ps(a.includes('-p') ? a[a.indexOf('-p') + 1]!.split(',').map(Number) : undefined) }
    if (cmd === 'git' && a[2] === 'status') return { stdout: (this.status.get(a[1]!) ?? []).map(e => `${e}\0`).join('') }
    if (cmd === 'git' && a[2] === 'rev-parse') return { stdout: `${this.shas.get(a[1]!) ?? ''}\n` }
    // The lease scripts, as the shell runs them: one atomic step each.
    if (cmd === '/bin/sh' && a[1]?.includes('mkdir')) {
      const [lock, seen, info] = a.slice(3) as [string, string, string]
      if (this.dirs.has(lock) && this.cat(`${lock}/holder.json`) === seen) this.drop(lock)
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
  touch(cwd: string) { return this.check({ tool: 'Bash', cwd }) }
  bash(cwd: string, ...steps: (string | Partial<Step>)[]) {
    return this.check({ tool: 'Bash', cwd, steps: steps.map(s => (typeof s === 'string' ? step(s) : { ...step(''), ...s })) })
  }
  edited(cwd: string, path: string, tool = 'Edit') { return this.check({ phase: 'after', tool, cwd, path }) }
  start(source: string, cwd: string, sid = this.sid) { return this.peers.check({ session_id: sid, phase: 'start', source, cwd }) }
  report(cwd: string) { return this.peers.report(cwd) }
}
const step = (text: string, dir = '', op = ''): Step => ({ words: text === '' ? [] : text.split(' '), dir, op, writes: false })

function machine() {
  const m = new Machine()
  m.mkdir(DIR)
  let n = 0
  const session = (sid = `s${++n}`, pid = m.spawn()) => new Session(m, pid, sid)
  return { m, session }
}

// A Bash call as the adapter makes it: `before`, the command's effect on the machine, then `after` with
// what `before` saw, sent only when it saw something.
async function call(s: Session, cwd: string, steps: (string | Partial<Step>)[], effect?: () => void) {
  const v = await s.bash(cwd, ...steps)
  if (v.decision !== 'stop') effect?.()
  if (v.seen !== undefined) await s.check({ phase: 'after', tool: 'Bash', cwd, seen: v.seen })
  return v
}
const at = (dir: string, text: string, op = ''): Partial<Step> => step(text, dir, op)
const then = (text: string, op = '&&'): Partial<Step> => step(text, '', op)
const writes = (text: string): Partial<Step> => ({ ...step(text), writes: true })

// --- the adapter: the hooks module in front of the guard ----------------------------------------------------
// The module reads and writes records with $.fs and runs `ps` and git with $.process.run; the test's hooks
// stand for those, backed by the machine.
function engine(on: On, m: Machine, pid: number, effect: (command: string) => void = () => {}, broken = () => false,
  task: (command: string) => string | undefined = () => undefined) {
  const w = m.world(pid)
  on('classic.SessionStart', () => ({}))
  on('session.id', () => ({ value: 'e1' }))
  on('session.cwd', () => ({ value: '/w/r' }))
  on('ui.log', () => ({ value: undefined }))
  on('env.get', (_, e) => ({ value: e.name === 'CC_TUNER_PEERS_DIR' ? DIR : e.name === 'CC_TUNER_PEERS_CONFIG' ? USER : undefined }))
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

test('an ack is recorded from the prefix and stripped before the command runs; only a prefix is one', async ($, on) => {
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
  expect(Object.keys(m.rec('e1').acks)).toEqual([key])
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
  expect((await $.tool.call({ tool: 'Bash', command: 'npm test' })).deny).toBeUndefined()
  expect(ran).toEqual(['npm test'])
})

test('the start line reaches the context from the module, on startup, clear and resume', async ($, on) => {
  const { m, session } = machine()
  m.repo('/w/r')
  await session('peer').touch('/w/r')
  engine(on, m, m.spawn())
  for (const source of ['startup', 'clear', 'resume'] as const) {
    const done = await $.classic.SessionStart({ source, session_id: `e-${source}`, cwd: '/w/r' })
    expect(done.additionalContext?.join('\n'), source).toContain('cc-tuner: live peers: main (r, pid')
  }
})

test('the start line is silent without peers', async ($, on) => {
  const { m } = machine()
  m.repo('/w/r')
  engine(on, m, m.spawn())
  const done = await $.classic.SessionStart({ source: 'startup', session_id: 'e1', cwd: '/w/r' })
  expect(done.additionalContext ?? []).toEqual([])
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
  await resumed.start('resume', r1)
  expect(m.rec('s5')).toMatchObject({ pid: resumed.pid, start: m.procs.get(resumed.pid)!.start })
  expect(m.rec('s5').checkouts[r1]!.paths).toEqual(['kept.txt'])
  expect(m.records(resumed.pid)).toBe(1)
})

test('record: /clear drops acks and claims, keeps the kept task, and follows the new session id', async () => {
  const { m, session } = machine()
  const r1 = m.repo('/w/r1')
  const s6 = session('s6')
  await s6.touch(r1)
  m.edit('s6', r => { r.acks = { k: 1 }; r.claims = { 'plan.md': { repo: 'x', paths: ['a'] } }; r.kept = ['dev server'] })
  await s6.start('clear', r1, 's6b')
  expect(m.rec('s6')).toMatchObject({ acks: {}, claims: {}, kept: ['dev server'], session_id: 's6b' })
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
  expect(m.files.has(`${DIR}/merge/sha-${ra}-sha-${wa}`), 'report-caches-per-sha-pair').toBe(true)
  m.put(`${DIR}/merge/sha-${ra}-sha-${wa}`, '["cached.txt"]')
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
test('start: the line appears only with live peers or a kept task, on startup, clear and resume', async () => {
  const { m, session } = machine()
  const rs = m.repo('/w/rs')
  const [p1, p2] = [session('t1'), session('t2')]
  for (const source of ['startup', 'clear', 'resume']) expect((await p1.start(source, rs)).line, source).toBe('')
  const { line } = await p2.start('startup', rs)
  expect(line).toBe(`cc-tuner: live peers: main (rs, pid ${p1.pid}). More: the peers_report tool.`)
  expect((await p2.start('clear', rs, 't2c')).line).toContain('live peers: main')
  expect((await p2.start('resume', rs, 't2c')).line).toContain('live peers: main')
  m.edit('t2', r => { r.kept = ['dev server'] })
  m.end(p1.pid)
  const kept = (await p2.start('startup', rs, 't2c')).line!
  expect(kept).toContain('kept at /clear: dev server')
  expect(kept).not.toContain('live peers')
  m.edit('t2', r => { r.kept = [] })
  expect((await p2.start('startup', rs, 't2c')).line).toBe('')
})

test('start: the line reaches the product, and skips an unrelated one', async () => {
  const { ra, rb, rc, sr, sb, sc } = products()
  await sr.touch(ra)
  expect((await sb.start('startup', rb)).line).toContain('live peers:')
  expect((await sc.start('startup', rc)).line).toBe('')
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
  await call(g, re, ['git switch nosuch', then('true', ';')])
  expect(expected(), 'guard-drifted-failed-switch-then-true-keeps-it').toBe('a')
  await call(g, re, ['false', then('git switch c')])
  expect(expected(), 'guard-drifted-skipped-switch-keeps-it').toBe('a')
  await call(g, re, ['git switch c'], () => m.head(re, 'c'))
  expect(expected(), 'guard-drifted-successful-switch-moves-it').toBe('c')
  state('a', 'b')
  await call(g, re, ['git checkout --detach'], () => m.head(re, undefined))
  expect(expected(), 'guard-detaching-keeps-it').toBe('a')
  m.head(re, 'a')
  await call(g, re, [at(rw, 'git switch other')], () => m.head(rw, 'other'))
  expect(expected(rw), 'guard-switch-elsewhere-moves-that-checkout').toBe('other')
  expect(expected(), 'guard-switch-elsewhere-leaves-the-cwd-checkout').toBe('a')
})

// --- the guard stops what would destroy a peer's checkout, files, branch or process ------------------------------
// A repository where a live peer is a writer and this session has been.
function world() {
  const { m, session } = machine()
  const r = m.repo('/w/r')
  const [peer, me] = [session('peer'), session('me')]
  const ready = (async () => { await peer.touch(r); await me.bash(r, 'git status') })()
  const decide = async (cwd: string, ...steps: (string | Partial<Step>)[]) => me.bash(cwd, ...steps)
  const acked = (cwd: string, ack: string, ...steps: string[]) => me.check({ tool: 'Bash', cwd, steps: steps.map(s => step(s)), ack })
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
  expect((await decide(r, at('../x', 'git status'), step('echo', '', '-'), then('git reset --hard', ';'))).decision, 'behind wrappers').toBe('stop')
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
  expect(await decide(r, 'lsof -ti :4000', then('kill', '|'))).toBe('stop')
  expect(await decide(r, 'lsof -ti :1', 'kill')).toBe('allow')
  expect(await decide(r, 'kill $PID')).toBe('note')
  m.end(p)
  expect(await decide(r, `kill ${pc}`)).toBe('allow')
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
  await me.start('clear', r)
  expect(m.rec('me').acks).toEqual({})
})

test('a decision spawns only the processes it needs: ps once a minute, git status before losing files', async () => {
  const { m, r, ready, decide } = world()
  await ready
  m.ran.length = 0
  for (const c of ['ls', 'npm test', 'git switch x', 'git commit -m m']) await decide(r, c)
  expect(m.ran.map(a => a.slice(0, 4).join(' '))).toEqual([`git -C ${r} status`])
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
  expect((await sr.check({ tool: 'Bash', cwd: ra, steps: [step('stack down')], ack: key })).decision, 'resource-shared-stop-takes-an-ack').toBe('allow')
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
  expect(m.rec('e1').kept).toEqual(['stack (b1)'])
  const done = await $.classic.SessionStart({ source: 'clear', session_id: 'e1', cwd: '/w/r' })
  expect(done.additionalContext?.join('\n'), 'resource-clear-start-line-names-the-task').toContain('kept at /clear: stack (b1)')
})
