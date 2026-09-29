#!/usr/bin/env bash
# Run a heavy check (full suite, e2e, build, container start) in one of a few machine-wide slots.
#
#   heavy.sh [--slots N] [--label <text>] -- <command> [args...]
#   heavy.sh status
#
# Slots are shared by every session and subagent on this machine, so five agents asking for e2e at
# once run them one after another instead of together. The command runs unchanged: its output and
# exit code are its own; the only difference is when it starts.
#
# A slot is a kernel lock (flock) on slot-<n>.lock held for as long as the work lives. The command
# runs in its own process group under a small supervisor, which returns the command's exit code as
# soon as the command exits. If processes of that group are still running then — whether the command
# exited normally or was killed — a detached keeper holds the slot until the last of them exits.
# Interrupting the supervisor (TERM, INT, HUP) stops the whole group first. The lock descriptor is
# also inherited by the work, so a process that kept it holds the slot on its own.
#
# The slot can be released while work still runs in two cases only: a process that left the group
# (setsid, a daemon) and closed the inherited descriptor; or the supervisor killed with SIGKILL
# before a keeper exists, leaving group members that closed the descriptor. Nothing is reclaimed by
# pid: the kernel releases the lock when its last holder exits. A heavy.sh started inside a slot's
# work runs inside that slot at once.
#
# What this bounds: concurrent heavy commands started through it. Not memory itself, not commands
# that bypass it (a repository hook calling the test runner directly), and not a container that
# keeps running after its start command returned.
#
#   CC_TUNER_HEAVY_SLOTS  concurrent heavy checks on this machine (default 1)
#   CC_TUNER_HEAVY_DIR    slot directory (default ~/.cache/cc-tuner/heavy)
#   CC_TUNER_HEAVY_POLL   seconds between attempts while waiting (default 2)
#
# Needs python3 for the lock; without it the command runs unslotted, and says so.
# bash 3.2 compatible: macOS ships 3.2.57.
set -u

DIR="${CC_TUNER_HEAVY_DIR:-$HOME/.cache/cc-tuner/heavy}"
SLOTS="${CC_TUNER_HEAVY_SLOTS:-1}"
POLL="${CC_TUNER_HEAVY_POLL:-2}"
LABEL=""

die() { printf 'heavy.sh: %s\n' "$1" >&2; exit 2; }

MODE=run
if [ "${1:-}" = status ]; then
  MODE=status
  shift
else
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --slots) [ -n "${2:-}" ] || die "--slots needs a number"; SLOTS="$2"; shift 2 ;;
      --label) [ -n "${2:-}" ] || die "--label needs text"; LABEL="$2"; shift 2 ;;
      --) shift; break ;;
      *) die "usage: heavy.sh [--slots N] [--label <text>] -- <command> [args...] | heavy.sh status" ;;
    esac
  done
  [ "$#" -gt 0 ] || die "no command given after --"
fi
case "$SLOTS" in ''|*[!0-9]*|0) die "slots must be a positive integer, got '$SLOTS'" ;; esac
[ -n "$LABEL" ] || LABEL="$*"

# Already inside a slot's work: the parent holds the slot this command belongs to.
if [ "$MODE" = run ] && [ -n "${CC_TUNER_HEAVY_HELD:-}" ]; then
  exec "$@"
fi

if ! command -v python3 >/dev/null 2>&1; then
  [ "$MODE" = run ] || die "python3 is required to read slot state"
  printf 'heavy.sh: python3 not found — running without a slot: %s\n' "$LABEL" >&2
  exec "$@"
fi
mkdir -p "$DIR" || die "cannot create $DIR"

# The program is passed with -c, not on stdin, so the command keeps the caller's stdin after exec.
read -r -d '' PROG <<'PY' || true
import fcntl, os, signal, subprocess, sys, time

mode, d, slots, poll, label = sys.argv[1], sys.argv[2], int(sys.argv[3]), float(sys.argv[4]), sys.argv[5]
cmd = sys.argv[6:]

