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

# sha256, portable between macOS (shasum) and the Linux runners in CI (sha256sum). Prints the digest
# alone -- both tools append the filename, and a digest carrying a path would differ between checkouts.
sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d" " -f1
  else sha256sum "$1" | cut -d" " -f1; fi
}

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
         "$PLUGIN"/hooks/hooks.json "$PLUGIN"/workflow-contract.json "$ROOT"/release-please-config.json \
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
for pat in '/cc-tuner:execute-task' '/cc-tuner:delegate' 'assets/delegate' 'skills/smoke-verify'; do
  for f in $(grep -rlF "$pat" "$PLUGIN" "$ROOT/README.md" 2>/dev/null || true); do
    if grep -F "$pat" "$f" | grep -qvE 'replace|removed|old |superseded|predates|no longer'; then
      bad "${f#$ROOT/} still instructs the use of '$pat' (removed)"
      removed_hits=$((removed_hits + 1))
    fi
  done
done
[ "$removed_hits" -eq 0 ] && ok "no references to removed commands or skills"

# --- 6. eval scenarios point at files that exist ------------------------------------------------
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
  [ -e "$ROOT/$path" ] || { bad "${f#$ROOT/} references missing $path"; dangling=$((dangling + 1)); continue; }
  # A `path#anchor` reference also has to name a heading that is still there — a renamed section is
  # the same dangling-pointer failure as a renamed file, just quieter.
  case "$ref" in
    *"#"*)
      anchor="${ref#*#}"
      grep '^#\{1,6\} ' "$ROOT/$path" \
        | sed -e 's/^#* //' -e 's/[^A-Za-z0-9 -]//g' -e 's/ /-/g' \
        | tr 'A-Z' 'a-z' | grep -qx "$anchor" \
        || { bad "${f#$ROOT/} references missing anchor #$anchor in $path"; dangling=$((dangling + 1)); }
      ;;
  esac
done
[ "$dangling" -eq 0 ] && ok "scenario tests_reference paths resolve ($scen scenarios)"

