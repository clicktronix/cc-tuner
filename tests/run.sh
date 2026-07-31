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

# --- 2. JSON validity ---------------------------------------------------------------------------
json_count=0
for f in "$ROOT"/.claude-plugin/marketplace.json "$PLUGIN"/.claude-plugin/plugin.json \
         "$PLUGIN"/hooks/hooks.json "$ROOT"/release-please-config.json \
         "$ROOT"/.release-please-manifest.json "$ROOT"/tests/scenarios/*/*.json; do
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
