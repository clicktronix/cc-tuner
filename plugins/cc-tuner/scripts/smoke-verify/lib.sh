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

# First match wins; value may contain '='. CRs are stripped so a CRLF-saved
# config doesn't silently produce a never-matching pattern.
smoke_cfg_get() { # $1=key
  sed -n "s/^$1=//p" "$SMOKE_CFG" 2>/dev/null | head -1 | tr -d '\r'
}

# Path from a porcelain line: strip the 3-char "XY " prefix; renames keep the
# destination side (the side that exists in the worktree). Git C-quotes paths
# with specials ("My Comp.tsx") — surrounding quotes are stripped so `patterns`
# anchors like \.tsx$ still match; inner escape sequences are left as-is
# (stable across runs, which is all the fingerprint needs — a path whose
# escapes don't resolve simply contributes no content bytes, identically in
# both callers).
smoke_line_path() { # $1=porcelain line
  local p="${1:3}"
  case "$p" in *" -> "*) p="${p##* -> }";; esac
  case "$p" in
    \"*\") p="${p#\"}"; p="${p%\"}";;
  esac
  printf '%s' "$p"
}

# Repo-relative paths (one per line) of changed files — staged, unstaged, and
# untracked — whose PATH matches the config's ERE. Matching is against the
# extracted path, not the raw porcelain line, so ^ anchors work (`(^|/)app/`
# matches a top-level app/ dir). The gate's own state dir never triggers it.
smoke_matched_paths() { # $1=patterns-ERE
  git status --porcelain -uall 2>/dev/null \
    | grep -vF "$SMOKE_STATE_DIR/" \
    | grep -vF "$SMOKE_CFG" \
    | while IFS= read -r _line; do
        [ -z "$_line" ] && continue
        _p="$(smoke_line_path "$_line")"
        printf '%s' "$_p" | grep -qE -- "$1" && printf '%s\n' "$_p"
      done
}

# Fingerprint of the matched frontend delta: the sorted path list plus each
# path's WORKTREE content (deleted files contribute a marker). Deliberately
# independent of index state — verification covers what runs, i.e. the
# worktree, so `git add` after attesting must NOT re-arm the gate; editing a
# file (content change) must and does.
smoke_fingerprint() { # $1=patterns-ERE
  local paths p
  paths="$(smoke_matched_paths "$1" | LC_ALL=C sort)"
  {
    printf '%s\n' "$paths"
    printf '%s\n' "$paths" | while IFS= read -r p; do
      [ -z "$p" ] && continue
      if [ -e "$p" ]; then cat -- "$p" 2>/dev/null; else printf 'DELETED:%s\n' "$p"; fi
    done
  } | smoke_sha
}

smoke_state_get() { # $1=key
  sed -n "s/^$1=//p" "$SMOKE_STATE" 2>/dev/null | head -1
}
