#!/usr/bin/env bash
# Sessions of one product see each other: who is live next to this session, on which branch, claiming
# and editing which paths, and whose branch would conflict with this one.
#
#   peers.sh check             read one JSON event on stdin, update this session's record, answer
#                              allow, note or stop; the guard's entry point
#   peers.sh report            the live peers of this repository and of its product
#   peers.sh claim <plan>      publish the open Owned paths of a plan, then report their overlap
#
# `check` events, one per phase, carry session_id, phase (before | after | start), tool and cwd:
#   Bash before   ack: the key of an earlier stop, which the caller stripped from the command, and
#                 steps: [{words, dir, op, writes}] one per simple command, the unwrapped one that runs:
#                 dir its directory (relative to cwd, or absolute), op the operator joining it to the
#                 step before (&& || ; |, empty for the first), writes a redirection to a file. A step
#                 that is not a known read-only form (git status/log/diff/show, ls, cat, grep, rg, find
#                 without -delete, -exec, --output or --pre) makes the session a writer in its checkout.
#                 The answer carries seen {checkout: branch} for each checkout holding a switch step.
#   Bash after    seen, as answered: the expectation moves to a checkout's branch only if HEAD changed.
#   Edit | Write | NotebookEdit before   path: a note when a peer writes in the checkout or claims the path.
#   Edit | Write | NotebookEdit after    path, sent after a call that succeeded.
#   start         the SessionStart hook: source (startup | clear | resume); the answer is the line
#                 session-start.sh prints, empty without peers.
# The answer is {"decision": allow | note | stop, "reason": ...} plus seen. A stop is the reason the call
# is refused with: who, what would be lost, and the ack key that lets the same command through for 30 min
# (one action on one target); a note runs the call and is said to the agent. A stopped call marks no
# writer. Whatever fails here, the caller lets the tool call go on.
#
# What stops: a branch switch next to a peer that wrote in the checkout in the last 2 h; discarding or
# committing a foreign file (dirty, staged or untracked, and not edited by this session through
# Edit/Write: a peer's, the user's, a tool's; no peer is needed, and a dead peer's stay protected);
# `stash drop|clear` while a peer works in the repository; commit, push or PR from a branch other than
# the expected one; deleting a peer's expected branch; removing a worktree that is a peer's cwd or holds
# foreign files; `kill` of a process that descends from a peer. A peer is a live session, so a dead one
# lifts every stop that depends on one. Notes: an edit next to a writer or of a claimed path (once an
# hour per peer), a switch next to a peer's cwd, a git or kill command that cannot be read.
#
# One JSON record per Claude session in the record directory, written by rename under a flock on
# <dir>/.lock. A session is its Claude process: pid plus start time, and a nested `claude -p` counts
# as the outermost `claude` above it. A record whose process is gone becomes a tombstone for 24 h; a
# resumed session with the same session_id adopts it. `/clear` drops acks and claims. A record that
# does not parse is skipped, and `report` says so.
# A process start time read from `ps` is kept for a minute in <dir>/.starts, so most calls run no `ps`.
#
#   {session_id, pid, start, seen, dead,              dead: null while the process lives, else when
#    claims: {<plan>: {repo, paths}}, acks: {<key>: <epoch>}, kept: [<task>],     acks also holds the
#                                                                               hourly notes, `note:...`
#    checkouts: {<toplevel>: {repo, expected, writer, paths}}}
#
# repo is the git common directory, so worktrees of one repository share it. expected is the branch at
# first touch, moved only when HEAD changed during this session's own call that held a switch; writer
# the epoch of the last writer call; paths what Edit/Write changed.
#
#   CC_TUNER_PEERS_DIR         record directory (default ~/.cache/cc-tuner/sessions)
#   CC_TUNER_PEERS_CLAUDE_PID  this session's Claude pid (default $CLAUDE_PID, else the `claude` above)
#
# Needs python3 and git >= 2.38. bash 3.2 compatible: macOS ships 3.2.57.
set -u

command -v python3 >/dev/null 2>&1 || { printf 'peers.sh: python3 is required\n' >&2; exit 2; }

read -r -d '' PROG <<'PY' || true
import fcntl, json, os, re, subprocess, sys, time, zlib
from contextlib import contextmanager

