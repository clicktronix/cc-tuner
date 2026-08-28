#!/usr/bin/env bash
# Execute the shell oracles exactly as shipped in claude-md-writer/audit.md.
set -u

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
AUDIT="$ROOT/plugins/cc-tuner/skills/claude-md-writer/audit.md"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

block() {
  marker="$1"
  awk -v marker="$marker" '
    /^```bash$/ { inside = 1; wanted = 0; body = ""; next }
    inside && /^```$/ {
      if (wanted) printf "%s", body
      inside = 0; wanted = 0; body = ""
      next
    }
    inside {
      body = body $0 ORS
      if ($0 == marker) wanted = 1
    }
  ' "$AUDIT"
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cc-tuner-claude-md.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT INT TERM

# The last section used to print only "to EOF", so the largest trailing block had no size.
mkdir -p "$TMP/sections"
cat > "$TMP/sections/AGENTS.md" <<'EOF'
intro
## First
one
## Last
one
two
EOF
sections="$(cd "$TMP/sections" && TARGET=AGENTS.md bash -c "$(block '# audit-section-sizes')")"
if printf '%s\n' "$sections" | grep -qF '2:## First -> 2' \
  && printf '%s\n' "$sections" | grep -qF '4:## Last -> 3'; then
  ok "section sizes include the final section"
else
  bad "section sizes include the final section (got: $sections)"
fi

# A regex search treated foo.bar as matching fooxbar and invented a duplicate owner.
mkdir -p "$TMP/identifiers/.claude/rules/nested"
printf '%s\n' 'foo.bar' > "$TMP/identifiers/AGENTS.md"
printf '%s\n' 'fooxbar' > "$TMP/identifiers/.claude/rules/false.md"
printf '%s\n' 'foo.bar' > "$TMP/identifiers/.claude/rules/nested/exact.md"
identifiers="$(cd "$TMP/identifiers" && TARGET=AGENTS.md IDS=foo.bar bash -c "$(block '# audit-literal-identifiers')")"
if printf '%s\n' "$identifiers" | grep -qF '.claude/rules/nested/exact.md' \
  && ! printf '%s\n' "$identifiers" | grep -qF '.claude/rules/false.md'; then
  ok "identifier search is literal"
else
  bad "identifier search is literal (got: $identifiers)"
fi

# The owner parser must accept both shell assignment forms and avoid shared /tmp files.
mkdir -p "$TMP/owned-list"
cat > "$TMP/owned-list/AGENTS.md" <<'EOF'
## Environment
- `API_URL`
- `DB_HOST`
EOF
cat > "$TMP/owned-list/.env.example" <<'EOF'
API_URL=https://example.test
export DB_HOST=localhost
EOF
if (cd "$TMP/owned-list" && TARGET=AGENTS.md FROM=1 TO=3 bash -c "$(block '# audit-owned-list')") >/dev/null; then
  ok "owned-list comparison accepts export assignments"
else
  bad "owned-list comparison accepts export assignments"
fi

missing_owner="$(cd "$TMP/owned-list" && TARGET=AGENTS.md FROM=1 TO=3 OWNER=missing.env \
  bash -c "$(block '# audit-owned-list')" 2>&1)"
if printf '%s\n' "$missing_owner" | grep -qF 'SKIP: owner does not exist: missing.env'; then
  ok "missing owner is explicit"
else
  bad "missing owner is explicit (got: $missing_owner)"
fi

# Codex reads every project instruction from repository root to cwd, preferring an override at a level.
mkdir -p "$TMP/ancestors/a/b"
git -C "$TMP/ancestors" init -q
printf 'root\n' > "$TMP/ancestors/AGENTS.md"
printf 'parent\n' > "$TMP/ancestors/a/AGENTS.md"
printf 'ignored\n' > "$TMP/ancestors/a/b/AGENTS.md"
printf 'override\n' > "$TMP/ancestors/a/b/AGENTS.override.md"
ancestors="$(cd "$TMP/ancestors/a/b" && /bin/bash -uc "$(block '# audit-ancestor-chain')")"
root_line="$(printf '%s\n' "$ancestors" | grep -nF "$TMP/ancestors/AGENTS.md" | cut -d: -f1)"
parent_line="$(printf '%s\n' "$ancestors" | grep -nF "$TMP/ancestors/a/AGENTS.md" | cut -d: -f1)"
override_line="$(printf '%s\n' "$ancestors" | grep -nF "$TMP/ancestors/a/b/AGENTS.override.md" | cut -d: -f1)"
if [ -n "$root_line" ] && [ -n "$parent_line" ] && [ -n "$override_line" ] \
  && [ "$root_line" -lt "$parent_line" ] && [ "$parent_line" -lt "$override_line" ] \
  && ! printf '%s\n' "$ancestors" | grep -qF "$TMP/ancestors/a/b/AGENTS.md"; then
  ok "ancestor diagnostic follows load order and override precedence"
else
  bad "ancestor diagnostic follows load order and override precedence (got: $ancestors)"
fi

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
