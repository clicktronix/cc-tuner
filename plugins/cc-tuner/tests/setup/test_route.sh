#!/usr/bin/env bash
# Regression tests for scripts/setup/route.sh, the one owner of the delivery-route key block.
#
# The producer and the checker are the same program, so every case writes with `route.sh write` and
# reads with `route.sh check`, and doctor then reads the same file: a hand-built block would only prove
# that the test agrees with itself. Hand-built files appear only for states the producer refuses to
# make (a malformed block, CRLF line endings, the legacy header).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$(cd "$HERE/../.." && pwd)"
ROUTE="$PLUGIN/scripts/setup/route.sh"
DOCTOR="$PLUGIN/scripts/setup/doctor.sh"
fails=0

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1${2:+ ($2)}"; fails=1; }
eq() { # eq <name> <want> <got>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want [$2] got [$3]"; fi
}
has() { # has <name> <fixed substring> <text>
  case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "want [$2] in [$3]" ;; esac
}
lacks() {
  case "$3" in *"$2"*) fail "$1" "unwanted [$2] in [$3]" ;; *) pass "$1" ;; esac
}
same_file() { if cmp -s "$2" "$3"; then pass "$1"; else fail "$1" "files differ"; fi; }

T="$(mktemp -d)" || { echo "FATAL: mktemp failed"; exit 1; }
trap 'rm -rf "$T"' EXIT
R="$T/repo"; F="$R/.claude/rules/task-flow.local.md"
fresh() { # fresh: a repo whose task-flow.local.md holds a header, deltas and a trailing paragraph
  rm -rf "$R"; mkdir -p "$R/.claude/rules"
  ( cd "$R" && git init -q -b main )
  printf '%s\n' '# task-flow — repo-specific deltas' '' \
    '<!-- Overrides and additions to task-flow.md live here; setup writes only between cc-tuner markers' \
    '     (the delivery route) and caches board field IDs. Typical content: board name/number + cached field' \
    '     IDs, label taxonomy, merge-policy exceptions. -->' '' 'board: 3' > "$F"
}
without_block() { sed '/^<!-- cc-tuner:delivery-route /,/^<!-- \/cc-tuner:delivery-route -->$/d' "$1"; }
rc_of() { "$@" >/dev/null 2>&1; echo $?; }

# --- canonical: the one source of the block text ----------------------------------------------------
OUT="$(bash "$ROUTE" canonical gitlab)"
eq  "canonical-gitlab-three-lines" 3 "$(printf '%s\n' "$OUT" | grep -c '')"
eq  "canonical-opens-with-the-host" '<!-- cc-tuner:delivery-route gitlab -->' "$(printf '%s\n' "$OUT" | head -n 1)"
eq  "canonical-closes" '<!-- /cc-tuner:delivery-route -->' "$(printf '%s\n' "$OUT" | tail -n 1)"
has "canonical-names-the-plugin-reference" "skills/run/references/route-gitlab.md in the cc-tuner plugin" "$OUT"
has "canonical-forbids-a-web-merge" "never by a web merge or a bare CLI merge" "$OUT"
lacks "canonical-has-no-version-marker" " v0." "$OUT"
has "canonical-local-names-its-reference" "skills/run/references/route-local.md" "$(bash "$ROUTE" canonical local)"
eq  "canonical-other-is-a-usage-error" 2 "$(rc_of bash "$ROUTE" canonical other)"
eq  "canonical-github-is-a-usage-error" 2 "$(rc_of bash "$ROUTE" canonical github)"

# --- round trip: the real producer through the real checker ----------------------------------------
for host in gitlab local; do
  fresh
  eq "write-$host-appends"        written "$(bash "$ROUTE" write "$host" "$F")"
  eq "check-$host-is-current"     current "$(bash "$ROUTE" check "$host" "$R")"
  eq "check-$host-rc0"            0       "$(rc_of bash "$ROUTE" check "$host" "$R")"
  eq "write-$host-is-idempotent"  unchanged "$(bash "$ROUTE" write "$host" "$F")"
  eq "$host-block-is-canonical"   "$(bash "$ROUTE" canonical "$host")" "$(sed -n '/^<!-- cc-tuner:delivery-route /,/^<!-- \/cc-tuner:delivery-route -->$/p' "$F")"
