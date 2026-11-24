#!/usr/bin/env bash
# The spec's "Domain model and design" section: each design step of /spec names what it left in the
# repository, or why it left nothing.
#
#   spec-lint.sh design <spec>    exit 0 when the section holds, otherwise one line per error
#
# /spec stated these steps as conditions the agent weighed, and over six real runs the glossary and
# ADRs were never touched: a skipped step cost nothing and showed nowhere. Here a missing answer, a
# placeholder, or a path the branch did not change fails before the spec is committed.
#
#   ## Domain model and design
#   Research: <path>[, <path>...] | not needed — <reason>
#   Glossary: <path to a GLOSSARY.md> | unchanged — <reason>
#   ADR: <path>[, <path>...] | none — <reason>
#   Prototype: <branch> | not needed — <reason>
#   Seams: <where the acceptance tests drive the change>
#   Modules: <modules added or whose interface moves> | unchanged — <reason>
#
# A path is repo-relative, exists, and differs from where this branch left the spec's `target:`,
# committed or not. /run does not call this: a spec written before the section existed still runs.
# bash 3.2 compatible.
set -u

die() { printf 'spec-lint: %s\n' "$1" >&2; exit 1; }
usage() { die "usage: spec-lint.sh design <spec>"; }

[ "${1:-}" = design ] && [ $# -eq 2 ] && [ -n "$2" ] || usage
SPEC="$2"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "spec-lint needs a git repository"
cd "$ROOT" || die "cannot enter the repository root"
[ -f "$SPEC" ] || die "no such spec: $SPEC"

errors=0
err() { printf 'spec-lint: %s\n' "$1" >&2; errors=$((errors + 1)); }

heading_count="$(grep -c '^## Domain model and design[[:space:]]*$' "$SPEC")"
[ "$heading_count" -eq 1 ] || die 'the spec needs one "## Domain model and design" section'
SECTION="$(awk '/^## Domain model and design[[:space:]]*$/ { inside = 1; next } inside && /^#{1,2} / { inside = 0 } inside' "$SPEC")"

TARGET="$(sed -n 's/^target:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$SPEC" | head -n 1)"
BASE=""
for ref in "$TARGET" "origin/$TARGET"; do
  [ -n "$TARGET" ] || break
  BASE="$(git merge-base HEAD "$ref" 2>/dev/null)" && break
  BASE=""
done
[ -n "$BASE" ] || die "cannot find the target \"${TARGET:-<none>}\" the spec's Run config names, to tell what this branch changed"
CHANGED="$( { git diff --name-only "$BASE" --; git ls-files --others --exclude-standard; } 2>/dev/null)"

# value <field> -> the field's value; an error unless the section has exactly one such line
value() {
  local count
  count="$(printf '%s\n' "$SECTION" | grep -c "^$1:")"
  if [ "$count" -ne 1 ]; then
    err "the section needs one \"$1:\" line (found $count)"
    return 1
  fi
  printf '%s\n' "$SECTION" | sed -n "s/^$1:[[:space:]]*//p" | sed 's/[[:space:]]*$//'
}

# reasoned <field> <keyword> <text> -> 0 when the text is "<keyword> — <reason>"
reasoned() {
  case "$3" in
    "$2"|"$2 —"|"$2 -"|"$2 --") err "$1: give the reason after \"—\": $2 — <reason>"; return 0 ;;
    "$2 — "?*) return 0 ;;
  esac
  return 1
}

placeholder() {
  case "$2" in
    ''|TBD|tbd|TODO|todo|'?'|'...'|'<'*'>'*|*'<'*'>') err "$1: replace the placeholder with the answer: $2"; return 0 ;;
  esac
  return 1
}

# paths <field> <value> -> each comma-separated path exists and is changed on this branch
paths() {
  local field="$1" list="$2" path old_ifs="$IFS"
  IFS=','
  for path in $list; do
    IFS="$old_ifs"
    path="$(printf '%s' "$path" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    case "/$path/" in
      //|//*|*/../*|*/./*|*//*) err "$field: a path is repo-relative, without . or .. components: $path"; continue ;;
    esac
    if [ ! -f "$path" ]; then
      err "$field: the file does not exist: $path"
    elif ! printf '%s\n' "$CHANGED" | grep -qxF -- "$path"; then
      err "$field: the file is not changed on this branch: $path"
    elif [ "$field" = Glossary ] && [ "${path##*/}" != GLOSSARY.md ]; then
      err "Glossary names GLOSSARY.md, the file domain-modeling writes: $path"
    fi
  done
  IFS="$old_ifs"
}

# The keyword each field accepts in place of an artifact.
for spec_field in "Research:not needed" "Glossary:unchanged" "ADR:none" "Prototype:not needed" "Modules:unchanged" "Seams:"; do
  field="${spec_field%%:*}"; keyword="${spec_field#*:}"
  v="$(value "$field")" || continue
  placeholder "$field" "$v" && continue
  if [ -n "$keyword" ] && reasoned "$field" "$keyword" "$v"; then continue; fi
  case "$v" in
    'not needed'*|'unchanged'*|'none'*)
      if [ "$field" != Seams ]; then
        err "$field: write $field: <path> | $keyword — <reason>"
        continue
      fi ;;
  esac
  case "$field" in
    Research|Glossary|ADR) paths "$field" "$v" ;;
    Prototype)
      git rev-parse --verify --quiet "refs/heads/$v" >/dev/null \
        || git for-each-ref --format='%(refname)' "refs/remotes/*/$v" | grep -q . \
        || err "Prototype: there is no branch named $v" ;;
  esac
done

if [ "$errors" -gt 0 ]; then exit 1; fi
printf 'spec-lint: the design section of %s holds\n' "$SPEC"