SELF = sys.argv[1]
cmd, args = (sys.argv[2] if len(sys.argv) > 2 else ""), sys.argv[3:]
DIR = os.environ.get("CC_TUNER_PEERS_DIR") or os.path.expanduser("~/.cache/cc-tuner/sessions")
NOW = int(time.time())
TOMBSTONE = 24 * 3600
ACK_TTL = 30 * 60
NOTE_TTL = 3600
WRITER_WINDOW = 2 * 3600
EDITS = ("Edit", "Write", "NotebookEdit")
READ_ONLY = ("ls", "cat", "grep", "rg", "find")
READ_ONLY_GIT = ("status", "log", "diff", "show")
SWITCH_GIT = ("switch", "checkout")
WRITING_ARGS = ("-delete", "-exec", "-execdir", "-ok", "-okdir")
GITENV = dict(os.environ, GIT_OPTIONAL_LOCKS="0")

def git(d, *a, env=GITENV):
    r = subprocess.run(["git", "-C", d] + list(a), capture_output=True, text=True, env=env)
    return r.stdout.strip() if r.returncode == 0 else None

_where = {}
def where(d):
    # (toplevel, common dir) of the checkout holding d, resolved from the target, not the session's cwd.
    if d not in _where:
        _where[d] = locate(d)
    return _where[d]

def gitdir(top):
    # The git directory of a checkout: its `.git` directory, or the one a worktree's `.git` file names.
    g = os.path.join(top, ".git")
    if os.path.isdir(g):
        return g
    try:
        with open(g) as f:
            line = f.readline()
    except OSError:
        return None
    return os.path.join(top, line[7:].strip()) if line.startswith("gitdir:") else None

def locate(d):
    # Read from the files, which costs no process: the first directory up holding `.git`, and the common
    # directory a worktree's git directory points to.
    while d and not os.path.isdir(d):
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent
    d = os.path.realpath(d)
    while True:
        gd = gitdir(d)
        if gd:
            try:
                with open(os.path.join(gd, "commondir")) as f:
                    gd = os.path.join(gd, f.read().strip())
            except OSError:
                pass
            return d, os.path.realpath(gd)
        if os.path.dirname(d) == d:
            return None
        d = os.path.dirname(d)

def product(top):
    try:
        with open(os.path.join(top, ".claude", "cc-tuner-resources.json")) as f:
            p = json.load(f).get("product")
    except (OSError, ValueError, AttributeError):
        return None
    return p if isinstance(p, str) and p else None

def read_only(step):
    # A known read-only form without a redirection, -delete/-exec, --output or --pre; any other form is a
    # writer call.
    w = step.get("words") or []
    if step.get("writes") or not w:
        return False
    name, args = os.path.basename(w[0]), w[1:]
    if any(a in WRITING_ARGS or a.startswith(("--output", "--pre", "-fprint", "-fls")) for a in args):
        return False
    return bool(args) and args[0] in READ_ONLY_GIT if name == "git" else name in READ_ONLY

def switches(step):
    w = step.get("words") or []
    return len(w) > 1 and os.path.basename(w[0]) == "git" and w[1] in SWITCH_GIT

def branch(co, fallback=""):
    gd = gitdir(co)
    try:
        with open(os.path.join(gd, "HEAD")) as f:
            head = f.read().strip()
    except (OSError, TypeError):
        return fallback
    return head[len("ref: refs/heads/"):] if head.startswith("ref: refs/heads/") else fallback

# --- processes ------------------------------------------------------------------------------------
_start = {}
STARTS_TTL = 60
def starts(pids):
    # pid -> start time of that process, None once it is gone. A pid that does not exist is told by a signal
    # 0. A start time read by any session in the last minute is taken from <dir>/.starts; the rest come
    # from `ps`: one `-p` for a single pid, else the whole table in one call, as a `-p` over several pids
    # reads the table too and costs more. A pid reused within the minute reads as the old process until then.
    try:
        with open(os.path.join(DIR, ".starts")) as f:
            known = json.load(f)
    except (OSError, ValueError):
        known = {}
    live = []
    for p in pids:
        if p in _start or p in live:
            continue
        try:
            os.kill(p, 0)
        except ProcessLookupError:
            _start[p] = None
            continue
        except PermissionError:
            pass
        e = known.get(str(p))
        if isinstance(e, list) and len(e) == 2 and NOW - e[1] < STARTS_TTL:
            _start[p] = e[0]
        else:
            live.append(p)
    if live:
        argv = ["ps", "-p", str(live[0])] if len(live) == 1 else ["ps", "-A"]
        out = subprocess.run(argv + ["-o", "pid=,lstart="], capture_output=True, text=True,
                             env=dict(os.environ, LC_ALL="C")).stdout
        table = {}
        for line in out.splitlines():
            f = line.split(None, 1)
            if len(f) == 2 and f[0].isdigit():
                table[int(f[0])] = f[1].strip()
        for p in live:
            _start[p] = table.get(p)
            if _start[p]:
                known[str(p)] = [_start[p], NOW]
        known = {k: e for k, e in known.items() if isinstance(e, list) and len(e) == 2 and NOW - e[1] < STARTS_TTL}
        tmp = os.path.join(DIR, ".starts.%d.tmp" % os.getpid())
        with open(tmp, "w") as f:
            json.dump(known, f)
        os.replace(tmp, os.path.join(DIR, ".starts"))
    return {p: _start[p] for p in pids}

