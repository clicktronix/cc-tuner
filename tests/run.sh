#!/usr/bin/env bash
# Repository validation for cc-tuner. Runs the plugin's bash suites and the manifest invariants that
# a released plugin has to hold. bash 3.2 compatible on purpose: the smoke-verify gate claims macOS
# support, so its own CI must run on the same shell macOS ships.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN="$ROOT/plugins/cc-tuner"
fails=0

say() { printf '%s\n' "$1"; }
ok() { say "ok   $1"; }
bad() { say "FAIL $1"; fails=1; }

command -v jq >/dev/null 2>&1 || { say "FATAL: jq is required"; exit 1; }

# --- 1. bash suites -----------------------------------------------------------------------------
# 412 lines of regression tests shipped in 0.6.0 with nothing running them. That is the gap this
# runner closes; the suites themselves already passed.
suites=0
for t in "$PLUGIN"/tests/*/test_*.sh; do
  [ -f "$t" ] || continue
  suites=$((suites + 1))
  rel="${t#$ROOT/}"
  if out="$(bash "$t" 2>&1)"; then
    ok "$rel"
  else
    bad "$rel"
    printf '%s\n' "$out" | grep -i '^FAIL' | sed 's/^/       /'
  fi
done
[ "$suites" -gt 0 ] || bad "no test suites found under plugins/cc-tuner/tests/"
# Per tier, not just in total. "Some suite exists" stayed true with tests/flow/ emptied, so the tier
# built to observe the product could vanish and the run would still say ok.
for tier in flow contract setup smoke-verify; do
  n=0
  for t in "$PLUGIN"/tests/"$tier"/test_*.sh; do [ -f "$t" ] && n=$((n + 1)); done
  [ "$n" -gt 0 ] || bad "no test suites under plugins/cc-tuner/tests/$tier/"
done

# --- 2. JSON validity ---------------------------------------------------------------------------
json_count=0
for f in "$ROOT"/.claude-plugin/marketplace.json "$PLUGIN"/.claude-plugin/plugin.json \
         "$PLUGIN"/hooks/hooks.json "$ROOT"/release-please-config.json \
         "$PLUGIN"/schemas/*.json "$ROOT"/.release-please-manifest.json "$ROOT"/tests/scenarios/*/*.json; do
  [ -f "$f" ] || continue
  json_count=$((json_count + 1))
  jq empty "$f" >/dev/null 2>&1 || bad "invalid JSON: ${f#$ROOT/}"
done
ok "json parses ($json_count files)"

# --- 3. version consistency ---------------------------------------------------------------------
# The 0.6.0 branch shipped plugin.json at 0.6.0 and marketplace.json at 0.5.1, so /plugin would have
# advertised a version the plugin did not claim. Every version field has to agree.
plugin_v="$(jq -r '.version' "$PLUGIN/.claude-plugin/plugin.json")"
market_meta_v="$(jq -r '.metadata.version' "$ROOT/.claude-plugin/marketplace.json")"
market_plug_v="$(jq -r '.plugins[0].version' "$ROOT/.claude-plugin/marketplace.json")"
if [ "$plugin_v" = "$market_meta_v" ] && [ "$plugin_v" = "$market_plug_v" ]; then
  ok "versions agree ($plugin_v)"
else
  bad "version mismatch: plugin.json=$plugin_v metadata=$market_meta_v plugins[0]=$market_plug_v"
fi

# CHANGELOG has to carry the version being shipped, or the release notes describe something else.
grep -q "^## \[$plugin_v\]" "$ROOT/CHANGELOG.md" \
  && ok "CHANGELOG has a [$plugin_v] section" \
  || bad "CHANGELOG has no [$plugin_v] section"

# --- 4. ${CLAUDE_PLUGIN_ROOT} paths exist -------------------------------------------------------
# A command that points at a script the plugin does not ship fails at the user's first invocation.
missing=0
refs="$(grep -rhoE '\$\{CLAUDE_PLUGIN_ROOT\}/[A-Za-z0-9_./-]+' "$PLUGIN" 2>/dev/null | sort -u)"
for ref in $refs; do
  rel="${ref#\$\{CLAUDE_PLUGIN_ROOT\}/}"
  [ -e "$PLUGIN/$rel" ] || { bad "\${CLAUDE_PLUGIN_ROOT}/$rel does not exist"; missing=$((missing + 1)); }