done

fresh
printf 'Open a review on our forge.\nWait for two approvals, then merge from the UI.\n' > "$T/body"
eq "write-other-appends"        written "$(bash "$ROUTE" write other "$F" "$T/body")"
eq "check-other-is-present"     present-other "$(bash "$ROUTE" check other "$R")"
eq "check-other-rc0"            0 "$(rc_of bash "$ROUTE" check other "$R")"
has "other-body-is-between-the-markers" "$(cat "$T/body")" "$(sed -n '/^<!-- cc-tuner:delivery-route other -->$/,/^<!-- \/cc-tuner:delivery-route -->$/p' "$F")"
eq "write-other-is-idempotent"  unchanged "$(bash "$ROUTE" write other "$F" "$T/body")"
printf 'Merge from the UI after one approval.' > "$T/body2"
eq "write-other-replaces-a-changed-description" replaced "$(bash "$ROUTE" write other "$F" "$T/body2")"
has "other-new-body-without-trailing-newline-is-closed" "Merge from the UI after one approval.
<!-- /cc-tuner:delivery-route -->" "$(cat "$F")"
eq "check-other-after-replace"  present-other "$(bash "$ROUTE" check other "$R")"

# --- doctor reads what the writer wrote (host local: no remote) ------------------------------------
fresh
bash "$ROUTE" write local "$F" >/dev/null
DOC="$( cd "$R" && HOME="$T" bash "$DOCTOR" quick 2>&1 )"
has "doctor-says-current-after-write" "ok   delivery route (local) current" "$DOC"
bash "$ROUTE" write other "$F" "$T/body" >/dev/null
DOC="$( cd "$R" && HOME="$T" bash "$DOCTOR" quick 2>&1 )"
has "doctor-says-the-other-block-is-a-mismatch-for-local" "delivery route block is for host other, but this repository's host is local" "$DOC"

# --- replace in place, outside text untouched ------------------------------------------------------
fresh
printf '\nlabels: bug, feature\n' >> "$F"
cp "$F" "$T/before"
bash "$ROUTE" write gitlab "$F" >/dev/null
without_block "$F" > "$T/after-append"
# an appended block follows one blank line, which belongs to the block's separator
{ cat "$T/before"; printf '\n'; } > "$T/before-sep"
same_file "append-keeps-outside-text" "$T/before-sep" "$T/after-append"
# put text after the block, then switch the host, then the description
printf '\nmore deltas\n' >> "$F"
without_block "$F" > "$T/mid-outside"
eq "write-other-host-switch-replaces" replaced "$(bash "$ROUTE" write local "$F")"
without_block "$F" > "$T/after-local"
same_file "replace-local-keeps-outside-text" "$T/mid-outside" "$T/after-local"
eq "write-after-a-switch-checks-current" current "$(bash "$ROUTE" check local "$R")"
bash "$ROUTE" write other "$F" "$T/body" >/dev/null
without_block "$F" > "$T/after-other"
same_file "replace-other-keeps-outside-text" "$T/mid-outside" "$T/after-other"
eq "one-block-only-after-replaces" 1 "$(grep -c '^<!-- cc-tuner:delivery-route ' "$F")"
# drift is repaired in place
bash "$ROUTE" write gitlab "$F" >/dev/null
sed 's/never by a web merge/by any merge/' "$F" > "$T/drifted" && cp "$T/drifted" "$F"
eq "check-drift"      drift "$(bash "$ROUTE" check gitlab "$R")"
eq "check-drift-rc12" 12    "$(rc_of bash "$ROUTE" check gitlab "$R")"
eq "write-repairs-drift" replaced "$(bash "$ROUTE" write gitlab "$F")"
eq "check-repaired"   current "$(bash "$ROUTE" check gitlab "$R")"
# no scratch left behind next to the file, and the file mode is kept
eq "no-temp-files-left-in-rules" "task-flow.local.md" "$(ls -A "$R/.claude/rules")"
fresh; chmod 640 "$F"; bash "$ROUTE" write gitlab "$F" >/dev/null
eq "write-keeps-the-file-mode" "-rw-r-----" "$(ls -l "$F" | cut -c1-10)"
# a file that does not end in a newline still gets a separate block
fresh; printf 'no newline at the end' >> "$F"
bash "$ROUTE" write local "$F" >/dev/null
eq "append-after-no-trailing-newline-is-current" current "$(bash "$ROUTE" check local "$R")"
has "append-after-no-trailing-newline-keeps-the-line" "no newline at the end
" "$(cat "$F"; printf x)"

