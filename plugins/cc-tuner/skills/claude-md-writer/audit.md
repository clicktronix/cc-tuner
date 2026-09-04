# Audit an instruction file

Use this procedure only when an existing `CLAUDE.md` or `AGENTS.md` has grown
large, contradictory, or hard to maintain. The commands gather evidence; they
do not decide what the repository should say.

## Contents

1. [Choose the target](#1-choose-the-target)
2. [Measure what actually loads](#2-measure-what-actually-loads)
3. [Measure sections](#3-measure-sections)
4. [Find duplicated identifiers](#4-find-duplicated-identifiers)
5. [Compare copied lists with their owner](#5-compare-copied-lists-with-their-owner)
6. [Classify the remaining content](#6-classify-the-remaining-content)
7. [Rebuild](#7-rebuild)
8. [Verify the result and its references](#8-verify-the-result-and-its-references)

## 1. Choose the target

Resolve one file before measuring it, then use that path throughout:

```bash
export TARGET=AGENTS.md # or CLAUDE.md, .claude/CLAUDE.md, a nested file, etc.
test -f "$TARGET" || { echo "missing target: $TARGET" >&2; exit 1; }
```

Do not silently switch between `AGENTS.md` and `CLAUDE.md`. If both exist,
establish which one owns the shared rules and whether the other imports or
links to it.

## 2. Measure what actually loads

For Claude Code, `/context` -> **Memory files** is authoritative. Count every
ancestor file listed there and every rule without `paths:`. A disk search alone
cannot prove that Claude loaded a file.

For Codex, `project_doc_max_bytes` limits only project instruction entries. It
is 32 KiB by default, can be overridden in Codex configuration, and is shared
by the project files discovered from repository root to `cwd` (and by project
files from any additional selected environment). User-level
`~/.codex/AGENTS.md` is added separately and must not be subtracted from this
budget. Truncation emits a tracing warning, which may not be visible in the
ordinary UI.

Ask the installed CLI what the model actually receives instead of recreating
its loader arithmetic:

```bash
codex debug prompt-input 'instruction audit' |
  jq -r '.[] | .content[]? | select(.type == "input_text") | .text' |
  sed -n '/^# AGENTS\.md instructions/,/<\/INSTRUCTIONS>/p'
```

For the default single-repository route, list the contributing project files
in load order with this diagnostic. If Codex configuration adds fallback
filenames or additional environments, the rendered prompt above remains the
authority.

```bash
# audit-ancestor-chain
root=$(git rev-parse --show-toplevel) || exit 1
dir=$(pwd -P)
docs=()
while [[ "$dir" == "$root" || "$dir" == "$root/"* ]]; do
  for name in AGENTS.override.md AGENTS.md; do
    if [[ -f "$dir/$name" ]]; then
      docs[${#docs[@]}]="$dir/$name"
      break
    fi
  done
  [[ "$dir" == "$root" ]] && break
  dir=${dir%/*}
done
for ((i=${#docs[@]} - 1; i >= 0; i--)); do wc -c "${docs[$i]}"; done
```

## 3. Measure sections

This prints every `##` section, including the final one, with its full span
including the heading:

```bash
: "${TARGET:?set TARGET to the instruction file}"
# audit-section-sizes
awk '
  /^## / {
    if (seen) print start ":" title " -> " NR - start
    seen = 1; start = NR; title = $0
  }
  END {
    if (seen) print start ":" title " -> " NR - start + 1
  }
' "$TARGET"
```

Treat a large section as a candidate for inspection, not automatic deletion.
Procedures and historical narration are common causes; short unenforced
constraints may carry more value than either.

## 4. Find duplicated identifiers

Choose identifiers that distinguish the suspected block, then search them as
literal strings:

```bash
: "${TARGET:?set TARGET to the instruction file}"
: "${IDS:?set IDS to space-separated literal identifiers}"
# audit-literal-identifiers
files=("$TARGET")
while IFS= read -r -d '' file; do files+=("$file"); done \
  < <(find .claude/rules -type f -name '*.md' -print0 2>/dev/null)
for id in $IDS; do
  printf '%s: ' "$id"
  grep -lF -- "$id" "${files[@]}" 2>/dev/null | tr '\n' ' '
  printf '\n'
done
```

Selecting useful identifiers is a judgement call. A match in two files is
evidence of duplication only after checking that both statements mean the
same thing and load for the same work.

## 5. Compare copied lists with their owner

First identify the exact line range containing the suspected copy. If there is
no copy, the step passes. If its claimed owner does not exist, report that fact
and stop this comparison rather than manufacturing an empty owner.

The example below compares an environment-key section with `.env.example`
without shared temporary files and accepts both `NAME=value` and
`export NAME=value` in the owner:

```bash
: "${TARGET:?set TARGET to the instruction file}"
: "${FROM:?set FROM to the first line of the copied list}"
: "${TO:?set TO to the last line of the copied list}"
OWNER=${OWNER:-.env.example}
# audit-owned-list
if [[ ! -f "$OWNER" ]]; then
  printf 'SKIP: owner does not exist: %s\n' "$OWNER" >&2
else
  diff \
    <(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Z][A-Z0-9_]*)=.*/\2/p' "$OWNER" | sort -u) \
    <(sed -n "${FROM},${TO}p" "$TARGET" | grep -oE '`[A-Z][A-Z0-9_]+`' | tr -d '`' | sort -u)
fi
```

A difference is a reason to inspect the ownership boundary, not a verdict.
When the owner is authoritative, replace the copy with a pointer instead of
repairing both lists.

## 5b. Check a rule against its own `paths:`

Two failures live here, and both are silent.

**A rule that legislates where it never loads.** A body that governs an area outside the rule's own
globs is inert there and fires where it does not apply. One repository's architecture rule carried a
"new public table" migration checklist while scoped to `src/**`: it loaded on UI edits and stayed
silent on every migration. The same rule documented `src/infrastructure/**` ownership with that path
absent from its frontmatter.

This one resists a one-liner — a rule may legitimately *mention* a neighbour it does not govern, and
only a reader can tell a mention from a rule. Do it by hand, once per rule: list the directories the
body gives instructions about, list the directories the frontmatter matches, and account for every
difference. A rule for area X whose body legislates area Y either grows a glob or loses the section.

**A pointer table that has drifted from the frontmatter.** Where `AGENTS.md` lists rule → glob for
the agents that do not autoload rules, that table is a hand copy, and one session was enough for a
glob to vanish from it while the rule kept matching. This one is mechanical, so it belongs in the
repository's gate rather than in an audit that ends:

```python
# audit-pointer-table-parity — сверяет колонку глобов в AGENTS.md с paths: правил
import ast, pathlib, re, sys

def expand(glob):
    m = re.search(r'\{([^}]*)\}', glob)
    if not m:
        return [glob]
    return [g for opt in m.group(1).split(',')
              for g in expand(glob[:m.start()] + opt.strip() + glob[m.end():])]

def prefixes(globs):
    return {re.sub(r'/?\*.*$', '', e).rstrip('/') for g in globs for e in expand(g)} - {''}

table = pathlib.Path('AGENTS.md').read_text().splitlines()
issues = []
for rule in sorted(pathlib.Path('.claude/rules').glob('*.md')):
    txt = rule.read_text()
    declared = []
    if txt.startswith('---') and 'paths:' in txt.split('---')[1]:
        declared = ast.literal_eval(txt.split('---')[1].split('paths:', 1)[1].strip())
    row = next((l for l in table if l.startswith(f'| `.claude/rules/{rule.name}`')), None)
    if row is None:
        issues.append(f'{rule.name}: no row in the pointer table')
        continue
    cell = row.split('|')[2]
    if not declared:
        if 'always' not in cell:
            issues.append(f'{rule.name}: has no paths:, but the table does not say "always"')
        continue
    listed = prefixes(re.findall(r'`([^`]+)`', cell))
    for miss in sorted(prefixes(declared) - listed):
        issues.append(f'{rule.name}: table is missing {miss}')
    for extra in sorted(listed - prefixes(declared)):
        issues.append(f'{rule.name}: table claims {extra}, frontmatter does not')

print('\n'.join(issues) if issues else 'pointer table matches every rule frontmatter')
sys.exit(1 if issues else 0)
```

Run it before trusting the table, and again after editing either side. It reports a missing glob, a
glob the table invented, a rule with no row, and a `paths:`-less rule the table does not mark as
always-loaded.

## 6. Classify the remaining content

Use one genre per block:

| Genre | Sign | Destination |
|---|---|---|
| instruction | repository-specific `do X` / `never Y` | keep in the narrowest applicable instruction file |
| procedure | more than two steps, used for a task | skill or `docs/how-to/` |
| chronicle | dated measurement or incident narrative | issue, decision record, or adjacent code comment |
| copy | an authoritative owner already exists | delete and point to the owner |
| generic preference | true across the user's projects | user scope, once |
| duplicate | same rule already reaches the same work | delete one copy |

Then inspect every remaining constraint against lint, format, type, test, hook,
and settings enforcement. This is judgement, not a mechanical grep:

- fully enforced and already obvious from the tool configuration -> remove the prose copy;
- not enforced or only partially enforced -> keep the concise instruction;
- must block regardless of model judgement -> use a hook or setting.

## 7. Rebuild

Rebuild around repository-specific, always-relevant facts rather than editing
the old shape line by line. Do not force identical headings on every project.
A useful small file usually contains:

- the repository's purpose and language;
- setup and the exact validation commands;
- critical unenforced prohibitions;
- repository-specific branch or delivery rules;
- pointers to scoped rules, skills, and runbooks.

Generic preferences such as a personal refactoring philosophy belong once at
user scope. Put them in a repository file only when that repository has a
specific deviation or a concrete failure that requires the rule there.

## 8. Verify the result and its references

Before editing, record headings and paths that will be removed or renamed.
After rebuilding:

1. Search the repository literally for each old heading and path with
   `rg -nF -- '<old heading or path>'` and update every live pointer.
2. Run the repository's instruction-file validator or `/doctor`, if present.
3. Re-run Steps 2-5 against the rebuilt file.
4. For Claude Code, confirm the result in `/context`.
5. For Codex, confirm the exact model-visible block with
   `codex debug prompt-input`.
6. Run the repository's normal test suite when instruction changes affect its
   workflow or commands.

The final check is behavioral: observe the next real tasks. Static structure
can prove that pointers and commands resolve; it cannot prove model adherence.
