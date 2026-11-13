import type { EngineInterface, Register } from 'claude-code'

// Claude Code stops a session's background tasks when the process exits, but
// a /clear ends the conversation and leaves them running under the next one.
// The agent that started them no longer knows they exist, so they are stopped
// here. Ids are module state: a reload loses them, and exit still stops those.
// An id leaves the set when the agent stops the task itself; a task that ends
// on its own is not observable from a hook, and stopping it later is harmless.
const started = new Set<string>()

// The subagent panel shows an agent's type and its live activity, never its model, and a plugin
// cannot redraw that panel. The status line carries the models of the subagents still running.
const models = new Map<string, string>()
const ACTIVE = new Set(['pending', 'running', 'waiting'])
const ENDED = new Set(['completed', 'failed', 'killed'])
const family = (model: string) => /fable|mythos|opus|sonnet|haiku/.exec(model)?.[0] ?? model

async function showModels($: EngineInterface) {
  const agents = await $.agent.list()
  const counts = new Map<string, number>()
  for (const agent of agents) {
    const model = models.get(agent.id)
    if (model === undefined) continue
    if (ENDED.has(agent.status)) models.delete(agent.id)
    else if (ACTIVE.has(agent.status)) counts.set(model, (counts.get(model) ?? 0) + 1)
  }
  $.ui.status(counts.size === 0 ? undefined : `subagents: ${[...counts].map(([m, n]) => `${n} ${m}`).join(' · ')}`)
}