# --- the legacy header --------------------------------------------------------------------------------
fresh
printf '%s\n' '# task-flow — repo-specific deltas' '' \
  '<!-- Overrides and additions to task-flow.md live here; setup never touches this file.' \
  '     Typical content: board name/number + cached field IDs, label taxonomy, merge-policy exceptions. -->' \
  '' 'board: 3' '' '<!-- cc-tuner:delivery-route local v0.23.0 -->' 'Old copied route text.' 'line two' \
  '<!-- /cc-tuner:delivery-route -->' '' 'more deltas' > "$F"
eq "legacy-block-with-a-versioned-marker-is-drift" drift "$(bash "$ROUTE" check local "$R")"
eq "legacy-write-replaces" replaced "$(bash "$ROUTE" write local "$F")"
eq "legacy-write-checks-current" current "$(bash "$ROUTE" check local "$R")"
LEGACY_OUT="$(cat "$F")"
lacks "legacy-header-no-longer-says-never-touches" "never touches this file" "$LEGACY_OUT"
has   "legacy-header-has-the-current-wording" "setup writes only between cc-tuner markers" "$LEGACY_OUT"
lacks "legacy-old-route-text-is-gone" "Old copied route text." "$LEGACY_OUT"
has   "legacy-keeps-outside-text" "board: 3" "$LEGACY_OUT"
has   "legacy-keeps-the-text-after-the-block" "more deltas" "$LEGACY_OUT"
# the wording route.sh writes is the wording the setup reference writes into a new file
REF="$PLUGIN/skills/setup/references/task-flow-rule.md"
for want in "Overrides and additions to task-flow.md live here; setup writes only between cc-tuner markers" \
            "(the delivery route) and caches board field IDs. Typical content: board name/number + cached field" \
            "IDs, label taxonomy, merge-policy exceptions. -->"; do
  case "$LEGACY_OUT" in *"$want"*) ;; *) fail "header-line-in-route-sh-output" "$want" ;; esac
  if grep -qF -- "$want" "$REF"; then pass "header-line-is-in-task-flow-rule-md"; else fail "header-line-is-in-task-flow-rule-md" "$want"; fi
done
# only the exact legacy pair is rewritten: an edited second line is the user's text
fresh
printf '%s\n' '<!-- Overrides and additions to task-flow.md live here; setup never touches this file.' 'my own second line -->' > "$F"
bash "$ROUTE" write local "$F" >/dev/null
has "edited-legacy-header-is-left-alone" "my own second line -->" "$(cat "$F")"

