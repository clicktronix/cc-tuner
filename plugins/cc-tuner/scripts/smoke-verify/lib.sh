# cc-tuner smoke-verify — shared helpers, sourced by the Stop hook AND mark.sh.
#
# The single hard invariant here: the hook and mark.sh MUST compute the
# fingerprint identically, or an attestation could never match and the gate
# would loop to its cap on every turn. That is why this logic lives in one
# file both callers source, not in two copies.
#
# Portability: macOS bash 3.2 + Linux. No jq, no python.

SMOKE_CFG=".claude/smoke-verify.cfg"
SMOKE_STATE_DIR=".claude/smoke-verify"
SMOKE_STATE="$SMOKE_STATE_DIR/state"
SMOKE_BLOCKS="$SMOKE_STATE_DIR/blocks"

# sha256 with a portable fallback (shasum ships on macOS, sha256sum on Linux).
smoke_sha() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d' ' -f1
  else sha256sum | cut -d' ' -f1; fi
}

smoke_cfg_get() { # $1=key — first match wins; value may contain '='.
  sed -n "s/^$1=//p" "$SMOKE_CFG" 2>/dev/null | head -1
}

# Changed files (staged + unstaged + untracked) whose path matches the
# config's ERE, one porcelain line per file. Renames match on either side;
# the gate's own state dir is never a trigger.
smoke_matched_lines() { # $1=patterns-ERE
  git status --porcelain -uall 2>/dev/null \
    | grep -vF "$SMOKE_STATE_DIR/" \
    | grep -vF "$SMOKE_CFG" \
    | grep -E -- "$1"
}

# Path from a porcelain line: strip the 3-char "XY " prefix; renames keep the
# destination side. Git's own quoting of exotic paths is left as-is — it is
# stable across runs, which is all the fingerprint needs.
smoke_line_path() { # $1=porcelain line
  local p="${1:3}"
  case "$p" in *" -> "*) p="${p##* -> }";; esac
  printf '%s' "$p"
}

# Fingerprint of the matched frontend delta: the sorted porcelain lines plus
# the actual content delta (tracked files via git diff HEAD, untracked via
# file content). Content is included so "verified, then edited again" re-arms
# the gate, while a no-op turn (same delta) stays released.
smoke_fingerprint() { # $1=patterns-ERE
  local lines line p
  lines="$(smoke_matched_lines "$1" | LC_ALL=C sort)"
  {
    printf '%s\n' "$lines"
    printf '%s\n' "$lines" | while IFS= read -r line; do
      [ -z "$line" ] && continue
      p="$(smoke_line_path "$line")"
      case "$line" in
        '??'*) cat -- "$p" 2>/dev/null ;;
        # `diff HEAD` covers both index and worktree deltas in one pass.
        *)     git diff HEAD -- "$p" 2>/dev/null ;;
      esac
    done
  } | smoke_sha
}

smoke_state_get() { # $1=key
  sed -n "s/^$1=//p" "$SMOKE_STATE" 2>/dev/null | head -1
}