_procs = {}
def procs():
    # pid -> (ppid, command name) of every process, read once: a walk up a tree needs it whole.
    if not _procs:
        out = subprocess.run(["ps", "-A", "-o", "pid=,ppid=,comm="], capture_output=True, text=True,
                             env=dict(os.environ, LC_ALL="C")).stdout
        for line in out.splitlines():
            f = line.split(None, 2)
            if len(f) == 3 and f[0].isdigit() and f[1].isdigit():
                _procs[int(f[0])] = (int(f[1]), os.path.basename(f[2]))
    return _procs

def claude_pid(recs):
    # This session's Claude process: the outermost `claude` from the given pid up, as a nested
    # `claude -p` belongs to its parent. A given pid that is not a `claude` (a stand-in) is itself; one
    # that is not running gives None. Without a given pid, the first `claude` above this script. A live
    # record of the given pid already answers, without a walk.
    given = os.environ.get("CC_TUNER_PEERS_CLAUDE_PID") or os.environ.get("CLAUDE_PID")
    start = int(given) if given and given.isdigit() else os.getpid()
    if given and any(r["pid"] == start and not r.get("dead") and r["start"] == starts([start])[start]
                     for r in recs.values()):
        return start
    if given and (start not in procs() or procs()[start][1] != "claude"):
        return start if start in procs() else None
    top, seen, p = None, set(), start
    while p in procs() and p not in seen:
        seen.add(p)
        if procs()[p][1] == "claude":
            top = p
        p = procs()[p][0]
    return top

# --- records --------------------------------------------------------------------------------------
os.makedirs(os.path.join(DIR, "merge"), exist_ok=True)

@contextmanager
def locked():
    fd = os.open(os.path.join(DIR, ".lock"), os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)

def save(name, r):
    tmp = os.path.join(DIR, ".%s.%d.tmp" % (name, os.getpid()))
    with open(tmp, "w") as f:
        json.dump(r, f)
    os.replace(tmp, os.path.join(DIR, name))

def load():
    recs, bad = {}, []
    for name in sorted(os.listdir(DIR)):
        if not name.endswith(".json") or name.startswith("."):
            continue
        try:
            with open(os.path.join(DIR, name)) as f:
                r = json.load(f)
            if not (isinstance(r, dict) and isinstance(r.get("pid"), int) and isinstance(r.get("start"), str)
                    and isinstance(r.get("checkouts"), dict)):
                raise ValueError(name)
            recs[name] = r
        except (OSError, ValueError):
            bad.append(name)
    return recs, bad

def expire(recs):
    # Under the lock: a tombstone dead for 24 h is removed, and so is an old merge result.
    for name, r in list(recs.items()):
        if r.get("dead") and NOW - r["dead"] > TOMBSTONE:
            os.unlink(os.path.join(DIR, name))
            del recs[name]
    cache = os.path.join(DIR, "merge")
    for n in os.listdir(cache):
        if NOW - os.path.getmtime(os.path.join(cache, n)) > TOMBSTONE:
            os.unlink(os.path.join(cache, n))

def verify(recs, names):
    # Under the lock: a record whose process is gone, or is another one now, becomes a tombstone.
    run = starts([recs[n]["pid"] for n in names if not recs[n].get("dead")])
    for n in names:
        r = recs[n]
        if not r.get("dead") and run[r["pid"]] != r["start"]:
            r["dead"] = NOW
            save(n, r)

def sweep(recs):
    expire(recs)
    verify(recs, list(recs))

def mine(recs, pid):
    for name, r in recs.items():
        if r["pid"] == pid and r["start"] == starts([pid])[pid] and not r.get("dead"):
            return name, r
    return None, None