# --- check: every state, one stable line ---------------------------------------------------------------
fresh
eq "check-missing"        missing "$(bash "$ROUTE" check local "$R")"
eq "check-missing-rc10"   10      "$(rc_of bash "$ROUTE" check local "$R")"
eq "check-missing-other"  missing "$(bash "$ROUTE" check other "$R")"
eq "check-github-none-needed"    none-needed "$(bash "$ROUTE" check github "$R")"
eq "check-github-none-needed-rc" 0           "$(rc_of bash "$ROUTE" check github "$R")"
rm -f "$F"
eq "check-no-file-is-missing"    missing "$(bash "$ROUTE" check gitlab "$R")"
eq "check-no-file-github-is-none-needed" none-needed "$(bash "$ROUTE" check github "$R")"
fresh; bash "$ROUTE" write gitlab "$F" >/dev/null
eq "check-mismatch"       "mismatch gitlab" "$(bash "$ROUTE" check local "$R")"
eq "check-mismatch-rc11"  11 "$(rc_of bash "$ROUTE" check local "$R")"
eq "check-mismatch-for-other" "mismatch gitlab" "$(bash "$ROUTE" check other "$R")"
eq "check-stale-on-github"    "stale-on-github gitlab" "$(bash "$ROUTE" check github "$R")"
eq "check-stale-on-github-rc14" 14 "$(rc_of bash "$ROUTE" check github "$R")"
bash "$ROUTE" write other "$F" "$T/body" >/dev/null
eq "check-stale-other-on-github" "stale-on-github other" "$(bash "$ROUTE" check github "$R")"
eq "check-bad-host-is-usage" 2 "$(rc_of bash "$ROUTE" check bitbucket "$R")"
fresh; bash "$ROUTE" write local "$F" >/dev/null
eq "check-without-a-root-uses-the-repo" current "$( cd "$R/.claude" && bash "$ROUTE" check local )"

# --- malformed: counted, refused by check and by write, never repaired -----------------------------
M_OPEN='<!-- cc-tuner:delivery-route local -->'; M_CLOSE='<!-- /cc-tuner:delivery-route -->'
fresh; printf '%s\nbody\n' "$M_OPEN" >> "$F"
eq "check-unclosed"          "malformed 1 0" "$(bash "$ROUTE" check local "$R")"
eq "check-unclosed-rc13"     13 "$(rc_of bash "$ROUTE" check local "$R")"
eq "check-unclosed-github"   "malformed 1 0" "$(bash "$ROUTE" check github "$R")"
cp "$F" "$T/unclosed"
eq "write-refuses-unclosed"  3 "$(rc_of bash "$ROUTE" write local "$F")"
same_file "write-leaves-an-unclosed-file-untouched" "$T/unclosed" "$F"
fresh; printf '%s\n%s\nx\n%s\n%s\n' "$M_OPEN" "$M_CLOSE" "$M_OPEN" "$M_CLOSE" >> "$F"
eq "check-two-blocks"        "malformed 2 2" "$(bash "$ROUTE" check local "$R")"
cp "$F" "$T/two"
eq "write-refuses-two-blocks" 3 "$(rc_of bash "$ROUTE" write gitlab "$F")"
same_file "write-leaves-two-blocks-untouched" "$T/two" "$F"
fresh; printf '%s\n%s\n' "$M_CLOSE" "$M_OPEN" >> "$F"
eq "check-closing-before-opening" "malformed 1 1" "$(bash "$ROUTE" check local "$R")"
eq "write-refuses-closing-first" 3 "$(rc_of bash "$ROUTE" write local "$F")"
fresh; printf '%s\n' "$M_CLOSE" >> "$F"
eq "check-stray-closing"     "malformed 0 1" "$(bash "$ROUTE" check local "$R")"

# --- CRLF checkouts: still current, and writing leaves them as they are -----------------------------
fresh; bash "$ROUTE" write gitlab "$F" >/dev/null
sed 's/$/\r/' "$F" > "$T/crlf" && cp "$T/crlf" "$F"
eq "crlf-check-is-current"   current "$(bash "$ROUTE" check gitlab "$R")"
eq "crlf-write-is-unchanged" unchanged "$(bash "$ROUTE" write gitlab "$F")"
same_file "crlf-write-keeps-the-bytes" "$T/crlf" "$F"
eq "crlf-write-replaces-a-different-host" replaced "$(bash "$ROUTE" write local "$F")"
eq "crlf-check-after-replace" current "$(bash "$ROUTE" check local "$R")"
fresh; bash "$ROUTE" write local "$F" >/dev/null
sed 's/$/\r/' "$F" | sed 's/web merge/web  merge/' > "$T/crlf-drift" && cp "$T/crlf-drift" "$F"
eq "crlf-drift-is-still-drift" drift "$(bash "$ROUTE" check local "$R")"

