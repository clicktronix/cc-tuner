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
    # Consume the newline that terminated the block's last line, mirroring the
    # separator this function adds when it inserts one. Without it, moving the
    # block leaves the separators on both of its former sides adjacent.
    if current[stop : stop + 1] == "\n":
        stop += 1
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
    # git's own 128 says "not a repository" and "no such directory" in the same
    # breath, and its argv repr tells the operator nothing about either.
    try:
        toplevel = subprocess.check_output(
            ["git", "-C", args.repo, "rev-parse", "--show-toplevel"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except subprocess.CalledProcessError:
        raise ValueError(
            f"{args.repo} is not inside a Git repository, or does not exist; "
            "run this from a repository or pass --repo; nothing written"
        ) from None
    repo = Path(toplevel).resolve()
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
    # proposed() has already refused a differing or ambiguous block, so a marker
    # surviving here means the instruction is present verbatim.
    present = BEGIN in current
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
    # "The file needs an edit" is not one state. A block that is present but not
    # first needs a move, and reporting that as MISSING sends the operator
    # looking for text that is already there.
    if args.mode == "check":
        if present:
            print(
                "PRESENT BUT NOT FIRST: the rule-loading instruction is installed lower "
                "in the file, where the instruction budget can truncate it; "
                "install moves it to the top; check wrote nothing"
            )
        else:
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
        f"{'MOVED' if present else 'INSTALLED'} {target}; "
        "start a fresh Codex session to load startup instructions"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(f"ERROR: {exc}")
        raise SystemExit(2)