// A printed secret is in the transcript for good, so this one effect is refused at the call rather
// than left to prose: `env`, `printenv`, `set`, `export`, `declare` or `typeset` with nothing to run
// or name dumps every variable with its value, and reading a `.env` file prints its values. Each
// refusal names commands that answer the same question and print no value even when one spans
// lines (a PEM key does; `cut -d= -f1` would print its body). Templates (`.env.example`) hold none.
const CHECK_SET = "printenv NAME | wc -c"
const LIST_NAMES = "awk 'BEGIN { for (k in ENVIRON) print k }'"
const CHECK_KEY = "grep -c '^NAME=' FILE"
const DUMPS = new Set(['env', 'printenv', 'set', 'export', 'declare', 'typeset'])
const READERS = new Set(['cat', 'head', 'tail', 'less', 'more', 'bat'])
const PREFIXES = new Set(['!', '{', '}', 'if', 'then', 'elif', 'else', 'while', 'until', 'do', 'time', 'command', 'builtin', 'exec'])
const WRAPPERS = new Set(['command', 'builtin', 'exec'])
const LOOKUP = /^-[pvV]*[vV][pvV]*$/
const ASSIGNMENT = /^[A-Za-z_]\w*=/
const ENV_FILE = /(^|\/)\.env([.*?[][\w.*?[\]-]*)?$/
const TEMPLATE = /\.(example|sample|template|dist)$/

// The simple commands shell text would run, each as its words with quotes and escapes resolved and
// the files it reads on stdin (`< file`). One reader handles every place the shell expands text —
// words, double quotes, unquoted heredoc bodies, redirection targets — so a $( … ) or backquote is
// scanned as commands of its own wherever it sits, and an escaped one stays literal. A heredoc
// delimiter is read the same way but, as in the shell, only loses its quotes: a $( … ) in it is
// text. Comments, quoted heredoc bodies and other redirections drop out.
// Each command also keeps the directory it runs in (`dir`, relative to where the text starts or
// absolute) and the operator that joins it to the command before it (`op`: `&&`, `||`, `;` or `|`,
// empty for the first), and whether a redirection writes a file (`writes`). A `cd` moves the commands
// after it; a $( … ), backquote or ( … ) keeps its own `cd` to itself, and so does a pipeline stage.
interface Simple { words: string[]; inputs: string[]; dir: string; op: string; writes: boolean }
const METACHARS = ' \t\n;&|()<>'
const OPERATORS = ['&&', '||', '|&', '|', ';', '&']
const at = (dir: string, to: string) => to.startsWith('/') || dir === '' ? to : `${dir}/${to}`

function commands(text: string, base = '', first = ''): Simple[] {
  const found: Simple[] = []
  const heredocs: { end: string; tabs: boolean; quoted: boolean }[] = []
  let i = 0
  let quoted = false
  let literal = false
  let dir = base
  let op = first

  // A command list from i; nested, it stops after the `)` that closes its $(.
  function list(nested: boolean) {
    let current: Simple = { words: [], inputs: [], dir, op, writes: false }
    const parens: string[] = []
    // Ends the command at an operator (`joined` is its text) and makes that operator the next one's.
    const end = (joined?: string) => {
      if (current.words.length > 0 || current.inputs.length > 0) {
        current.dir = dir
        current.op = op
        found.push(current)
        const [name, ...args] = current.words.slice(lead(current.words))
        const to = args.find(a => a !== '--' && !/^-[LPe@]+$/.test(a))
        if (name === 'cd' && joined !== '|' && joined !== '&' && to !== undefined && to !== '-' && !to.startsWith('~')) dir = at(dir, to)
      }
      current = { words: [], inputs: [], dir, op, writes: false }
      if (joined !== undefined) op = joined === '&' ? ';' : joined === '|&' ? '|' : joined
    }
    while (i < text.length) {
      const c = text[i]!
      if (c === '\n') { end(';'); i++; bodies() } else if (c === ' ' || c === '\t') i++
      else if (c === '#') { while (i < text.length && text[i] !== '\n') i++ } else if (c === '(') { end(); parens.push(dir); i++ } else if (c === ')') {
        end()
        i++
        if (parens.length === 0 && nested) return
        dir = parens.pop() ?? dir
      } else if (c === '&' && text[i + 1] === '>') { i++; redirect(current) } else if (';&|'.includes(c)) {
        const joined = OPERATORS.find(o => text.startsWith(o, i))!
        end(joined)
        i += joined.length
      } else if (c === '<' || c === '>') redirect(current)
      else {
        const w = word()
        if ((text[i] === '<' || text[i] === '>') && /^\d+$/.test(w)) redirect(current)
        else current.words.push(w)
      }
    }
    end()
  }

  // One word up to the next unquoted metacharacter.
  function word(): string {
    let out = ''
    let q = false
    while (i < text.length && !METACHARS.includes(text[i]!)) {
      const c = text[i]!
      const start = i
      if (c === "'") {
        q = true
        const close = text.indexOf("'", i + 1)
        out += text.slice(i + 1, close === -1 ? text.length : close)
        i = close === -1 ? text.length : close + 1
      } else if (c === '"') {
        q = true
        i++
        out += expand('"', text.length)
      } else if (c === '\\') {
        q = true
        if (text[i + 1] !== '\n') out += text[i + 1] ?? ''
        i += 2
      } else if (substitution()) { if (literal) out += text.slice(start, i) } else { out += c; i++ }
    }
    quoted = q
    return out
  }

  // Expandable text up to `close` (double quotes) or `limit` (a heredoc body).
  function expand(close: string | undefined, limit: number): string {
    const escapable = close === undefined ? '$`\\\n' : '$`"\\\n'
    let out = ''
    while (i < limit) {
      const c = text[i]!
      if (c === close) { i++; return out }
      const start = i
      if (c === '\\' && escapable.includes(text[i + 1] ?? '')) {
        if (text[i + 1] !== '\n') out += text[i + 1]
        i += 2
      } else if (substitution()) { if (literal) out += text.slice(start, i) } else { out += c; i++ }
    }
    return out
  }

  // At $( or a backquote: scans the body as commands and moves past it, keeping them unless literal.
  function substitution(): boolean {
    const kept = found.length
    if (text.startsWith('$(', i)) {
      const [outerDir, outerOp] = [dir, op]
      i += 2
      list(true)
      ;[dir, op] = [outerDir, outerOp]
      if (literal) found.length = kept
      return true
    }
    if (text[i] !== '`') return false
    let body = ''
    for (i++; i < text.length && text[i] !== '`'; i++) {
      if (text[i] === '\\' && '`$\\'.includes(text[i + 1] ?? '')) i++
      body += text[i]
    }
    i++
    if (!literal) found.push(...commands(body, dir, op))
    return true
  }

  function redirect(current: Simple) {
    const op = /^(<<-|<<<|<<|<>|<&|>>|>&|>\||<|>)/.exec(text.slice(i))![0]
    i += op.length
    while (text[i] === ' ' || text[i] === '\t') i++
    const heredoc = op === '<<' || op === '<<-'
    const outer = literal
    literal = outer || heredoc
    const target = word()
    literal = outer
    if (outer) return
    if (heredoc) heredocs.push({ end: target, tabs: op === '<<-', quoted })
    else if (op === '<' || op === '<>') current.inputs.push(target)
    if (/^(>>?|>\||<>|>&)$/.test(op) && target !== '/dev/null' && !(op === '>&' && /^(\d+-?|-)$/.test(target))) current.writes = true
  }

  // The heredoc bodies that start after a newline; unquoted ones expand like double quotes.
  function bodies() {
    for (const doc of heredocs.splice(0)) {
      let at = i
      let bodyEnd = text.length
      let next = text.length
      while (at < text.length) {
        const eol = text.indexOf('\n', at)
        const line = text.slice(at, eol === -1 ? text.length : eol)
        if ((doc.tabs ? line.replace(/^\t+/, '') : line) === doc.end) {
          bodyEnd = at
          next = eol === -1 ? text.length : eol + 1
          break
        }
        at = eol === -1 ? text.length : eol + 1
      }
      if (!doc.quoted) expand(undefined, bodyEnd)
      i = Math.max(i, next)
    }
  }

  list(false)
  return found
}

function dumps(name: string, args: string[]): boolean {
  if (name === 'set') return args.length === 0
  if (name !== 'env') return args.every(arg => arg.startsWith('-'))
  for (let k = 0; k < args.length; k++) {
    const arg = args[k]!
    if (arg === '-S' || arg.startsWith('--split-string')) return false
    if (arg === '-u' || arg === '-P' || arg === '-C') k++
    else if (!arg.startsWith('-') && !ASSIGNMENT.test(arg)) return false
  }
  return true
}

// Where the command proper starts: past control words, variable assignments and the wrappers that
// only pass the command on (`command`, `builtin`, `exec`, with their options).
function lead(words: string[]): number {
  let at = 0
  while (at < words.length && (PREFIXES.has(words[at]!) || ASSIGNMENT.test(words[at]!))) {
    if (WRAPPERS.has(words[at]!)) {
      const wrapper = words[at++]!
      while (at < words.length && words[at]!.startsWith('-')) {
        const option = words[at]!
        if (wrapper === 'command' && LOOKUP.test(option)) at = words.length
        else at += option === '-a' ? 2 : 1
        if (option === '--') break
      }
    } else at++
  }
  return at
}

function secretLeak(command: string): string | undefined {
  for (const { words, inputs } of commands(command)) {
    const [name, ...args] = words.slice(lead(words))
    if (name !== undefined && DUMPS.has(name) && dumps(name, args)) {
      return `cc-tuner: \`${[name, ...args].join(' ')}\` prints every variable's value, secrets included, into the transcript. ` +
        `Check one is set with \`${CHECK_SET}\`; list names only with \`${LIST_NAMES}\`.`
    }
    const read = name === undefined || READERS.has(name) ? [...args, ...inputs] : []
    const file = read.find(arg => ENV_FILE.test(arg) && !(TEMPLATE.test(arg) && !/[*?[]/.test(arg)))
    if (file !== undefined) {
      return `cc-tuner: \`${name ?? '<'} ${file}\` prints secret values into the transcript. ` +
        `Check a key is set with \`${CHECK_KEY.replace('FILE', file)}\`; key names come from its template (\`.env.example\`) or the user.`
    }
  }
  return undefined
}

// What the session's guard reads of a command: the commands that actually run, in order, each in the
// directory it runs in. The wrappers that start another command unwrap, and the command inside keeps
// the wrapper's scope: `heavy.sh --`, `bash -c`, `env`, `xargs`, `git -C`. A `cd` is not a step, it
// moved the directory of the steps after it. A wrapper it cannot read stays a step as written.
interface Step { words: string[]; dir: string; op: string; writes: boolean }
const SHELLS = new Set(['bash', 'sh', 'zsh', 'dash'])
const XARGS_VALUED = new Set(['-n', '-I', '-L', '-P', '-d', '-E', '-s', '-a'])
const GIT_QUIET = new Set(['--no-pager', '--no-optional-locks', '-P'])
const base = (word: string | undefined) => (word ?? '').slice((word ?? '').lastIndexOf('/') + 1)

function unwrap(simple: Simple): Step[] {
  let words = simple.words.slice(lead(simple.words))
  let dir = simple.dir
  for (;;) {
    const name = base(words[0])
    const args = words.slice(1)
    if (name === 'cd') return []
    if (name === 'env') {
      let k = 0
      for (; k < args.length && (args[k]!.startsWith('-') || ASSIGNMENT.test(args[k]!)); k++) {
        if (args[k] === '-S' || args[k]!.startsWith('--split-string')) break
        if (args[k] === '-C') dir = at(dir, args[++k] ?? '')
        else if (args[k] === '-u' || args[k] === '-P') k++
      }
      if (k < args.length && args[k]!.startsWith('-')) break
      words = args.slice(k)
    } else if (name === 'xargs') {
      let k = 0
      while (k < args.length && args[k]!.startsWith('-')) k += XARGS_VALUED.has(args[k]!) ? 2 : 1
      words = args.slice(k)
    } else if (name === 'heavy.sh' || (SHELLS.has(name) && base(args[0]) === 'heavy.sh')) {
      const dash = words.indexOf('--')
      if (dash === -1) break
      words = words.slice(dash + 1)
    } else if (SHELLS.has(name)) {
      const c = args.findIndex(a => /^-[a-z]*c[a-z]*$/.test(a))
      if (c === -1 || args[c + 1] === undefined) break
      const inner = commands(args[c + 1]!, dir, simple.op).flatMap(unwrap)
      return inner.map(step => ({ ...step, writes: step.writes || simple.writes }))
    } else if (name === 'git') {
      const rest: string[] = []
      let k = 0
      for (; k < args.length && args[k]!.startsWith('-'); k++) {
        if (args[k] === '-C') dir = at(dir, args[++k] ?? '')
        else if (args[k] === '-c') k++
        else if (!GIT_QUIET.has(args[k]!)) rest.push(args[k]!)
      }
      words = ['git', ...rest, ...args.slice(k)]
      break
    } else break
    words = words.slice(lead(words))
  }
  return words.length === 0 ? [] : [{ words, dir, op: simple.op, writes: simple.writes }]
}

function steps(command: string): Step[] {
  return commands(command).flatMap(unwrap)
}

// The guard is scripts/peers.sh, which owns the record of what each session did and every decision:
// allow, a note (the call runs and the agent reads it after the result) or a stop (the reason is the
// call's error). A failure here is never the tool call's: the call goes on. The Claude process is the
// parent of the child `$.process.run` starts, read once per module load; the record is keyed by it.
let claude = ''

interface Verdict { decision: 'allow' | 'note' | 'stop'; reason?: string; seen?: Record<string, string> }

// The way on from a stop is the same command prefixed with its key. The guard records the ack from the
// event; the prefix goes before the call, so a user's allow rule such as `Bash(git switch:*)` still matches.
const ACK = /^CC_TUNER_ACK=(\S+) /

const noted = <T extends { deny?: string; context?: readonly string[] }>(ran: T, verdict?: Verdict): T =>
  verdict?.decision === 'note' && ran.deny === undefined ? { ...ran, context: [...(ran.context ?? []), verdict.reason ?? ''] } : ran

async function guard($: EngineInterface, event: object): Promise<Verdict | undefined> {
  try {
    if (claude === '') claude = (await $.process.run(['/bin/sh', '-c', 'echo $PPID'])).stdout.trim()
    const ran = await $.process.run(['bash', `${$.plugin.root}/scripts/peers.sh`, 'check'], {
      stdin: JSON.stringify({ session_id: await $.session.id(), cwd: await $.session.cwd(), ...event }),
      env: { CC_TUNER_PEERS_CLAUDE_PID: claude },
      timeoutMs: 5000,
    })
    return ran.exitCode === 0 ? JSON.parse(ran.stdout) : undefined
  } catch {
    return undefined
  }
}

export const register: Register = on => {
  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const ack = ACK.exec(e.command)
    const command = ack === null ? e.command : e.command.slice(ack[0].length)
    const leak = secretLeak(command)
    if (leak !== undefined) return { deny: leak }
    const before = await guard($, { phase: 'before', tool: 'Bash', steps: steps(command), ack: ack?.[1] })
    if (before?.decision === 'stop') return { deny: before.reason ?? 'cc-tuner: stopped' }
    const ran = await next(ack === null ? e : { ...e, command })
    if (before?.seen !== undefined) await guard($, { phase: 'after', tool: 'Bash', seen: before.seen })
    if (ran.deny === undefined && ran.isError !== true && ran.result.backgroundTaskId) {
      started.add(ran.result.backgroundTaskId)
    }
    return noted(ran, before)
  })

  on('tool.call', { tool: ['Edit', 'Write', 'NotebookEdit'] }, async ($, e, next) => {
    const path = 'file_path' in e ? e.file_path : e.notebook_path
    const before = await guard($, { phase: 'before', tool: e.tool, path })
    const ran = await next(e)
    if (ran.deny === undefined && ran.isError !== true) await guard($, { phase: 'after', tool: e.tool, path })
    return noted(ran, before)
  })

  on('tool.call', { tool: 'TaskStop' }, async ($, e, next) => {
    const ran = await next(e)
    if (ran.deny === undefined && ran.isError !== true) started.delete(ran.result.task_id)
    return ran
  })

  on('agent.spawn', async ($, e, next) => {
    const spawned = await next(e)
    if (spawned.deny === undefined && spawned.agentId) {
      models.set(spawned.agentId, family(spawned.model))
      await showModels($)
    }
    return spawned
  })

  on('turn.complete', async ($, e, next) => {
    const done = await next(e)
    if (models.size > 0) await showModels($)
    return done
  })

  on('session.end', async ($, e, next) => {
    if (e.reason === 'clear') {
      const ids = [...started]
      const results = await Promise.allSettled(ids.map(task_id => $.tool.call({ tool: 'TaskStop', task_id })))
      // Only confirmed stops leave the set: an id whose stop failed stays for the next /clear (exit
      // still stops it; a task that already ended can answer with an error, harmless to retry), and
      // a task started while the stops were awaited was never in the snapshot and stays too.
      const unstopped: string[] = []
      ids.forEach((id, i) => {
        const r = results[i]
        if (r?.status === 'fulfilled' && r.value.deny === undefined && r.value.isError !== true) started.delete(id)
        else unstopped.push(id)
      })
      if (unstopped.length > 0) {
        $.ui.log(`cc-tuner: /clear could not confirm stopping ${unstopped.join(', ')}; retrying next /clear`, { to: 'debug' })
      }
    }
    return next(e)
  })
}