# --- write refuses what it cannot do, and writes nothing -----------------------------------------------
fresh; cp "$F" "$T/pristine"
eq "other-without-a-body-argument-is-refused" 2 "$(rc_of bash "$ROUTE" write other "$F")"
: > "$T/empty"
eq "other-with-an-empty-body-is-refused"      2 "$(rc_of bash "$ROUTE" write other "$F" "$T/empty")"
printf '  \n\n' > "$T/blank"
eq "other-with-a-blank-body-is-refused"       2 "$(rc_of bash "$ROUTE" write other "$F" "$T/blank")"
eq "other-with-a-missing-body-file-is-refused" 2 "$(rc_of bash "$ROUTE" write other "$F" "$T/nope")"
printf 'merge it\n<!-- /cc-tuner:delivery-route -->\nand more\n' > "$T/markers"
eq "other-with-a-marker-in-the-body-is-refused" 2 "$(rc_of bash "$ROUTE" write other "$F" "$T/markers")"
same_file "refused-writes-leave-the-file-untouched" "$T/pristine" "$F"
ERR="$(bash "$ROUTE" write other "$F" 2>&1 >/dev/null)"
has "other-refusal-says-what-is-missing" "non-empty description file" "$ERR"
eq "write-github-is-refused"          2 "$(rc_of bash "$ROUTE" write github "$F")"
eq "write-into-a-missing-file-is-refused" 2 "$(rc_of bash "$ROUTE" write local "$R/.claude/rules/nope.md")"
ERR="$(bash "$ROUTE" write local "$R/.claude/rules/nope.md" 2>&1 >/dev/null)"
has "missing-file-refusal-names-the-node" "task-flow rule node" "$ERR"
eq "no-file-was-created-by-a-refused-write" "task-flow.local.md" "$(ls -A "$R/.claude/rules")"

# --- the route texts: record lines are the forms merge.sh accepts, and the commands keep them literal ---
# The routes are /run references read from the plugin (skills/run/references/route-<host>.md). Outside
# GitHub nothing refuses a malformed record, so the lines the routes teach are held to the forms merge.sh
# matches. Those forms are restated below with the merge.sh lines they come from; the guard right after
# fails when merge.sh changes one, so this list cannot drift silently. merge.sh is not modified here.
MERGE="$PLUGIN/scripts/merge.sh"
for frag in \
  'def verdict: test("^cc-tuner-verdict: (APPROVE|REQUEST_CHANGES) " + $sha + "$");' \
  'def accepted: $mode == "none" and test("^cc-tuner-accepted: " + $sha + " \\S");' \
  'test("^cc-tuner-verified: [0-9a-f]{40}( |$)")' \
  "grep -E '\\[(browser|api|test|cli)\\]|NOT PROVED'" \
  'test("^cc-tuner-local-ci: " + $sha + " \\S.*$")'; do
  if grep -qF -- "$frag" "$MERGE"; then pass "merge-sh-still-has-the-form"; else fail "merge-sh-still-has-the-form" "$frag"; fi
