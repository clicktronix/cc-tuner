#!/usr/bin/env bash
# Run a heavy check (full suite, e2e, build, container start) in one of a few machine-wide slots.
#
#   heavy.sh [--weight w] [--slots N] [--label <text>] -- <command> [args...]
#   heavy.sh status
#
# Capacity is shared by every session and subagent on this machine, so five agents asking for e2e at
# once do not run them together. The command runs unchanged: its output and exit code are its own;
# the only difference is when it starts.
#
# Capacity is a number of slots: CC_TUNER_HEAVY_SLOTS (or --slots), else one per 8 GB of RAM, at
# least 1 (16 GB -> 2). A check holds --weight slots (default 1; an e2e run asks for 2). A weight
# above capacity is clamped, with a note. Callers start in the order they asked: each waiter takes
# a ticket in queue/ and only the oldest live ticket takes slots, keeping the ones it took while it
# waits for the rest, so a weight-2 check is not starved by weight-1 arrivals. A dead waiter's
# ticket is swept; a waiter whose caller died leaves the queue.
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
# Memory pressure: once it holds its slots, the head of the queue waits while the OS reports pressure
# (macOS kern.memorystatus_vm_pressure_level warn/critical; Linux /proc/pressure/memory some avg10 >=
# 10). The wait is bounded by CC_TUNER_HEAVY_MEM_WAIT; after it the command starts anyway, with the
# line "heavy.sh: started under memory pressure after <n>s", and a deficit mark in the slot directory
# lets checks in the next 600 s start without waiting. A signal that cannot
# be read starts the command and says "pressure not measured".
#
# What this bounds: concurrent heavy commands started through it. Not memory itself, not commands
# that bypass it (a repository hook calling the test runner directly), and not a container that
# keeps running after its start command returned.
#
#   CC_TUNER_HEAVY_SLOTS     capacity in slots (default: RAM / 8 GB, at least 1)
#   CC_TUNER_HEAVY_DIR       slot directory (default ~/.cache/cc-tuner/heavy)
#   CC_TUNER_HEAVY_POLL      seconds between attempts while waiting (default 2)
#   CC_TUNER_HEAVY_MEM_WAIT  seconds the head waits for pressure to clear (default 600)
#   CC_TUNER_HEAVY_TOTAL_MB  RAM in MB instead of the machine's (macOS hw.memsize; Linux MemTotal
#                            rounded up to a whole GiB); CC_TUNER_HEAVY_PROC replaces /proc;
#                            CC_TUNER_HEAVY_PRESSURE (normal|warn|critical|unknown) replaces the
#                            pressure reading; CC_TUNER_HEAVY_DEFICIT sets how long the deficit
#                            mark lasts (default 600 s)
#
# Needs python3 for the lock; without it the command runs unslotted, and says so.
# bash 3.2 compatible: macOS ships 3.2.57.
set -u

DIR="${CC_TUNER_HEAVY_DIR:-$HOME/.cache/cc-tuner/heavy}"
SLOTS="${CC_TUNER_HEAVY_SLOTS:-}"
WEIGHT=1
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
      --weight) [ -n "${2:-}" ] || die "--weight needs a number"; WEIGHT="$2"; shift 2 ;;
      --label) [ -n "${2:-}" ] || die "--label needs text"; LABEL="$2"; shift 2 ;;
      --) shift; break ;;
      *) die "usage: heavy.sh [--weight w] [--slots N] [--label <text>] -- <command> [args...] | heavy.sh status" ;;
    esac
  done
  [ "$#" -gt 0 ] || die "no command given after --"
fi
case "$SLOTS" in *[!0-9]*|0) die "slots must be a positive integer, got '$SLOTS'" ;; esac
case "$WEIGHT" in ''|*[!0-9]*|0) die "weight must be a positive integer, got '$WEIGHT'" ;; esac
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