def session(recs, pid, sid):
    # This session's record: the one of its process, else a tombstone with its session_id (resume
    # adopts it), else a new one.
    name, r = mine(recs, pid)
    if r is None and sid:
        verify(recs, [n for n, t in recs.items() if t.get("session_id") == sid])
        for n, t in recs.items():
            if t.get("session_id") == sid and t.get("dead"):
                name, r = n, t
                r["pid"], r["start"], r["dead"] = pid, starts([pid])[pid], None
                break
    if r is None:
        base = re.sub(r"[^A-Za-z0-9_.-]", "_", sid or "").lstrip(".") or "p%d" % pid
        name = base + ".json" if base + ".json" not in recs else "%s-%d.json" % (base, pid)
        r = recs[name] = {"session_id": sid, "pid": pid, "start": starts([pid])[pid], "seen": NOW, "dead": None,
                          "claims": {}, "acks": {}, "kept": [], "checkouts": {}}
    return name, r

def touch(r, top, common):
    co = r["checkouts"].get(top)
    if co is None:
        co = r["checkouts"][top] = {"repo": common, "expected": branch(top), "writer": None, "paths": []}
    r["seen"] = NOW
    return co

# --- peers ----------------------------------------------------------------------------------------
def related(top, common, here):
    # Same repository, or a repository of the same product.
    p = product(here[0])
    return common == here[1] or (p is not None and product(top) == p)

def peers_of(recs, name, here):
    # The live sessions next to `here`, with the checkouts that make them so; only candidates are checked.
    found = []
    for n, r in sorted(recs.items()):
        if n != name and not r.get("dead"):
            cos = [(top, co) for top, co in sorted(r["checkouts"].items()) if related(top, co["repo"], here)]
            if cos:
                found.append((n, r, cos))
    verify(recs, [n for n, _, _ in found])
    return [(r, cos) for _, r, cos in found if not r.get("dead")]

def overlaps(a, b):
    a, b = a.rstrip("/"), b.rstrip("/")
    return a == b or a.startswith(b + "/") or b.startswith(a + "/")

def conflicts(top, common, mine_sha, theirs_sha):
    # merge-tree of the two commits in a temporary object directory in front of the repository's own
    # store, so its result objects never reach the repository; cached per SHA pair.
    cache = os.path.join(DIR, "merge", "%s-%s" % (mine_sha, theirs_sha))
    try:
        with open(cache) as f:
            return json.load(f)
    except (OSError, ValueError):
        pass
    import shutil, tempfile
    tmp = tempfile.mkdtemp(dir=DIR, prefix=".objects.")
    env = dict(GITENV, GIT_OBJECT_DIRECTORY=tmp, GIT_ALTERNATE_OBJECT_DIRECTORIES=os.path.join(common, "objects"))
    r = subprocess.run(["git", "-C", top, "merge-tree", "--write-tree", "--name-only", mine_sha, theirs_sha],
                       capture_output=True, text=True, env=env)
    shutil.rmtree(tmp, ignore_errors=True)
    if r.returncode not in (0, 1):
        return None
    names = [n for n in r.stdout.split("\n\n")[0].split("\n")[1:] if n]
    with open(cache + ".tmp", "w") as f:
        json.dump(names, f)
    os.replace(cache + ".tmp", cache)
    return names

def report(here):
    with locked():
        recs, bad = load()
        sweep(recs)
        pid = claude_pid(recs)
    name, me = mine(recs, pid) if pid else (None, None)
    for n in bad:
        print("note: skipped malformed record %s" % n)
    found = peers_of(recs, name, here)
    if not found:
        print("no live peers")
        return
    mine_sha = git(here[0], "rev-parse", "HEAD")
    my_claims = [p for c in (me or {}).get("claims", {}).values() if c["repo"] == here[1] for p in c["paths"]]
    print("%d live peer%s" % (len(found), "" if len(found) == 1 else "s"))
    for r, cos in found:
        for top, co in cos:
            print("pid %d  %s  %s" % (r["pid"], branch(top, co["expected"]) or "(detached)", top))
            theirs = [p for c in r["claims"].values() if c["repo"] == co["repo"] for p in c["paths"]]
            if theirs:
                print("  claims: %s" % ", ".join(theirs))
            if co["paths"]:
                print("  edited: %s" % ", ".join(co["paths"]))
            if co["repo"] == here[1] and mine_sha:
                sha = git(top, "rev-parse", "HEAD")
                if sha and sha != mine_sha:
                    names = conflicts(here[0], here[1], mine_sha, sha)
                    if names is None:
                        print("  conflicts with HEAD: not computed (merge-tree failed)")
                    elif names:
                        print("  conflicts with HEAD: %s" % ", ".join(names))
            if co["repo"] == here[1]:
                both = [(a, b) for a in my_claims for b in theirs + co["paths"] if overlaps(a, b)]
                if both:
                    print("  overlap with your claims: %s" % ", ".join("%s ~ %s" % x for x in both))

