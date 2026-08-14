#!/usr/bin/env bash
# Which installation of a plugin applies to THIS repository?
#
#   plugin-here.sh <plugin-id> [project-root]
#
# Prints exactly ONE row -- the installation that applies -- tab separated:
#
#   <installPath><TAB><version><TAB><scope>
#
# Exit 0 with the row, 1 with none, 2 when the question cannot be answered at all (no `claude`, no
# `jq`). "Cannot answer" is deliberately not the same as "not installed": a caller that treats them
# alike reports a missing plugin to someone whose only problem is a missing `jq`.
#
# **One row, not a list, and that is the whole point.** The first version printed every applicable
# install, best first, and left the caller to pick. Reproduced: a `local` install missing the
# code-review skill, plus a complete `user` install, and the preflight reported `prereqs OK` -- it had
# searched every root for each file and found each one *somewhere*. But only the top install loads,
# so the check passed on files that will never be read while the one that will be is broken. A
# resolver that answers "which install applies" and then hands back three of them has not answered.
#
# Why this exists as its own program. `claude plugin list --json` is the platform's own answer, so
# nothing here parses a plugin manifest -- but it does NOT answer which installation applies. It
# returns one row per installation, and on 2.1.231 cc-tuner comes back twice: `scope: project` with a
# `projectPath`, and `scope: user` without one, both `enabled: true`, with no `active` field. So a
# selection rule still has to exist, and it had two homes -- doctor.sh and the preflight -- which is
# how they came to disagree, first about `enabled: false` and then about how many installs count.
#
# Total order, not list order: local, then project, then user, matching the scope precedence Claude
# Code applies to settings. Grouping any two of them would leave the choice to row order, so two
# readers of one list could pick different installs and both be "right". A row scoped to a different
# project cannot answer for this repository at all.
#
# `enabled: false` is excluded. A disabled plugin does not load its commands, so a check that reports
# it as present greenlights a run whose gate will never fire.
#
# CC_TUNER_PLUGIN_LIST_CMD overrides the source command, which is how the tests install a fixture.
# bash 3.2 compatible: macOS ships 3.2.57.
set -u

ID="${1:-}"
[ -n "$ID" ] || { printf 'plugin-here: usage: plugin-here.sh <plugin-id> [project-root]\n' >&2; exit 2; }

PROJECT="${2:-}"
if [ -z "$PROJECT" ]; then
  PROJECT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$PROJECT" ] || PROJECT="$PWD"
fi
# Canonicalized once here, and every candidate's `projectPath` is canonicalized too, below.
#
# A previous version compared the caller's string against both its own spellings and left it there.
# That was useless: every caller resolves its root through `git rev-parse --show-toplevel` or
# `pwd -P` first, so only the canonical form ever arrives, and the mitigation could not fire in
# production. Its test called this script directly with a lexical path -- a route nothing uses --
# which is the exact defect this branch exists to remove, committed while fixing an instance of it.
#
# The comparison that matters is between two canonical paths, so `projectPath` has to be resolved on
# the filesystem, which jq cannot do. Hence the walk below rather than one jq expression: on macOS a
# repo under /var/tmp is recorded lexically and reported canonically under /private/var/tmp, and a
# project-scoped install then loses to a user-scoped one that should never have been reached.
PROJECT="$(CDPATH='' cd -- "$PROJECT" 2>/dev/null && pwd -P)" || PROJECT="$PROJECT"

command -v jq >/dev/null 2>&1 || { printf 'plugin-here: jq is required\n' >&2; exit 2; }

LIST="$(${CC_TUNER_PLUGIN_LIST_CMD:-claude plugin list --json} 2>/dev/null)" || LIST=""
[ -n "$LIST" ] || { printf 'plugin-here: could not list installed plugins\n' >&2; exit 2; }

# Candidates in precedence order, scope filtering left to the walk. `// ""` on every field, never
# `// empty`: inside an array constructor `empty` DELETES the element rather than yielding a blank
# one, so a row with no installPath emitted three columns instead of four and every reader shifted.
CANDIDATES="$(printf '%s' "$LIST" | jq -r --arg id "$ID" '
  [ .[]? | select(.id == $id and (.enabled != false)) ]
  | sort_by(if .scope == "local" then 0 elif .scope == "project" then 1 else 2 end)
  | .[] | [ (.installPath // ""), (.version // ""), (.scope // ""), (.projectPath // "") ] | @tsv
' 2>/dev/null)" || {
  printf 'plugin-here: could not read the installed-plugin list\n' >&2; exit 2
}

while IFS= read -r row; do
  [ -n "$row" ] || continue
  # Split by parameter expansion. `read -r a b c d` with IFS set to tab collapses empty fields and
  # shifts the rest left, because tab is one of the default IFS whitespace characters.
  path="${row%%	*}";  rest="${row#*	}"
  ver="${rest%%	*}";  rest="${rest#*	}"
  scope="${rest%%	*}"; ppath="${rest#*	}"

  case "$scope" in
    user) ;;
    project|local)
      [ -n "$ppath" ] || continue
      # Resolve the recorded path the same way the caller's was resolved. A path that no longer
      # exists cannot be canonicalized, so it falls back to the literal comparison rather than
      # matching everything.
      preal="$(CDPATH='' cd -- "$ppath" 2>/dev/null && pwd -P)" || preal="$ppath"
      [ "$preal" = "$PROJECT" ] || continue
      ;;
    *) continue ;;
  esac

  printf '%s\t%s\t%s\n' "$path" "$ver" "$scope"
  exit 0
done <<EOF
$CANDIDATES
EOF

exit 1
