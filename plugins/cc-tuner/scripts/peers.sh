#!/usr/bin/env bash
# Sessions of one product see each other: who is live next to this session, on which branch, claiming
# and editing which paths, and whose branch would conflict with this one.
#
#   peers.sh check             read one JSON event on stdin, update this session's record, answer
#                              {"decision":"allow"}; the guard's entry point
#   peers.sh report            the live peers of this repository and of its product
#   peers.sh claim <plan>      publish the open Owned paths of a plan, then report their overlap
#
# `check` events, one per phase, carry session_id, phase (before | after | start), tool and cwd:
#   Bash before   steps: [{words, dir, op, writes}] one per simple command, the unwrapped one that runs:
#                 dir its directory (relative to cwd, or absolute), op the operator joining it to the
#                 step before (&& || ; |, empty for the first), writes a redirection to a file. A step
#                 that is not a known read-only form (git status/log/diff/show, ls, cat, grep, rg, find
#                 without -delete, -exec, --output or --pre) makes the session a writer in its checkout.
#                 The answer carries seen {checkout: branch} for each checkout holding a switch step.
#   Bash after    seen, as answered: the expectation moves to a checkout's branch only if HEAD changed.
#   Edit | Write | NotebookEdit after   path, sent after a call that succeeded.
#   start         the SessionStart hook: source (startup | clear | resume); the answer is the line
#                 session-start.sh prints, empty without peers.
# The answer is {"decision":"allow"} plus seen; a stop or a note for a peer's sake comes with the guard's
# policy. Whatever fails here, the caller lets the tool call go on.
#
# One JSON record per Claude session in the record directory, written by rename under a flock on
# <dir>/.lock. A session is its Claude process: pid plus start time, and a nested `claude -p` counts
# as the outermost `claude` above it. A record whose process is gone becomes a tombstone for 24 h; a
# resumed session with the same session_id adopts it. `/clear` drops acks and claims. A record that
# does not parse is skipped, and `report` says so.
#
#   {session_id, pid, start, seen, dead,              dead: null while the process lives, else when
#    claims: {<plan>: {repo, paths}}, acks: {<key>: <epoch>}, kept: [<task>],
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
import fcntl, json, os, re, shutil, subprocess, sys, tempfile, time
from contextlib import contextmanager

SELF = sys.argv[1]
cmd, args = (sys.argv[2] if len(sys.argv) > 2 else ""), sys.argv[3:]
DIR = os.environ.get("CC_TUNER_PEERS_DIR") or os.path.expanduser("~/.cache/cc-tuner/sessions")
NOW = int(time.time())
TOMBSTONE = 24 * 3600
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

def locate(d):
    while d and not os.path.isdir(d):
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent
    out = git(d, "rev-parse", "--show-toplevel", "--path-format=absolute", "--git-common-dir")
    if not out:
        return None
    top, common = [os.path.realpath(x) for x in out.split("\n")[:2]]
    return top, common

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
    return git(co, "symbolic-ref", "-q", "--short", "HEAD") or fallback

# --- processes ------------------------------------------------------------------------------------
_procs = {}
def procs():
    # pid -> (ppid, lstart, command name), read once.
    if not _procs:
        out = subprocess.run(["ps", "-A", "-o", "pid=,ppid=,lstart=,comm="], capture_output=True, text=True,
                             env=dict(os.environ, LC_ALL="C")).stdout
        for line in out.splitlines():
            f = line.split()
            if len(f) >= 8 and f[0].isdigit() and f[1].isdigit():
                _procs[int(f[0])] = (int(f[1]), " ".join(f[2:7]), os.path.basename(" ".join(f[7:])))
    return _procs

def alive(r):
    p = procs().get(r["pid"])
    return p is not None and p[1] == r["start"]

