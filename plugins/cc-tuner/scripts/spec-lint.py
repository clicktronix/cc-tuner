#!/usr/bin/env python3
"""Check the spec's "Domain model and design" section: each design step of /spec names what it left
in the repository, or why it left nothing.

usage: spec-lint.py design <spec> --base <ref>

<ref> is the commit the task branch was cut from, as /spec chose it (`origin/main`,
`refs/heads/main`). A path counts as this branch's work when it differs from the merge base of HEAD
and <ref>, committed or not.

/spec stated these steps as conditions the agent weighed, and over six real runs the glossary and
ADRs were never touched: a skipped step cost nothing and showed nowhere. Here a missing answer, a
placeholder, or a path the branch did not change fails before the spec is committed. /run does not
call this, so a spec written before the section existed still runs.

    ## Domain model and design
    Research: <path>[, <path>...] | not needed — <reason>
    Glossary: <path to a GLOSSARY.md> | unchanged — <reason>
    ADR: <path under an adr/ directory>[, <path>...] | none — <reason>
    Prototype: prototype/<name> | not needed — <reason>
    Seams: <where the acceptance tests drive the change>
    Modules: <modules added or whose interface moves> | unchanged — <reason>
"""
import os
import re
import subprocess
import sys

HEADING = "## Domain model and design"
FIELDS = [  # field, the keyword it accepts in place of an artifact, what an artifact is
    ("Research", "not needed", "paths"),
    ("Glossary", "unchanged", "paths"),
    ("ADR", "none", "paths"),
    ("Prototype", "not needed", "branch"),
    ("Seams", None, "text"),
    ("Modules", "unchanged", "text"),
]
PLACEHOLDERS = {"", "tbd", "todo", "?", "...", "…", "n/a", "na", "-", "—"}
errors = []


def fail(message):
    print(f"spec-lint: {message}", file=sys.stderr)
    sys.exit(1)


def git(*args, check=True):
    result = subprocess.run(["git", *args], capture_output=True)
    if check and result.returncode != 0:
        fail(f"git {' '.join(args)} failed: {result.stderr.decode(errors='replace').strip()}")
    return result


def section_lines(text):
    """The lines of the design section, read outside fenced code blocks."""
    fence, inside, found, lines = None, False, 0, []
    for line in text.splitlines():
        marker = re.match(r"^\s{0,3}(`{3,}|~{3,})", line)
        if marker:
            run = marker.group(1)
            if fence is None:
                fence = run
            elif run[0] == fence[0] and len(run) >= len(fence):
                fence = None
            continue
        if fence is not None:
            continue
        if line.rstrip() == HEADING:
            found += 1
            inside = True
            continue
        if inside and re.match(r"^#{1,2} ", line):
            inside = False
        if inside:
            lines.append(line)
    if found != 1:
        fail(f'the spec needs one "{HEADING}" section (found {found})')
    return lines


def is_placeholder(text):
    text = text.strip()
    return text.lower() in PLACEHOLDERS or bool(re.fullmatch(r"<[^<>]*>", text))


def changed_paths(base):
    merge_base = git("merge-base", "HEAD", base, check=False)
    if merge_base.returncode != 0:
        fail(f"cannot find a merge base of HEAD and {base}; pass the ref the task branch was cut from")
    base_commit = merge_base.stdout.decode().strip()
    listed = git("diff", "-z", "--name-only", "--no-renames", base_commit, "--").stdout
    listed += git("ls-files", "-z", "--others", "--exclude-standard").stdout
    return {name.decode("utf-8", "surrogateescape") for name in listed.split(b"\0") if name}


def check_paths(field, value, changed):
    entries = [entry.strip() for entry in value.split(",")]
    if any(not entry for entry in entries):
        errors.append(f"{field}: an entry of the list is empty: {value}")
    for path in filter(None, entries):
        parts = path.split("/")
        if path.startswith("/") or any(part in ("", ".", "..") for part in parts):
            errors.append(f"{field}: a path is repo-relative, without . or .. components: {path}")
        elif not os.path.lexists(path):
            errors.append(f"{field}: the file does not exist: {path}")
        elif os.path.islink(path) or not os.path.isfile(path):
            errors.append(f"{field}: the record is a regular file of this checkout, not a link or a directory: {path}")
        elif path not in changed:
            errors.append(f"{field}: the file is not changed on this branch: {path}")
        elif field == "Glossary" and parts[-1] != "GLOSSARY.md":
            errors.append(f"Glossary names GLOSSARY.md, the file domain-modeling writes: {path}")
        elif field == "ADR" and "adr" not in parts[:-1]:
            errors.append(f"ADR: an ADR lives under an adr/ directory, where domain-modeling writes it: {path}")


def check_branch(value):
    name = value.strip()
    if not re.fullmatch(r"prototype/[^\s~^:?*\[\\]+", name) or git("check-ref-format", f"refs/heads/{name}", check=False).returncode:
        errors.append(f"Prototype: name the prototype's branch, prototype/<name>: {name}")
        return
    refs = git("for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes").stdout.decode().splitlines()
    if f"refs/heads/{name}" not in refs and not any(ref.endswith("/" + name) and ref.startswith("refs/remotes/") and ref.count("/") == name.count("/") + 3 for ref in refs):
        errors.append(f"Prototype: there is no branch named {name}")


def main(argv):
    if len(argv) != 4 or argv[0] != "design" or argv[2] != "--base" or not argv[1] or not argv[3]:
        fail("usage: spec-lint.py design <spec> --base <ref>")
    spec, base = argv[1], argv[3]
    root = git("rev-parse", "--show-toplevel", check=False)
    if root.returncode != 0:
        fail("spec-lint needs a git repository")
    os.chdir(root.stdout.decode().strip())
    if not os.path.isfile(spec):
        fail(f"no such spec: {spec}")
    with open(spec, encoding="utf-8") as handle:
        lines = section_lines(handle.read())
    changed = changed_paths(base)

    for field, keyword, kind in FIELDS:
        values = [line[len(field) + 1:].strip() for line in lines if line.startswith(field + ":")]
        if len(values) != 1:
            errors.append(f'the section needs one "{field}:" line (found {len(values)})')
            continue
        value = values[0]
        if is_placeholder(value):
            errors.append(f"{field}: replace the placeholder with the answer: {value}")
            continue
        skip = re.fullmatch(r"(not needed|unchanged|none)(?:\s*(?:—|--|-)\s*(.*))?", value)
        if skip:
            if keyword is None or skip.group(1) != keyword:
                shape = f"{field}: <answer>" if keyword is None else f"{field}: <artifact> | {keyword} — <reason>"
                errors.append(f"{field}: write {shape}")
            elif skip.group(2) is None or is_placeholder(skip.group(2)):
                errors.append(f'{field}: give the reason after "—": {keyword} — <reason>')
            continue
        if kind == "paths":
            check_paths(field, value, changed)
        elif kind == "branch":
            check_branch(value)

    for message in errors:
        print(f"spec-lint: {message}", file=sys.stderr)
    if errors:
        return 1
    print(f"spec-lint: the design section of {spec} holds")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
