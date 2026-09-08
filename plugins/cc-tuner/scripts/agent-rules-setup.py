#!/usr/bin/env python3
"""Install a portable rule-loading instruction; never copy or rewrite project rules."""

import argparse
import difflib
import os
from pathlib import Path
import subprocess
import tempfile

BEGIN = "<!-- agent-rules:begin -->"
END = "<!-- agent-rules:end -->"


def proposed(current, block):
    if BEGIN not in current and END not in current:
        return block + ("\n" + current if current else "")
    if current.count(BEGIN) != 1 or current.count(END) != 1:
        raise ValueError("ambiguous agent-rules markers; nothing written")
    start = current.index(BEGIN)
    stop = current.index(END) + len(END)
    if stop < start:
        raise ValueError("reversed agent-rules markers; nothing written")
    if current[start:stop] != block.rstrip("\n"):
        raise ValueError(
            "existing agent-rules block differs; review it manually; nothing written"
        )
    if start == 0:
        return current
    return block + "\n" + current[:start] + current[stop:]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "mode", choices=("check", "install"), default="check", nargs="?"
    )
    parser.add_argument(
        "--repo", default=".", help="Repository or a directory inside it"
    )
    args = parser.parse_args()
    repo = Path(
        subprocess.check_output(
            ["git", "-C", args.repo, "rev-parse", "--show-toplevel"], text=True
        ).strip()
    ).resolve()
    target = repo / "AGENTS.override.md"
    if not target.exists() and not target.is_symlink():
        target = repo / "AGENTS.md"
    if target.is_symlink():
        raise ValueError(
            "instruction file is a symlink; inspect its owner before editing; nothing written"
        )
    current = target.read_bytes().decode("utf-8") if target.exists() else ""
    block = (
        Path(__file__).resolve().parent.parent / "assets/agent-rules/instruction.md"
    ).read_text()
    if not block.startswith(BEGIN) or not block.rstrip().endswith(END):
        raise ValueError("invalid bundled instruction; nothing written")
    result = proposed(current, block)
    if len(result.encode("utf-8")) > 32768:
        print(
            "WARN root instructions exceed Codex default 32 KiB; verify your configured budget"
        )
    if result == current:
        print(
            f"OK {target}: rule-loading instruction present (not proof of model adherence)"
        )
        return 0
    print(
        "".join(
            difflib.unified_diff(
                current.splitlines(True),
                result.splitlines(True),
                fromfile=str(target),
                tofile=str(target),
            )
        ),
        end="",
    )
    if args.mode == "check":
        print("MISSING rule-loading instruction; check wrote nothing")
        return 1
    # Keep bytes outside the block, permissions, and an intervening user's edit intact.
    temp_name = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", dir=repo, delete=False, prefix=".agent-rules-", encoding="utf-8"
        ) as temp:
            temp_name = temp.name
            temp.write(result)
        os.chmod(temp_name, target.stat().st_mode & 0o777 if target.exists() else 0o644)
        if (
            target.is_symlink()
            or (target.read_bytes().decode("utf-8") if target.exists() else "")
            != current
        ):
            raise ValueError(
                "instruction file changed during setup; nothing overwritten"
            )
        os.replace(temp_name, target)
    finally:
        if temp_name and Path(temp_name).exists():
            Path(temp_name).unlink()
    print(
        f"INSTALLED {target}; start a fresh Codex session to load startup instructions"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(f"ERROR: {exc}")
        raise SystemExit(2)