done
SHA=0123456789abcdef0123456789abcdef01234567
for host in gitlab local; do
  REFFILE="$PLUGIN/skills/run/references/route-$host.md"
  [ -f "$REFFILE" ] || { fail "route-reference-$host-exists" "$REFFILE"; continue; }
  # the record templates: the lines of the first fenced block that start with cc-tuner-
  TEMPLATES="$(sed -n '/^```text$/,/^```$/p' "$REFFILE" | grep '^cc-tuner-')"
  eq "route-$host-teaches-four-records" 4 "$(printf '%s\n' "$TEMPLATES" | grep -c '')"
  FILLED="$(printf '%s\n' "$TEMPLATES" | sed -e 's/<APPROVE|REQUEST_CHANGES>/APPROVE/' -e "s/<full sha>/$SHA/g" -e "s/<head sha>/$SHA/g" \
    -e 's/<command and result>/make test: 41 passed/' -e 's/<who>: <what>/Vlad: accepted the open nit/')"
  lacks "route-$host-templates-have-no-placeholder-left" "<" "$FILLED"
  while IFS= read -r line; do
    case "$line" in
      cc-tuner-verdict:*)  [[ "$line" =~ ^cc-tuner-verdict:\ (APPROVE|REQUEST_CHANGES)\ $SHA$ ]] && pass "route-$host-verdict-form" || fail "route-$host-verdict-form" "$line" ;;
      cc-tuner-verified:*) [[ "$line" =~ ^cc-tuner-verified:\ [0-9a-f]{40}(\ |$) ]]               && pass "route-$host-verified-form" || fail "route-$host-verified-form" "$line" ;;
      cc-tuner-local-ci:*) [[ "$line" =~ ^cc-tuner-local-ci:\ $SHA\ [^[:space:]] ]]               && pass "route-$host-local-ci-form" || fail "route-$host-local-ci-form" "$line" ;;
      cc-tuner-accepted:*) [[ "$line" =~ ^cc-tuner-accepted:\ $SHA\ [^[:space:]] ]]               && pass "route-$host-accepted-form" || fail "route-$host-accepted-form" "$line" ;;
      *) fail "route-$host-unknown-record-line" "$line" ;;
    esac
  done <<EOF
$FILLED
EOF
  for tag in '[browser]' '[api]' '[test]' '[cli]' 'NOT PROVED'; do
    has "route-$host-names-criterion-tag" "$tag" "$(cat "$REFFILE")"
  done
done

# gitlab: the publish command, extracted from the reference and run against a stub glab, passes a hostile
# record through as one literal argument and runs nothing in it
HOSTILE='criterion `touch pwned` and $(touch pwned2) and "quotes"'
mkdir -p "$T/bin" "$T/work"
printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done > "%s/glab-argv"\n' "$T" > "$T/bin/glab"; chmod +x "$T/bin/glab"
printf 'cc-tuner-verified: %s\n[test] %s\n' "$SHA" "$HOSTILE" > "$T/rec"
CMD="$(grep -m1 '^glab mr note create' "$PLUGIN/skills/run/references/route-gitlab.md" | sed 's/<iid>/7/')"
has "route-gitlab-publish-command-found" "--message" "$CMD"
( cd "$T/work" && PATH="$T/bin:$PATH" REC="$T/rec" bash -c "$CMD" )
eq "route-gitlab-publish-passes-the-record-literally" "$(cat "$T/rec")" "$(tail -n 2 "$T/glab-argv")"
eq "route-gitlab-publish-runs-nothing-in-the-record" "" "$(ls "$T/work")"
eq "route-gitlab-publish-has-no-resolvable-thread" 1 "$(grep -c '^--resolvable=false$' "$T/glab-argv")"

# local: the append command from the reference, run twice, leaves two paragraphs in one note; the lookup
# from the reference finds the records on the commits the candidate adds, and the hostile text stays text
rm -rf "$T/lrepo"; mkdir -p "$T/lrepo"
# A repo-local identity, as tests/flow/lib.sh sets one: `git notes append` writes a commit, and a CI runner
# with no global identity and no guessable email refuses it, which macOS hosts hide by guessing one.
( cd "$T/lrepo" && git init -q -b main && git config user.name t && git config user.email t@t \
  && git commit -q --allow-empty -m base && git switch -q -c feature && git commit -q --allow-empty -m work )