# RAM in MB, empty when it cannot be read.
total_mb() {
  local raw
  if [ -n "${CC_TUNER_HEAVY_TOTAL_MB:-}" ]; then
    printf '%s' "$CC_TUNER_HEAVY_TOTAL_MB"; return
  fi
  case "$(uname -s 2>/dev/null)" in
    Darwin)
      raw="$(sysctl -n hw.memsize 2>/dev/null)"
      case "$raw" in ''|*[!0-9]*) return ;; esac
      printf '%s' "$((raw / 1048576))" ;;
    Linux)
      raw="$(awk '/^MemTotal:/ { print $2; exit }' "${CC_TUNER_HEAVY_PROC:-/proc}/meminfo" 2>/dev/null)"
      case "$raw" in ''|*[!0-9]*) return ;; esac
      printf '%s' "$(((raw + 1048575) / 1048576 * 1024))" ;;
  esac
}

case "${CC_TUNER_HEAVY_DEFICIT:-600}" in ''|*[!0-9.]*|*.*.*) die "CC_TUNER_HEAVY_DEFICIT must be a number of seconds" ;; esac
case "${CC_TUNER_HEAVY_MEM_WAIT:-600}" in ''|*[!0-9.]*|*.*.*) die "CC_TUNER_HEAVY_MEM_WAIT must be a number of seconds" ;; esac
case "${CC_TUNER_HEAVY_PRESSURE:-normal}" in normal|warn|critical|unknown) ;; *) die "CC_TUNER_HEAVY_PRESSURE must be normal, warn, critical or unknown" ;; esac
case "${CC_TUNER_HEAVY_TOTAL_MB:-}" in *[!0-9]*) die "CC_TUNER_HEAVY_TOTAL_MB must be a number of MB" ;; esac
if [ -z "$SLOTS" ]; then
  MB="$(total_mb)"
  SLOTS=$(( ${MB:-0} / 8192 ))
  [ "$SLOTS" -ge 1 ] || SLOTS=1
fi
if [ "$WEIGHT" -gt "$SLOTS" ]; then
  printf 'heavy.sh: weight %s clamped to capacity %s\n' "$WEIGHT" "$SLOTS" >&2
  WEIGHT="$SLOTS"
fi

# The program is passed with -c, not on stdin, so the command keeps the caller's stdin after exec.
read -r -d '' PROG <<'PY' || true
import fcntl, os, signal, subprocess, sys, time
from contextlib import contextmanager

mode, d, slots, weight, poll, label = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), float(sys.argv[5]), sys.argv[6]
cmd = sys.argv[7:]
qdir = os.path.join(d, "queue")
mem_wait = float(os.environ.get("CC_TUNER_HEAVY_MEM_WAIT") or 600)
deficit_ttl = float(os.environ.get("CC_TUNER_HEAVY_DEFICIT") or 600)
deficit_path = os.path.join(d, "memory-deficit")

def lock_path(i): return os.path.join(d, "slot-%d.lock" % i)
def owner_path(i): return os.path.join(d, "slot-%d.owner" % i)

@contextmanager
def owner_guard(i):
    # Both tuners share this short lock: a reader must not see the workload lock acquired before
    # its owner is published. It is released before starting work and never replaces the slot lock.
    with open(owner_path(i) + ".lock", "a") as note:
        fcntl.flock(note, fcntl.LOCK_EX)
        yield

def write_owner(i, text):
    # Replace metadata whole so readers, including older helpers, never see a truncated note.
    # The workload lock lives on slot-<n>.lock and is unaffected by the replacement.
    tmp = "%s.%d.tmp" % (owner_path(i), os.getpid())
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, owner_path(i))

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

# Queue: one file per waiter in queue/, named <arrival number>-<pid>. The waiter holds a lock on its
# ticket for as long as it lives, so a ticket whose lock is free belongs to a dead waiter.
def ticket_names():
    try:
        return sorted(n for n in os.listdir(qdir) if not n.startswith("."))
    except OSError:
        return []

def ticket_alive(path):
    # True: its waiter lives. False: it died. None: already gone.
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError:
        return None
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return False
    except OSError:
        return True
    finally:
        os.close(fd)