# --- 6b. the lifecycle rewrite has recorded model evidence ------------------------------------
# These scenarios originally shipped as `not run`, contradicting their own RED→GREEN rule. The
# validator cannot prove that an external model call happened, but it can prevent an unmeasured row
# (or an empty/failed GREEN arm) from silently replacing the reviewed evidence in source control.
#
# `measured_against` is required because a recorded pass says nothing without the text it was measured
# against. Every one of these GREENs was once taken on 2026-08-10 against `commands/run.md` — a file
# this branch then deleted. A date alone does not make that visible; naming the subject does.
#
# But prose cannot enforce it, and a review pointed out that this check accepted any non-empty string:
# after the next skill edit the old sentence would keep passing. So `measured_targets` carries the
# sha256 of every file the probe actually loads, and the loop below recomputes them. Edit a skill and
# the scenarios that read it go red until they are re-measured — which is the intended cost, and it is
# small: two haiku calls. On 2026-08-21 a two-line correction to spec/SKILL.md staled two probes and the
# parallel-review fix staled a third, and only one of the three was noticed without this check.
#
# How often a GREEN reproduces is the second half, and it used to be unrecorded. Every one of these was
# taken at n=2, and n=2 cannot see a coin flip. The protocol is now fixed and enforced above: a
# `decision_question` written BEFORE the sample -- one decidable question, not the full expectation
# checklist -- six samples, each outcome recorded including the misses, counts that must match the
# outcomes, and GREEN at >= 5 of 6.
#
# The bar being written first is the load-bearing part. Judged against an unwritten stricter reading
# after the fact, `implementation-only-parallelism` scored 2 of 6; against its written question, 5 of 6,
# and the difference was entirely in the bar. An automated judge fed the whole expectation list as a
# conjunction scored `current-sha-ci` 1 of 6 on six answers that were all correct -- it was measuring
# the rubric's shape. Hence: one question, decided by hand, fixed in the file before the sample runs.
task_run_evidence=0
for name in visible-plan-before-edit dor-first-failing-check false-green-regression-test \
  implementation-only-parallelism request-changes-blocks-merge stale-review-after-fix \
  reviewer-unavailable-fails-closed current-sha-ci sensitive-small-diff-review; do
  file="$ROOT/tests/scenarios/task-run/$name.json"
  if jq -e '
    (.baseline_observed | type == "object") and
    (.baseline_observed.date | type == "string" and length > 0) and
    (.baseline_observed.method | type == "string" and length > 0) and
    (.baseline_observed.verdict | type == "string" and length > 0) and
    (.green_check.measured_against | type == "string" and length > 0) and
    (.green_check.protocol | type == "string" and length > 0) and
    (.decision_question | type == "string" and length > 0) and
    (.green_check.runs | type == "array" and length >= 6) and
    all(.green_check.runs[]; (.pass | type == "boolean") and (.note | type == "string" and length > 0)) and
    (.green_check.reproduction.samples == (.green_check.runs | length)) and
    (.green_check.reproduction.passes == ([.green_check.runs[] | select(.pass)] | length)) and
    (.green_check.verdict == (if .green_check.reproduction.passes * 6 >= .green_check.reproduction.samples * 5
                              then "green" else "unstable" end)) and
    (.green_check.verdict == "green")
  ' "$file" >/dev/null 2>&1; then
    task_run_evidence=$((task_run_evidence + 1))
  else
    bad "tests/scenarios/task-run/$name.json fails the evidence contract: a decision_question and protocol, at least 6 recorded outcomes with notes, counts that match the outcomes, and a verdict of green (>= 5 of 6)"
  fi

  # The target set is derived, never hand-listed: one SKILL.md per entry in `skills`, plus whatever
  # `tests_reference` points at, anchor stripped. **Always that second one**, not only when the path
  # says `references/` -- an earlier revision of this check made that exemption, and it reproduced the
  # very defect it was written after: `visible-plan-before-edit` pointed at `plan/SKILL.md` while its
  # `skills` said only `run`, so the file the scenario is about carried no hash at all and the check
  # went green anyway.
  #
  # The comparison is set equality, not containment. A missing key is an unhashed target; a stale extra
  # key is a target the scenario stopped loading, and leaving those behind turns the record into a list
  # of files that were once relevant.
  targets="$(jq -r '[ (.skills[]? | "plugins/cc-tuner/skills/" + . + "/SKILL.md"),
                      (.tests_reference // "" | sub("#.*"; "") | select(length > 0)) ]
                    | unique | .[]' "$file" 2>/dev/null)"
  jq -e '(.skills | type == "array" and length > 0)' "$file" >/dev/null 2>&1 \
    || bad "tests/scenarios/task-run/$name.json lists no skills, so no target set can be derived"
  # `skills` must also name the skill its `tests_reference` points into. The hash set no longer depends
  # on that -- tests_reference is hashed either way -- but the probe harness reads `skills` to decide
  # what to put in front of the model, so a scenario about `plan` with `skills: ["run"]` is measured
  # without the file it is about. That is the shape this whole check was written after.
  ref_skill="$(jq -r '(.tests_reference // "") | capture("skills/(?<s>[^/]+)/SKILL\\.md") | .s' "$file" 2>/dev/null)"
  if [ -n "$ref_skill" ]; then
    jq -e --arg s "$ref_skill" 'any(.skills[]?; . == $s)' "$file" >/dev/null 2>&1 \
      || bad "tests/scenarios/task-run/$name.json points at the '$ref_skill' skill but does not list it in .skills, so the probe is run without it"
  fi
  recorded="$(jq -r '(.measured_targets // {}) | keys[]?' "$file" 2>/dev/null | sort)"
  derived="$(printf '%s\n' $targets | sort)"
  [ "$recorded" = "$derived" ] \
    || bad "tests/scenarios/task-run/$name.json measured_targets does not match what it loads — recorded [$(printf '%s' "$recorded" | tr '\n' ' ')] derived [$(printf '%s' "$derived" | tr '\n' ' ')]"
  for t in $targets; do
    [ -f "$ROOT/$t" ] || { bad "$name.json names a target that does not exist: $t"; continue; }
    have="$(sha256_of "$ROOT/$t")"
    want="$(jq -r --arg t "$t" '.measured_targets[$t] // ""' "$file")"
    if [ -z "$want" ]; then
      bad "tests/scenarios/task-run/$name.json has no measured_targets entry for $t"
    elif [ "$have" != "$want" ]; then
      bad "tests/scenarios/task-run/$name.json was measured against a different $t — re-measure it, or the recorded pass is about text that no longer exists"
    fi
  done
done
[ "$task_run_evidence" -eq 9 ] && ok "task-run RED/GREEN evidence is recorded ($task_run_evidence scenarios)"

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