done
[ "$missing" -eq 0 ] && ok "plugin-root references resolve ($(printf '%s\n' "$refs" | grep -c . ) refs)"

# --- 5. SKILL.md size -------------------------------------------------------------------------
# Claude Code guidance: keep a skill body under 500 lines so activation stays cheap.
for s in "$PLUGIN"/skills/*/SKILL.md; do
  [ -f "$s" ] || continue
  n="$(grep -c '' "$s")"
  [ "$n" -le 500 ] || bad "${s#$ROOT/} is $n lines; keep it <= 500"
done
ok "skill bodies within 500 lines"

# --- 5b. release-please config points at fields that actually exist -----------------------------
# release-please owns the version bump now. If one of its extra-file targets goes stale — a renamed
# path, a restructured manifest — it bumps the others and silently skips that one, which is exactly
# the 0.6.0 failure (plugin.json 0.6.0, marketplace.json 0.5.1) with an automated cause.
RP="$ROOT/release-please-config.json"
if [ -f "$RP" ]; then
  manifest_v="$(jq -r '.["."] // empty' "$ROOT/.release-please-manifest.json" 2>/dev/null)"
  if [ "$manifest_v" = "$plugin_v" ]; then
    ok "release-please manifest agrees ($manifest_v)"
  else
    bad "release-please manifest says '$manifest_v', plugin.json says '$plugin_v'"
  fi
  rp_n=0
  # here-doc, not a pipe: `bad` has to set `fails` in THIS shell, and a pipeline would subshell it.
  while IFS="$(printf '\t')" read -r rp_path rp_jsonpath; do
    [ -n "$rp_path" ] || continue
    rp_n=$((rp_n + 1))
    if [ ! -f "$ROOT/$rp_path" ]; then
      bad "release-please extra-file does not exist: $rp_path"
      continue
    fi
    # The jsonpath forms used here ($.a.b, $.a[0].b) are also valid jq paths once `$` is dropped.
    # A fancier JSONPath would make jq error out — loudly, which is the point.
    got="$(jq -r "${rp_jsonpath#\$}" "$ROOT/$rp_path" 2>/dev/null)"
    if [ "$got" = "$plugin_v" ]; then :; else
      bad "release-please $rp_path $rp_jsonpath resolves to '$got', expected '$plugin_v'"
    fi
  done <<RPEOF
$(jq -r '.packages["."]["extra-files"][] | select(.type == "json") | [.path, .jsonpath] | @tsv' "$RP")
RPEOF
  [ "$rp_n" -gt 0 ] && ok "release-please version targets resolve ($rp_n fields)" \
                    || bad "release-please config declares no json extra-files"
fi

# --- 5c. no live references to removed surfaces --------------------------------------------------
# The spec/run split deleted three commands and a skill. Nothing failed when a shipped file still
# named one — the dangling-reference checks cover ${CLAUDE_PLUGIN_ROOT} paths, markdown links and
# scenario anchors, but not prose that tells a user to run a command that no longer exists.
# CHANGELOG and docs/superpowers/ are history and are meant to keep the old names.
# A line that says the thing was replaced/removed/old is documenting history, which is wanted; an
# unqualified mention is an instruction to run something that no longer exists. Only the latter fails.
# This found config-init.sh telling users to "re-run /cc-tuner:execute-task" the first time it ran.
removed_hits=0
for pat in '/cc-tuner:execute-task' '/cc-tuner:delegate' 'assets/delegate' 'skills/smoke-verify/'; do
  for f in $(grep -rlF "$pat" "$PLUGIN" "$ROOT/README.md" 2>/dev/null || true); do
    if grep -F "$pat" "$f" | grep -qvE 'replace|removed|old |superseded|predates|no longer'; then
      bad "${f#$ROOT/} still instructs the use of '$pat' (removed)"
      removed_hits=$((removed_hits + 1))
    fi
  done
done
[ "$removed_hits" -eq 0 ] && ok "no references to removed commands or skills"

# Current user-facing entry points must not advertise the deleted standalone planning command.
# Historical plans, changelog entries and eval transcripts keep the name as evidence and are not
# searched here.
if grep -F '/cc-tuner:plan' "$ROOT/README.md" "$ROOT/.claude-plugin/marketplace.json" \
     "$PLUGIN/README.md" "$PLUGIN/.claude-plugin/plugin.json" >/dev/null 2>&1; then
  bad "a current README or manifest still advertises removed /cc-tuner:plan"
else
  ok "current READMEs and manifests omit removed /cc-tuner:plan"
fi

# --- 6. scenario provenance is internally consistent --------------------------------------------
# The git-flow -> task-flow rename left two scenarios referencing a path that no longer existed, and
# nothing failed. tests_reference is the scenario's claim about what it tests; a dangling one means
# the recorded RED/GREEN evidence describes a file nobody can read.
dangling=0
scen=0
for f in "$ROOT"/tests/scenarios/*/*.json; do
  [ -f "$f" ] || continue
  scen=$((scen + 1))
  ref="$(jq -r '.tests_reference // empty' "$f")"
  [ -n "$ref" ] || { bad "${f#$ROOT/} has no tests_reference"; dangling=$((dangling + 1)); continue; }
  path="${ref%%#*}"
  removed_ref=no
  jq -e --arg p "$path" '(.removed_targets // []) | index($p) != null' "$f" >/dev/null 2>&1 \
    && removed_ref=yes
  if [ ! -e "$ROOT/$path" ] && [ "$removed_ref" = no ]; then
    bad "${f#$ROOT/} references missing $path without recording it in removed_targets"
    dangling=$((dangling + 1))
    continue
  fi
  case "$path" in
    plugins/cc-tuner/skills/*)
      owner="${path#plugins/cc-tuner/skills/}"; owner="${owner%%/*}"
      jq -e --arg owner "$owner" '(.skills // []) | index($owner) != null' "$f" >/dev/null 2>&1 \
        || { bad "${f#$ROOT/} tests $owner but its skills list does not name that owner"; dangling=$((dangling + 1)); }
      ;;
  esac
  if jq -e '(.measured_targets // null) | type == "object"' "$f" >/dev/null 2>&1; then
    jq -e --arg p "$path" '.measured_targets | has($p)' "$f" >/dev/null 2>&1 \
      || { bad "${f#$ROOT/} tests $path but measured_targets does not contain it"; dangling=$((dangling + 1)); }
    jq -e '
      ([.skills[]?] | sort) ==
      ([.measured_targets | keys[]
        | select(startswith("plugins/cc-tuner/skills/"))
        | split("/")[3]] | unique | sort)
    ' "$f" >/dev/null 2>&1 \
      || { bad "${f#$ROOT/} skills and measured_targets name different skill owners"; dangling=$((dangling + 1)); }
  fi
  for target in $(jq -r '(.measured_targets // {}) | keys[]' "$f"); do
    if [ ! -e "$ROOT/$target" ] \
      && ! jq -e --arg p "$target" '(.removed_targets // []) | index($p) != null' "$f" >/dev/null 2>&1; then
      bad "${f#$ROOT/} measured missing $target without recording it in removed_targets"
      dangling=$((dangling + 1))
    fi
  done
  for target in $(jq -r '.removed_targets[]?' "$f"); do
    jq -e --arg p "$target" '(.measured_targets // {}) | has($p)' "$f" >/dev/null 2>&1 \
      || { bad "${f#$ROOT/} marks $target removed but did not measure it"; dangling=$((dangling + 1)); }
    [ ! -e "$ROOT/$target" ] \
      || { bad "${f#$ROOT/} marks $target removed but it still exists"; dangling=$((dangling + 1)); }
  done
  # A `path#anchor` reference also has to name a heading that is still there — a renamed section is
  # the same dangling-pointer failure as a renamed file, just quieter.
  case "$ref" in
    *"#"*)
      [ -e "$ROOT/$path" ] || continue
      anchor="${ref#*#}"
      grep '^#\{1,6\} ' "$ROOT/$path" \
        | sed -e 's/^#* //' -e 's/[^A-Za-z0-9 -]//g' -e 's/ /-/g' \
        | tr 'A-Z' 'a-z' | grep -qx "$anchor" \
        || { bad "${f#$ROOT/} references missing anchor #$anchor in $path"; dangling=$((dangling + 1)); }
      ;;
  esac
done
[ "$dangling" -eq 0 ] && ok "scenario provenance is consistent ($scen scenarios)"

# --- 6a2. the ADR may not claim "accepted" while the shipped tree is past the evaluated one --------
# Task 8 step 0 exists so the eval exercises the artifact that ships. Prose cannot hold that: run 3
# was recorded against cd9fa2f and two skill files then changed; run 3b against e39419c and
# plan-path.sh then changed. Both times the claim survived the change until a reviewer caught it, and
# both times the reply was an argument about which tier covered the difference. So the claim is now a
# comparison: production surface at the evaluated SHA versus the working tree. Editing a skill is
# fine -- it just means the ADR says "proposed" until the eval has seen it.
EVAL_SHA_FILE="$ROOT/plugins/cc-tuner/tests/eval/EVALUATED_SHA"
ADR="$ROOT/docs/adr/2026-08-13-native-first-lifecycle.md"
# Fail closed on its own inputs. An earlier revision wrapped the whole check in `if [ -f A ] && [ -f B ]`
# with no else, so deleting or renaming either file turned the guard off and the suite stayed green --
# a guard whose disappearance is indistinguishable from its success.
[ -f "$EVAL_SHA_FILE" ] || bad "plugins/cc-tuner/tests/eval/EVALUATED_SHA is missing — the check that the eval saw the shipped tree cannot run without it"
[ -f "$ADR" ] || bad "docs/adr/2026-08-13-native-first-lifecycle.md is missing — its status is what the EVALUATED_SHA check reads"
if [ -f "$EVAL_SHA_FILE" ] && [ -f "$ADR" ]; then
  eval_sha="$(grep -v "^#" "$EVAL_SHA_FILE" | tr -d "[:space:]")"
  adr_status="$(sed -n "s/^\*\*Status:\*\* *\([A-Za-z]*\).*/\1/p" "$ADR" | head -1 | tr "[:upper:]" "[:lower:]")"
  # A status this cannot read must fail, not quietly disable the two rules that read it. The earlier
  # pattern matched `[a-z]*`, so "**Status:** Accepted" -- or a missing line -- produced an empty string
  # that compared unequal to "accepted" and let both a moved tree and an unstable probe through. A guard
  # keyed on a value it failed to parse is worse than no guard: it reports ok.
  case "$adr_status" in
    accepted|proposed) ;;
    *) bad "cannot read the ADR's status (got '${adr_status:-<none>}') — it must be a line reading '**Status:** accepted' or '**Status:** proposed', because two checks here are keyed on it" ;;
  esac
  if ! git -C "$ROOT" cat-file -e "$eval_sha^{commit}" 2>/dev/null; then
    bad "EVALUATED_SHA names $eval_sha, which is not a commit here"
  elif git -C "$ROOT" diff --quiet "$eval_sha" -- \
         plugins/cc-tuner/skills plugins/cc-tuner/scripts plugins/cc-tuner/hooks \
         plugins/cc-tuner/assets plugins/cc-tuner/references \
         plugins/cc-tuner/.claude-plugin 2>/dev/null; then
    ok "the eval ran against the production surface that ships (${eval_sha%${eval_sha#???????}})"
  elif [ "$adr_status" = "accepted" ]; then
    bad "the ADR says accepted, but the production surface has moved since the evaluated commit ${eval_sha%${eval_sha#???????}} — re-run the eval and update EVALUATED_SHA, or set the ADR back to proposed"
  else
    ok "production surface has moved since the eval, and the ADR says '$adr_status' rather than accepted"
  fi
fi

# --- 7. relative markdown links resolve --------------------------------------------------------
broken=0
for f in $(find "$PLUGIN" "$ROOT/docs" -maxdepth 99 -name '*.md' 2>/dev/null; find "$ROOT" -maxdepth 1 -name '*.md'); do
  targets="$(grep -oE '\]\([^)#[:space:]]+\.md' "$f" 2>/dev/null | sed 's/^](//')"
  for target in $targets; do
    case "$target" in http*|\$*) continue ;; esac
    [ -e "$(dirname "$f")/$target" ] || { bad "${f#$ROOT/} links missing $target"; broken=$((broken + 1)); }
  done
done
[ "$broken" -eq 0 ] && ok "markdown links resolve"

# ------------------------------------------------------------------------------------------------
if [ "$fails" -eq 0 ]; then
  say "cc-tuner validate ok"
else
  say "cc-tuner validate FAILED"
fi
exit $fails