# --- the guard's policy ---------------------------------------------------------------------------
class Halt(Exception):
    pass

SIGNAL = re.compile(r"-(\d+|[A-Z][A-Z0-9]{2,})$")
VALUED = ("-t", "--subject", "-b", "--body", "-F", "--body-file", "-R", "--repo", "-A", "--author-email",
          "--match-head-commit")

def flags(a):
    return [x for x in (a[:a.index("--")] if "--" in a else a) if x.startswith("-")]

def operands(a):
    return [x for x in a if not x.startswith("-")]

def has(a, long, short=""):
    # A long option, or a short one that may be bundled (`-am`).
    return any(x == long or (short and re.match(r"-[a-zA-Z]*[%s]" % short, x)) for x in flags(a))

def owns(paths, f):
    return f in paths or (f.endswith("/") and any(p.startswith(f) for p in paths))

def covers(spec, f):
    import fnmatch
    return spec == "." or f == spec or f.startswith(spec.rstrip("/") + "/") or fnmatch.fnmatch(f, spec) \
        or (f.endswith("/") and spec.startswith(f))

def status(top, staged):
    # (index, worktree, path) of every changed or untracked file; `staged` are paths an earlier step of the
    # same command adds.
    out = subprocess.run(["git", "-C", top, "status", "--porcelain=v1", "-z"], capture_output=True, text=True,
                         env=GITENV).stdout.split("\0")
    found, i = [], 0
    while i < len(out):
        e = out[i]
        i += 1
        if len(e) > 3:
            found.append((e[0], e[1], e[3:]))
            if e[0] in "RC":
                i += 1
    for p in staged:
        found = [e for e in found if e[2] != p] + [("A", " ", p)]
    return found