def lock_path(i): return os.path.join(d, "slot-%d.lock" % i)
def owner_path(i): return os.path.join(d, "slot-%d.owner" % i)

def try_slot(i):
    fd = os.open(lock_path(i), os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return fd
    except OSError:
        os.close(fd)
        return None

def group_members(pgid):
    # Listed with ps, not probed with killpg: macOS answers ESRCH for a group whose leader has exited
    # even while other members still run.
    try:
        out = subprocess.run(["ps", "-A", "-o", "pid=,pgid="], capture_output=True, text=True).stdout
    except OSError:
        return []
    return [int(f[0]) for f in (line.split() for line in out.split("\n")) if len(f) == 2 and f[1] == str(pgid)]

def holders():
    out = []
    for i in range(1, slots + 1):
        fd = try_slot(i)
        if fd is not None:
            os.close(fd)  # free: taking and dropping it changes nothing
            continue
        try:
            with open(owner_path(i)) as f: lines = f.read().split("\n")
        except OSError:
            lines = ["unknown holder"]
        who = lines[0].strip() or "unknown holder"
        group = [l[6:] for l in lines if l.startswith("group=")]
        if group:
            live = group_members(group[-1])
            who += "; running now: %s" % (" ".join(map(str, live)) if live else "none")
        out.append("  slot-%d: %s" % (i, who))
    return out

if mode == "status":
    h = holders()
    print("\n".join(h) if h else "heavy.sh: all slots free")
    sys.exit(0)

said = False
while True:
    for i in range(1, slots + 1):
        fd = try_slot(i)
        if fd is None:
            continue
        with open(owner_path(i), "w") as f:
            f.write("%s supervisor=%d since=%s cwd=%s\n" % (label, os.getpid(), time.strftime("%H:%M:%S"), os.getcwd()))
        env = dict(os.environ, CC_TUNER_HEAVY_HELD="slot-%d" % i)
        try:
            child = subprocess.Popen(cmd, env=env, pass_fds=(fd,), start_new_session=True)
        except OSError as e:
            sys.stderr.write("heavy.sh: cannot run %s: %s\n" % (cmd[0], e))
            sys.exit(127)
        pgid = child.pid
        with open(owner_path(i), "a") as f:
            f.write("group=%d\n" % pgid)

        def members():
            return group_members(pgid)

        def stop(sig, _frame):
            for s, grace in ((signal.SIGTERM, 5.0), (signal.SIGKILL, 0.0)):
                live = members()
                if not live:
                    break
                for pid in live:
                    try:
                        os.kill(pid, s)
                    except OSError:
                        pass
                end = time.time() + grace
                while members() and time.time() < end:
                    time.sleep(0.1)
            sys.exit(128 + sig)

        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(sig, stop)
        rc = child.wait()
        code = rc if rc >= 0 else 128 - rc
        left = members()
        if left and os.fork() == 0:
            # The command is done but its group is not: a keeper holds the slot until the last
            # process in the group exits, while the caller gets the command's exit code now.
            os.setsid()
            # Let go of the caller's stdio, so a caller reading this command's output is not held
            # open until the leftovers finish.
            null = os.open(os.devnull, os.O_RDWR)
            for std in (0, 1, 2):
                os.dup2(null, std)
            for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
                signal.signal(sig, signal.SIG_DFL)
            with open(owner_path(i), "w") as f:
                f.write("%s (exited %d; keeper=%d holds the slot for leftover work) since=%s cwd=%s\ngroup=%d\n"
                        % (label, code, os.getpid(), time.strftime("%H:%M:%S"), os.getcwd(), pgid))
            while members():
                time.sleep(0.5)
            os._exit(0)
        sys.exit(code)
    if not said:
        sys.stderr.write("heavy.sh: waiting for one of %d heavy-check slot(s); held by:\n%s\n" % (slots, "\n".join(holders())))
        said = True
    time.sleep(poll)
PY
exec python3 -c "$PROG" "$MODE" "$DIR" "$SLOTS" "$POLL" "$LABEL" "$@"