HEAD_SHA="$(git -C "$T/lrepo" rev-parse HEAD)"
APPEND="$(grep -m1 '^git notes --ref cc-tuner append' "$PLUGIN/skills/run/references/route-local.md" | sed "s/<judged sha>/$HEAD_SHA/")"
has "route-local-append-command-found" "append -F" "$APPEND"
printf 'cc-tuner-verdict: REQUEST_CHANGES %s\n' "$HEAD_SHA" > "$T/rec1"
printf 'cc-tuner-verdict: APPROVE %s\n%s\n' "$HEAD_SHA" "$HOSTILE" > "$T/rec2"
( cd "$T/lrepo" && GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t REC="$T/rec1" bash -c "$APPEND" && GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t REC="$T/rec2" bash -c "$APPEND" )
eq "route-local-append-keeps-the-record-literally" "$(cat "$T/rec2")" "$(git -C "$T/lrepo" notes --ref cc-tuner show "$HEAD_SHA" | tail -n 2)"
eq "route-local-append-runs-nothing-in-the-record" "" "$(ls "$T/lrepo")"
eq "route-local-two-appends-are-two-paragraphs" 1 "$(git -C "$T/lrepo" notes --ref cc-tuner show "$HEAD_SHA" | grep -c '^$')"
LOOKUP="$(sed -n 's/.*`\(git log --notes=cc-tuner[^`]*\)`.*/\1/p' "$PLUGIN/skills/run/references/route-local.md" | head -n 1 | sed 's/<target>\.\.<candidate>/main..feature/')"
has "route-local-lookup-command-found" "--notes=cc-tuner" "$LOOKUP"
LOOKED="$( cd "$T/lrepo" && eval "$LOOKUP" )"
has "route-local-lookup-finds-the-head-commit" "$HEAD_SHA" "$LOOKED"
has "route-local-lookup-finds-the-last-record" "cc-tuner-verdict: APPROVE $HEAD_SHA" "$LOOKED"
# the last matching paragraph wins: read the note the way the reference says
LAST="$(git -C "$T/lrepo" notes --ref cc-tuner show "$HEAD_SHA" | sed -n '/^$/,$p' | sed -n '2p')"
eq "route-local-last-paragraph-wins" "cc-tuner-verdict: APPROVE $HEAD_SHA" "$LAST"