def claude_pid():
    # This session's Claude process: the outermost `claude` from the given pid up, as a nested
    # `claude -p` belongs to its parent. A given pid that is not a `claude` (a stand-in) is itself; one
    # that is not running gives None. Without a given pid, the first `claude` above this script.
    given = os.environ.get("CC_TUNER_PEERS_CLAUDE_PID") or os.environ.get("CLAUDE_PID")
    start = int(given) if given and given.isdigit() else os.getpid()
    if given and (start not in procs() or procs()[start][2] != "claude"):
        return start if start in procs() else None
    top, seen, p = None, set(), start
    while p in procs() and p not in seen:
        seen.add(p)
        if procs()[p][2] == "claude":
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

def sweep(recs):
    # Under the lock: a record whose process is gone becomes a tombstone, one dead for 24 h is removed.
    for name, r in list(recs.items()):
        if r.get("dead"):
            if NOW - r["dead"] > TOMBSTONE:
                os.unlink(os.path.join(DIR, name))
                del recs[name]
        elif not alive(r):
            r["dead"] = NOW
            save(name, r)
    cache = os.path.join(DIR, "merge")
    for n in os.listdir(cache):
        if NOW - os.path.getmtime(os.path.join(cache, n)) > TOMBSTONE:
            os.unlink(os.path.join(cache, n))

def mine(recs, pid):
    for name, r in recs.items():
        if r["pid"] == pid and r["start"] == procs()[pid][1] and not r.get("dead"):
            return name, r
    return None, None

def session(recs, pid, sid):
    # This session's record: the one of its process, else a tombstone with its session_id (resume
    # adopts it), else a new one.
    name, r = mine(recs, pid)
    if r is None and sid:
        for n, t in recs.items():
            if t.get("session_id") == sid and t.get("dead"):
                name, r = n, t
                r["pid"], r["start"], r["dead"] = pid, procs()[pid][1], None
                break
    if r is None:
        base = re.sub(r"[^A-Za-z0-9_.-]", "_", sid or "").lstrip(".") or "p%d" % pid
        name = base + ".json" if base + ".json" not in recs else "%s-%d.json" % (base, pid)
        r = recs[name] = {"session_id": sid, "pid": pid, "start": procs()[pid][1], "seen": NOW, "dead": None,
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
    out = []
    for n, r in sorted(recs.items()):
        if n == name or r.get("dead"):
            continue
        cos = [(top, co) for top, co in sorted(r["checkouts"].items()) if related(top, co["repo"], here)]
        if cos:
            out.append((r, cos))
    return out

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
    pid = claude_pid()
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
    pid = claude_pid()
    line, seen, touched = "", {}, []
    if phase == "before" and tool == "Bash":
        # Each step is read in its own directory. A writer step marks its checkout, a switch step takes the
        # branch HEAD is on now; a known read-only step elsewhere touches nothing.
        for st in ev["steps"] if "steps" in ev else [{}]:
            writes, switch = not read_only(st), switches(st)
            at = where(os.path.normpath(os.path.join(cwd, st.get("dir") or ""))) if writes or switch else None
            if at:
                touched.append((at, writes))
                if switch:
                    seen[at[0]] = branch(at[0])
    if pid and here and (sid or phase != "start"):
        with locked():
            recs, _ = load()
            sweep(recs)
            if phase == "start" and ev.get("source") == "clear":
                n, r = mine(recs, pid)
                if r is not None:
                    r["session_id"], r["acks"], r["claims"] = sid, {}, {}
            name, r = session(recs, pid, sid)
            co = touch(r, here[0], here[1])
            for (top, common), writes in touched:
                c = touch(r, top, common)
                if writes:
                    c["writer"] = NOW
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
            save(name, r)
        if phase == "start":
            line = start_line(recs, name, r, here)
    else:
        seen = {}
    if phase == "start":
        print(line)
    else:
        print(json.dumps(dict({"decision": "allow"}, **({"seen": seen} if seen else {})), separators=(",", ":")))

def claim(plan):
    here = where(os.getcwd())
    pid = claude_pid()
    if not pid:
        sys.exit("peers.sh: no Claude process found for this session")
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
exec python3 -c "$PROG" "$SELF" "$@"
