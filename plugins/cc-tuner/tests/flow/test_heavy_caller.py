#!/usr/bin/env python3
"""heavy.sh and the caller that started it.

Two boundaries a waiting-only test misses: a launch already detached when heavy.sh starts has no
caller to lose and must run; a caller that exits while the head is reading memory pressure must not
have work launched for it by a normal reading. Each case runs heavy.sh with a private slot directory
and a probe command that writes a marker.
"""
import fcntl
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

HEAVY = Path(__file__).resolve().parents[2] / "scripts" / "heavy.sh"
fails = 0


def check(name, ok, detail=""):
    global fails
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else " (%s)" % detail))
    if not ok:
        fails = 1


def until(predicate, timeout=6.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if predicate():
            return True
        time.sleep(0.02)
    return False


def alive(pid):
    out = subprocess.run(["ps", "-p", str(pid), "-o", "pid="], capture_output=True, text=True).stdout
    return bool(out.strip())


def stop_own(pid, probe):
    # Only a process still running our private probe label is ours to signal.
    cmd = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True).stdout
    if probe in cmd:
        os.kill(pid, signal.SIGTERM)
        until(lambda: not alive(pid))


LAUNCH = """import subprocess, sys
with open(sys.argv[2], 'w') as log:
    p = subprocess.Popen(['bash', sys.argv[1], '--label', sys.argv[4], '--', 'python3', '-c',
                          'import pathlib, sys; pathlib.Path(sys.argv[1]).write_text("ran")', sys.argv[3]],
                         stdout=log, stderr=log)
    print(p.pid, flush=True)
    if len(sys.argv) > 5:
        p.wait()
"""

# 1. A launch that is detached before heavy.sh starts (nohup, launchd) has no caller to lose: it waits
# for its slot and runs. The subshell outlives the `sh` that started it, so heavy.sh's parent is init
# from its first instruction; "the parent is init" used to be read as "the caller died".
with tempfile.TemporaryDirectory(prefix="heavy-caller-detached-") as d:
    root = Path(d); slots = root / "slots"; slots.mkdir()
    marker, log = root / "ran", root / "log"
    env = dict(os.environ, CC_TUNER_HEAVY_DIR=str(slots), CC_TUNER_HEAVY_SLOTS="1",
               CC_TUNER_HEAVY_POLL="0.05", CC_TUNER_HEAVY_PRESSURE="normal")
    for k in ("CC_TUNER_HEAVY_HELD", "CC_TUNER_HEAVY_WAIT"):
        env.pop(k, None)
    with (slots / "slot-1.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            subprocess.run(["sh", "-c", '(sleep 0.3; exec bash "$0" --label detached-probe -- touch "$1") > "$2" 2>&1 &',
                            str(HEAVY), str(marker), str(log)], env=env, timeout=10, check=True)
            waited = until(lambda: log.exists() and "waiting" in log.read_text())
            check("detached-launch-queues", waited and not marker.exists(), log.read_text() if log.exists() else "")
            fcntl.flock(lock, fcntl.LOCK_UN)
            ran = until(marker.exists)
            text = log.read_text() if log.exists() else ""
            check("detached-launch-runs", ran, text)
            check("detached-launch-not-called-orphan", "caller" not in text, text)
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)

# 2. The caller exits while the head reads memory pressure; a normal reading must not launch.
with tempfile.TemporaryDirectory(prefix="heavy-caller-pressure-") as d:
    root = Path(d); bindir = root / "bin"; bindir.mkdir(); slots = root / "slots"
    marker, log = root / "ran", root / "log"
    (bindir / "uname").write_text("#!/bin/sh\necho Darwin\n")
    (bindir / "sysctl").write_text(
        "#!/bin/sh\ncase \"$*\" in *pressure*) touch \"$PROBE_ROOT/entered\"; i=0;"
        " while [ ! -f \"$PROBE_ROOT/release\" ] && [ $i -lt 200 ]; do sleep 0.03; i=$((i+1)); done; echo 1 ;;"
        " *) echo 17179869184 ;; esac\n")
    for f in bindir.iterdir():
        f.chmod(0o755)
    env = dict(os.environ, PATH=str(bindir) + ":" + os.environ["PATH"], PROBE_ROOT=d,
               CC_TUNER_HEAVY_DIR=str(slots), CC_TUNER_HEAVY_SLOTS="1", CC_TUNER_HEAVY_POLL="0.05")
    for k in ("CC_TUNER_HEAVY_HELD", "CC_TUNER_HEAVY_PRESSURE"):
        env.pop(k, None)
    parent = subprocess.Popen(["python3", "-c", LAUNCH, str(HEAVY), str(log), str(marker), "pressure-probe", "wait"],
                              env=env, text=True, stdout=subprocess.PIPE)
    pid = None
    try:
        pid = int(parent.stdout.readline())
        check("pressure-reader-reached", until((root / "entered").exists), "the head never read pressure")
        parent.terminate(); parent.wait(timeout=5)
        (root / "release").touch()
        until(lambda: not alive(pid), 4.0)
        text = log.read_text() if log.exists() else ""
        check("caller-gone-during-pressure-read-never-runs", not marker.exists(), text)
        check("caller-gone-during-pressure-read-says-so", "the caller exited while this check was queued" in text, text)
    finally:
        (root / "release").touch()
        if parent.poll() is None:
            parent.terminate(); parent.wait(timeout=5)
        if pid:
            stop_own(pid, "pressure-probe")

sys.exit(fails)