# --- the Plugin root block in setup/SKILL.md: the fallback that replaced `find ... | sort | tail -1` -----
# Extract the block from the skill and run it with a stub `claude plugin list --json`, so what the setup
# references really execute is what is tested. The stub lists a fork, a disabled install, another
# project's install and a user install, in an order where the last path sorts after the right one.
SNIPPET="$(sed -n '/^## Plugin root$/,/^## The nodes$/p' "$PLUGIN/skills/setup/SKILL.md" | sed -n '/^```bash$/,/^```$/p' | sed '1d;$d')"
[ -n "$SNIPPET" ] && pass "plugin-root-block-found" || fail "plugin-root-block-found"
PR_REPO="$T/pr-repo"; mkdir -p "$PR_REPO/sub" "$T/inst/user" "$T/inst/project" "$T/inst/local" "$T/inst/other" "$T/inst/fork" "$T/inst/off" "$T/inst/env"
( cd "$PR_REPO" && git init -q -b main )
PR_REAL="$(cd "$PR_REPO" && pwd -P)"
mkdir -p "$T/prbin"
plugin_list() { # plugin_list <json with __REPO__ and __T__>
  printf '#!/bin/sh\ncat <<%s\n' "'PL_EOF'" > "$T/prbin/claude"
  printf '%s\n' "$1" | sed -e "s|__REPO__|$PR_REAL|g" -e "s|__T__|$T|g" >> "$T/prbin/claude"
  printf 'PL_EOF\n' >> "$T/prbin/claude"; chmod +x "$T/prbin/claude"
}
resolve() { # resolve [env assignment]: prints $PLUGIN as the block leaves it, from inside the repo
  ( cd "$PR_REPO/sub" && env -u CLAUDE_PLUGIN_ROOT "$@" PATH="$T/prbin:$PATH" bash -c "$SNIPPET"'; printf "%s" "$PLUGIN"' 2>&1 )
}
plugin_list '[
 {"id":"cc-tuner@cc-tuner","scope":"user","enabled":true,"installPath":"__T__/inst/user"},
 {"id":"cc-tuner@zzz-fork","scope":"user","enabled":true,"installPath":"__T__/inst/fork"},
 {"id":"cc-tuner@cc-tuner","scope":"project","projectPath":"/somewhere/else","enabled":true,"installPath":"__T__/inst/other"},
 {"id":"cc-tuner@cc-tuner","scope":"project","projectPath":"__REPO__","enabled":false,"installPath":"__T__/inst/off"}
]'
eq "plugin-root-user-install-beats-a-fork-a-foreign-project-and-a-disabled-one" "$T/inst/user" "$(resolve A=1)"
plugin_list '[
 {"id":"cc-tuner@cc-tuner","scope":"user","enabled":true,"installPath":"__T__/inst/user"},
 {"id":"cc-tuner@cc-tuner","scope":"project","projectPath":"__REPO__","enabled":true,"installPath":"__T__/inst/project"}
]'
eq "plugin-root-project-beats-user" "$T/inst/project" "$(resolve A=1)"
plugin_list '[
 {"id":"cc-tuner@cc-tuner","scope":"project","projectPath":"__REPO__","enabled":true,"installPath":"__T__/inst/project"},
 {"id":"cc-tuner@cc-tuner","scope":"local","projectPath":"__REPO__","enabled":true,"installPath":"__T__/inst/local"},
 {"id":"cc-tuner@cc-tuner","scope":"user","enabled":true,"installPath":"__T__/inst/user"}
]'
eq "plugin-root-local-beats-project-beats-user" "$T/inst/local" "$(resolve A=1)"
ln -s "$PR_REPO" "$T/pr-link"
plugin_list '[
 {"id":"cc-tuner@cc-tuner","scope":"user","enabled":true,"installPath":"__T__/inst/user"},
 {"id":"cc-tuner@cc-tuner","scope":"project","projectPath":"__T__/pr-link","enabled":true,"installPath":"__T__/inst/project"}
]'
eq "plugin-root-project-recorded-through-a-symlink-still-applies" "$T/inst/project" "$(resolve A=1)"
eq "plugin-root-keeps-the-env-when-it-is-a-directory" "$T/inst/env" "$(resolve CLAUDE_PLUGIN_ROOT="$T/inst/env")"
plugin_list '[{"id":"cc-tuner@cc-tuner","scope":"user","enabled":false,"installPath":"__T__/inst/user"}]'
OUT="$(resolve A=1)"
has "plugin-root-none-applicable-is-an-error" "Could not locate the cc-tuner plugin" "$OUT"

# A block or the legacy header on line 1 made write call `head -n 0`, which BSD head rejects on stderr
# ("illegal line count -- 0") while GNU head accepts it, so only macOS showed the noise.
LINE1="$(mktemp -d "${TMPDIR:-/tmp}/cc-tuner-line1.XXXXXX")"
bash "$ROUTE" canonical local > "$LINE1/block-first.md"
printf '%s\n' "trailing delta" >> "$LINE1/block-first.md"
ERR="$(bash "$ROUTE" write gitlab "$LINE1/block-first.md" 2>&1 >/dev/null)"
eq "write-block-on-line-1-has-no-stderr" "" "$ERR"
printf '%s\n' "<!-- Overrides and additions to task-flow.md live here; setup never touches this file." \
  "     Typical content: board name/number + cached field IDs, label taxonomy, merge-policy exceptions. -->" > "$LINE1/header-first.md"
ERR="$(bash "$ROUTE" write local "$LINE1/header-first.md" 2>&1 >/dev/null)"
eq "write-legacy-header-on-line-1-has-no-stderr" "" "$ERR"
lacks "legacy-header-on-line-1-replaced" "setup never touches this file" "$(cat "$LINE1/header-first.md")"
rm -rf "$LINE1"

exit $fails