def enqueue():
    # Created already locked (temp name, lock, rename) so no reader sees a live-looking ticket with
    # nobody behind it. Numbered under a short lock so arrival order is total.
    os.makedirs(qdir, exist_ok=True)
    gate = os.open(os.path.join(d, "queue.lock"), os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(gate, fcntl.LOCK_EX)
        n = max([int(x.split("-")[0]) for x in ticket_names()] or [0]) + 1
        tmp = os.path.join(qdir, ".new.%d" % os.getpid())
        fd = os.open(tmp, os.O_RDWR | os.O_CREAT | os.O_TRUNC, 0o644)
        fcntl.flock(fd, fcntl.LOCK_EX)
        os.write(fd, ("pid=%d weight=%d since=%d label=%s\n" % (os.getpid(), weight, time.time(), label)).encode())
        path = os.path.join(qdir, "%012d-%d" % (n, os.getpid()))
        os.rename(tmp, path)
        return fd, path
    finally:
        os.close(gate)

def oldest_live():
    for name in ticket_names():
        path = os.path.join(qdir, name)
        alive = ticket_alive(path)
        if alive:
            return name
        if alive is False:
            try:
                os.unlink(path)
            except OSError:
                pass
    return None

def queued():
    out = []
    for name in ticket_names():
        path = os.path.join(qdir, name)
        if ticket_alive(path) is not True:
            continue
        try:
            with open(path) as f:
                fields = f.read().rstrip("\n").split(" ", 3)
        except OSError:
            continue
        info = dict(x.split("=", 1) for x in fields if "=" in x)
        age = max(0, int(time.time()) - int(info.get("since", "0") or 0))
        out.append("  queued: pid=%s weight=%s age=%ds %s" % (info.get("pid", "?"), info.get("weight", "?"), age, info.get("label", "")))
    return out

def slot_numbers():
    known = {slots}
    for n in os.listdir(d):
        if n.startswith("slot-") and n.endswith(".lock") and n[5:-5].isdigit():
            known.add(int(n[5:-5]))
    return range(1, max(known) + 1)

def holders():
    out = []
    for i in slot_numbers():
        with owner_guard(i):
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

def command_output(argv):
    try:
        return subprocess.run(argv, capture_output=True, text=True).stdout.strip()
    except OSError:
        return ""

def read_pressure():
    # (level, detail) with level normal|warn|critical, or None when the signal cannot be read.
    seam = os.environ.get("CC_TUNER_HEAVY_PRESSURE")
    if seam:
        return (seam, "CC_TUNER_HEAVY_PRESSURE") if seam in ("normal", "warn", "critical") else None
    system = command_output(["uname", "-s"])
    if system == "Darwin":
        raw = command_output(["sysctl", "-n", "kern.memorystatus_vm_pressure_level"])
        level = {"1": "normal", "2": "warn", "4": "critical"}.get(raw)
        return (level, "kern.memorystatus_vm_pressure_level=" + raw) if level else None
    if system == "Linux":
        try:
            with open(os.path.join(os.environ.get("CC_TUNER_HEAVY_PROC", "/proc"), "pressure", "memory")) as f:
                first = f.readline().split()
            avg10 = float(next(x[6:] for x in first if x.startswith("avg10=")))
        except (OSError, StopIteration, ValueError):
            return None
        if first[0] != "some":
            return None
        return ("warn" if avg10 >= 10 else "normal", "some avg10=%s" % avg10)
    return None

def deficit_left():
    # Seconds the deficit mark has left; 0 when there is none or it ran out.
    try:
        with open(deficit_path) as f:
            return max(0.0, float(f.read().strip()) - time.time())
    except (OSError, ValueError):
        return 0.0

def write_deficit():
    tmp = "%s.%d.tmp" % (deficit_path, os.getpid())
    with open(tmp, "w") as f:
        f.write("%f\n" % (time.time() + deficit_ttl))
    os.replace(tmp, deficit_path)

pressure_since = None

def memory_allows_start():
    # True: start now. False: the head keeps its slots and asks again after the next poll.
    global pressure_since
    if deficit_left() > 0:
        return True
    reading = read_pressure()
    if reading is None:
        sys.stderr.write("heavy.sh: memory pressure not measured; starting: %s\n" % label)
        return True
    level, detail = reading
    if level == "normal":
        return True
    now = time.time()
    if pressure_since is None:
        pressure_since = now
        sys.stderr.write("heavy.sh: waiting for memory pressure to ease (%s, %s), at most %ds; holding %d slot(s): %s\n"
                         % (level, detail, mem_wait, weight, label))
    if now - pressure_since >= mem_wait:
        write_deficit()
        sys.stderr.write("heavy.sh: started under memory pressure after %ds\n" % (now - pressure_since))
        return True
    return False

if mode == "status":
    h = holders()
    print("heavy.sh: capacity %d%s" % (slots, "" if h else ", all slots free"))
    reading = read_pressure()
    print("  memory pressure: %s" % ("%s (%s)" % reading if reading else "not measured"))
    if deficit_left() > 0:
        print("  memory deficit mark: active, %ds left" % deficit_left())
    for line in h + queued():
        print(line)
    sys.exit(0)

ppid = os.getppid()
ticket_fd, ticket_path = enqueue()
ticket = os.path.basename(ticket_path)

def leave_queue():
    try:
        os.unlink(ticket_path)
    except OSError:
        pass
    os.close(ticket_fd)

held = {}
notes = {}
said = False
while True:
    if os.getppid() != ppid:
        leave_queue()
        sys.stderr.write("heavy.sh: the caller is gone; leaving the queue: %s\n" % label)
        sys.exit(1)
    head = oldest_live() == ticket
    if head:
        for i in range(1, slots + 1):
            if len(held) == weight:
                break
            if i in held:
                continue
            with owner_guard(i):
                fd = try_slot(i)
                if fd is None:
                    continue
                held[i] = fd
                notes[i] = "%s weight=%d supervisor=%d since=%s cwd=%s\n" % (label, weight, os.getpid(), time.strftime("%H:%M:%S"), os.getcwd())
                write_owner(i, notes[i])
        if len(held) == weight:
            if memory_allows_start():
                break
            # Never sleep past the bound: the forced start happens at CC_TUNER_HEAVY_MEM_WAIT.
            time.sleep(max(0.01, min(poll, pressure_since + mem_wait - time.time())))
            continue
    if not said:
        want = "one" if weight == 1 else str(weight)
        sys.stderr.write("heavy.sh: waiting for %s of %d heavy-check slot(s); held by:\n%s\n" % (want, slots, "\n".join(holders())))
        said = True
    # The head polls fast: a pre-change heavy.sh waiter has no ticket and competes for the slot the
    # head still needs at its own interval, so the head should see a release first.
    time.sleep(min(poll, 0.1) if head else poll)

leave_queue()
env = dict(os.environ, CC_TUNER_HEAVY_HELD=",".join("slot-%d" % i for i in sorted(held)))
try:
    child = subprocess.Popen(cmd, env=env, pass_fds=tuple(held.values()), start_new_session=True)
except OSError as e:
    sys.stderr.write("heavy.sh: cannot run %s: %s\n" % (cmd[0], e))
    sys.exit(127)
pgid = child.pid
for i in held:
    write_owner(i, notes[i] + "group=%d\n" % pgid)

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
    # The command is done but its group is not: a keeper holds the slots until the last
    # process in the group exits, while the caller gets the command's exit code now.
    os.setsid()
    # Let go of the caller's stdio, so a caller reading this command's output is not held
    # open until the leftovers finish.
    null = os.open(os.devnull, os.O_RDWR)
    for std in (0, 1, 2):
        os.dup2(null, std)
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, signal.SIG_DFL)
    for i in held:
        write_owner(i, "%s weight=%d (exited %d; keeper=%d holds the slot for leftover work) since=%s cwd=%s\ngroup=%d\n"
                    % (label, weight, code, os.getpid(), time.strftime("%H:%M:%S"), os.getcwd(), pgid))
    while members():
        time.sleep(0.5)
    os._exit(0)
sys.exit(code)
PY
exec python3 -c "$PROG" "$MODE" "$DIR" "$SLOTS" "$WEIGHT" "$POLL" "$LABEL" "$@"