def pids_of(argv):
    try:
        out = subprocess.run(argv, capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    return [int(x) for x in out.split() if x.isdigit()]

def listing(files):
    return ", ".join(files[:3]) + (" and %d more" % (len(files) - 3) if len(files) > 3 else "")

def who(r, co):
    return "pid %d on %s" % (r["pid"], co["expected"] or "a detached HEAD")

class Guard:
    # One call's decisions: a stop raises Halt, a note is kept and the call goes on.
    def __init__(self, recs, name, r, pid, here):
        self.recs, self.name, self.r, self.pid, self.here = recs, name, r, pid, here
        self.notes, self.moved, self.staged = [], set(), {}

    def peers(self, at):
        return peers_of(self.recs, self.name, at)

    def note(self, text):
        self.notes.append("cc-tuner: " + text)

    def once(self, key, text):
        if NOW - self.r["acks"].get(key, 0) >= NOTE_TTL:
            self.r["acks"][key] = NOW
            self.note(text)

    def stop(self, action, target, text):
        k = "%08x" % zlib.crc32(("%s|%s" % (action, target)).encode())
        if NOW - self.r["acks"].get(k, 0) >= ACK_TTL:
            raise Halt("cc-tuner: %s To go on, run the same command prefixed CC_TUNER_ACK=%s. Re-running it is "
                       "your choice, not a question for the user." % (text, k))

    def step(self, w, at, d, prev):
        # git and gh act on the checkout of their directory; rm and kill reach past it, so outside a
        # repository they are read from the cwd's.
        name = os.path.basename(w[0])
        if name == "git" and at:
            self.git(w, at, d)
        elif name == "gh" and at:
            self.gh(w, at)
        elif name in ("kill", "pkill", "killall"):
            self.kill(name, w[1:], at or self.here, prev)
        elif name == "rm" and has(w[1:], "--recursive", "rR"):
            self.remove(at or self.here, d, " ".join(w)[:60], operands(w[1:]))

    def git(self, w, at, d):
        top, common = at
        if len(w) < 2:
            return
        sub, a, label = w[1], w[2:], " ".join(w)[:60]
        after = a[a.index("--") + 1:] if "--" in a else None
        if sub.startswith("-"):
            self.note("could not read `%s`; if a peer works in %s, check first." % (label, top))
        elif sub == "checkout" and ("--" in a or "." in a):
            self.lose(at, d, label, "checkout", "overwrite", "tracked", after or ["."])
        elif sub in ("switch", "checkout"):
            self.switch(at)
            self.moved.add(top)
        elif sub == "reset" and "--hard" in a:
            self.lose(at, d, label, "reset", "discard", "tracked")
        elif sub == "stash":
            op = a[0] if a and not a[0].startswith("-") else "push"
            if op in ("drop", "clear"):
                self.stash_drop(at, label)
            elif op in ("push", "save"):
                wide = has(a, "--include-untracked", "u") or has(a, "--all", "a")
                self.lose(at, d, label, "stash", "stash away", "all" if wide else "tracked", after)
        elif sub == "clean" and not has(a, "--dry-run", "n"):
            self.lose(at, d, label, "clean", "delete", "untracked", operands(a) or ["."])
        elif sub == "restore":
            self.lose(at, d, label, "restore", "overwrite", "tracked", operands(a))
        elif sub == "commit":
            self.drift(at, label, "commit")
            self.lose(at, d, label, "commit", "commit", "tracked" if has(a, "--all", "a") else "staged")
        elif sub == "add":
            args = operands(a)
            wide = [x for x in args if x == "." or os.path.isdir(os.path.join(d, x)) or re.search(r"[*?[]", x)]
            self.staged.setdefault(top, []).extend(os.path.relpath(os.path.realpath(os.path.join(d, x)), top)
                                                   for x in args if x not in wide)
            if has(a, "--all", "A"):
                self.lose(at, d, label, "add", "stage", "all")
            elif has(a, "--update", "u"):
                self.lose(at, d, label, "add", "stage", "tracked", args or None)
            elif wide:
                self.lose(at, d, label, "add", "stage", "all", wide)
        elif sub == "push":
            self.drift(at, label, "push")
            if has(a, "--delete", "d"):
                self.delete(at, operands(a)[1:], label)
            self.delete(at, [x[1:] for x in operands(a) if x.startswith(":")], label)
        elif sub == "branch" and has(a, "--delete", "dD"):
            self.delete(at, operands(a), label)
        elif sub == "worktree" and a[:1] == ["remove"]:
            self.remove(at, d, label, operands(a[1:]))

    def gh(self, w, at):
        if len(w) < 3 or w[1] != "pr" or w[2] not in ("create", "merge"):
            return
        label = " ".join(w)[:60]
        self.drift(at, label, "gh pr " + w[2])
        if w[2] == "merge" and has(w[3:], "--delete-branch", "d"):
            sel, skip = [], False
            for x in w[3:]:
                if skip:
                    skip = False
                elif x in VALUED:
                    skip = True
                elif not x.startswith("-"):
                    sel.append(x)
            if not sel:
                self.delete(at, [branch(at[0])], label)
            elif re.match(r"\d+$|https?://", sel[0]):
                self.note("`%s` deletes a branch it does not name; if a peer works on it, check first." % label)
            else:
                self.delete(at, [sel[0]], label)

    def switch(self, at):
        top = at[0]
        here = [(r, co) for r, cos in self.peers(at) for t, co in cos if t == top]
        busy = [(r, co) for r, co in here if co["writer"] and NOW - co["writer"] < WRITER_WINDOW]
        if busy:
            self.stop("switch", top, "%s works in %s; switching branches there changes its files." % (who(*busy[0]), top))
        elif here:
            self.note("%s has its cwd in %s; switching branches there changes its files." % (who(*here[0]), top))

    def drift(self, at, label, action):
        top = at[0]
        head, want = branch(top), self.r["checkouts"][top]["expected"]
        if top not in self.moved and head != want:
            self.stop(action + " on " + top, top, "`%s` would run on %s in %s, not on %s, where this session "
                      "started; someone else switched it." % (label, head or "a detached HEAD", top, want or "a detached HEAD"))

    def foreign(self, top, kinds, specs, d):
        # The changed files of a checkout this session did not edit, within the paths a command reaches.
        mine = self.r["checkouts"].get(top, {}).get("paths", [])
        reach = None if specs is None else [os.path.relpath(os.path.realpath(os.path.join(d, x)), top) for x in specs]
        return [f for x, y, f in status(top, self.staged.get(top, []))
                if not (kinds == "tracked" and x == "?" or kinds == "untracked" and x != "?" or kinds == "staged" and x in " ?")
                and not owns(mine, f) and (reach is None or any(covers(x, f) for x in reach))]

    def owner(self, top, files):
        names = [n for n, r in sorted(self.recs.items()) if n != self.name and top in r["checkouts"]
                 and any(owns(r["checkouts"][top]["paths"], f) for f in files)]
        verify(self.recs, names)
        found = [("pid %d, exited" % self.recs[n]["pid"]) if self.recs[n].get("dead") else who(self.recs[n], self.recs[n]["checkouts"][top])
                 for n in names]
        return ", ".join(found) or "unknown owner"

    def lose(self, at, d, label, action, verb, kinds, specs=None):
        top = at[0]
        files = self.foreign(top, kinds, specs, d)
        if files:
            self.stop(action, top, "`%s` would %s %s in %s (%s)." % (label, verb, listing(files), top, self.owner(top, files)))

    def stash_drop(self, at, label):
        for r, cos in self.peers(at):
            for top, co in cos:
                if co["repo"] == at[1] and co["writer"]:
                    self.stop("stash drop", at[1], "`%s` would drop a stash that %s shares, working in %s." % (label, who(r, co), top))

    def delete(self, at, names, label):
        for name in names:
            for r, cos in self.peers(at):
                for top, co in cos:
                    if co["repo"] == at[1] and co["expected"] == name:
                        self.stop("delete branch", "%s:%s" % (at[1], name), "`%s` would delete %s, the branch %s works on in %s."
                                  % (label, name, who(r, co), top))

    def remove(self, at, d, label, paths):
        for p in paths:
            path = os.path.realpath(os.path.join(d, p))
            there = where(path)
            for r, cos in self.peers(there or at):
                for top, co in cos:
                    if top == path or top.startswith(path + "/"):
                        self.stop("remove", path, "`%s` would remove %s, where %s works." % (label, path, who(r, co)))
            if there and there[0] == path:
                files = self.foreign(path, "all", None, path)
                if files:
                    self.stop("remove", path, "`%s` would delete %s in %s (%s)." % (label, listing(files), path, self.owner(path, files)))

    def kill(self, name, a, at, prev):
        peers = {r["pid"]: (r, co) for r, cos in self.peers(at) for _, co in cos}
        if not peers:
            return
        if name == "kill":
            pids = [int(x) for x in a if x.isdigit()] or (pids_of(prev) if prev and os.path.basename(prev[0]) in ("lsof", "pgrep") else None)
        elif name == "pkill":
            pids = pids_of(["pgrep"] + [x for x in a if not SIGNAL.match(x)])
        else:
            pids = [q for x in operands(a) for q in pids_of(["pgrep", "-x", x]) or []]
        if pids is None:
            return self.note("could not tell which process `%s` stops; if a peer's, check first." % " ".join([name] + a)[:60])
        table = procs()
        for pid in pids:
            p, hops = pid, 0
            while p in table and p > 1 and p != self.pid and p not in peers and hops < 64:
                p, hops = table[p][0], hops + 1
            if p in peers:
                self.stop("kill", str(pid), "`%s` would stop process %d, which belongs to %s." % (" ".join([name] + a)[:60], pid, who(*peers[p])))

    def edit(self, at, rel):
        top, common = at
        for r, cos in self.peers(at):
            for t, co in cos:
                if t == top and co["writer"]:
                    self.once("note:%d:%s" % (r["pid"], top), "%s also writes in %s; its edits may land next to yours." % (who(r, co), top))
            for plan, c in sorted(r["claims"].items()):
                for p in c["paths"]:
                    if c["repo"] == common and overlaps(rel, p):
                        self.once("note:%d:%s" % (r["pid"], p), "%s claims %s (%s); this edit may conflict with it." % (who(r, cos[0][1]), p, plan))

def judge(ev, recs, name, r, pid, here, plan, target):
    g = Guard(recs, name, r, pid, here)
    try:
        if ev.get("tool") == "Bash":
            prev = []
            for st, _, _, at, d in plan:
                w = st.get("words") or []
                if w:
                    g.step(w, at, d, prev)
                prev = w
        elif target:
            g.edit(here, os.path.relpath(os.path.realpath(target), here[0]))
    except Halt as h:
        return "stop", str(h)
    return ("note", " ".join(g.notes)) if g.notes else ("allow", "")

# --- commands -------------------------------------------------------------------------------------
def start_line(recs, name, r, here):
    parts = []
    peers = [(rec["pid"], top, co) for rec, cos in peers_of(recs, name, here) for top, co in cos]
    if peers:
        parts.append("live peers: " + ", ".join("%s (%s, pid %d)" % (branch(top, co["expected"]) or "detached",
                                                                      os.path.basename(top), pid) for pid, top, co in peers))
    if r["kept"]:
        parts.append("kept at /clear: " + ", ".join(r["kept"]))
    return "" if not parts else 'cc-tuner: %s. Run: bash "%s" report' % ("; ".join(parts), SELF)

def check():
    try:
        ev = json.load(sys.stdin)
        assert isinstance(ev, dict)
    except (ValueError, AssertionError):
        ev = {}
    phase, sid, tool = ev.get("phase"), ev.get("session_id") or None, ev.get("tool")
    cwd = ev.get("cwd") or os.getcwd()
    target = ev.get("path")
    if target:
        target = os.path.join(cwd, target)
    here = where(os.path.dirname(target) if target else cwd)
    plan = []
    if phase == "before" and tool == "Bash":
        # Each step is read in its own directory; a known read-only step elsewhere touches nothing.
        for st in ev["steps"] if "steps" in ev else [{}]:
            d = os.path.normpath(os.path.join(cwd, st.get("dir") or ""))
            writes, switch = not read_only(st), switches(st)
            plan.append((st, writes, switch, where(d) if writes or switch else None, d))
    verdict, reason, line, seen = "allow", "", "", {}
    if here and (sid or phase != "start"):
        with locked():
            recs, _ = load()
            expire(recs)
            pid = claude_pid(recs)
            if pid:
                if phase == "start" and ev.get("source") == "clear":
                    n, r = mine(recs, pid)
                    if r is not None:
                        r["session_id"], r["acks"], r["claims"] = sid, {}, {}
                name, r = session(recs, pid, sid)
                co = touch(r, here[0], here[1])
                for _, _, _, at, _ in plan:
                    if at:
                        touch(r, at[0], at[1])
                if ev.get("ack"):
                    r["acks"][str(ev["ack"])] = NOW
                if phase == "before":
                    verdict, reason = judge(ev, recs, name, r, pid, here, plan, target)
                if verdict != "stop":
                    # A stopped call made no writer; a switch step takes the branch HEAD is on now.
                    for _, writes, switch, at, _ in plan:
                        if at and writes:
                            r["checkouts"][at[0]]["writer"] = NOW
                        if at and switch:
                            seen[at[0]] = branch(at[0])
                    if phase == "after" and tool in EDITS and ev.get("ok", True) and target:
                        rel = os.path.relpath(os.path.realpath(target), here[0])
                        if rel not in co["paths"]:
                            co["paths"].append(rel)
                        co["writer"] = NOW
                    if phase == "after" and tool == "Bash":
                        for top, old in (ev.get("seen") or {}).items():
                            now = branch(top)
                            if top in r["checkouts"] and now and now != old:
                                r["checkouts"][top]["expected"] = now
                r["acks"] = {k: t for k, t in r["acks"].items() if NOW - t < NOTE_TTL}
                save(name, r)
                if phase == "start":
                    line = start_line(recs, name, r, here)
    if phase == "start":
        print(line)
    else:
        out = {"decision": verdict}
        if reason:
            out["reason"] = reason
        if seen:
            out["seen"] = seen
        print(json.dumps(out, separators=(",", ":")))

def claim(plan):
    here = where(os.getcwd())
    lint = os.path.join(os.path.dirname(SELF), "plan-lint.sh")
    out = {}
    for mode in ("slices", "owned"):
        r = subprocess.run(["bash", lint, mode, plan], capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit(r.stderr.strip() or "peers.sh: plan-lint failed")
        out[mode] = [l.split("\t") for l in r.stdout.split("\n") if l]
    open_slices = {f[1] for f in out["slices"] if f[0] == "SLICE" and f[2] == "open"}
    paths = []
    for f in out["owned"]:
        if f[1] in open_slices:
            paths += [p for p in f[2].split(",") if p and p not in paths]
    key = os.path.relpath(os.path.realpath(plan), here[0])
    with locked():
        recs, _ = load()
        sweep(recs)
        pid = claude_pid(recs)
        if not pid:
            sys.exit("peers.sh: no Claude process found for this session")
        name, r = session(recs, pid, None)
        touch(r, here[0], here[1])
        if paths:
            r["claims"][key] = {"repo": here[1], "paths": paths}
        else:
            r["claims"].pop(key, None)
        save(name, r)
    report(here)

def main():
    if cmd == "check":
        return check()
    if cmd in ("report", "claim"):
        here = where(os.getcwd())
        if not here:
            sys.exit("peers.sh: not in a git repository")
        if cmd == "claim":
            if len(args) != 1:
                sys.exit("usage: peers.sh claim <plan>")
            return claim(args[0])
        return report(here)
    sys.exit("usage: peers.sh check | report | claim <plan>")

main()
PY
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
exec python3 -I -S -c "$PROG" "$SELF" "$@"
