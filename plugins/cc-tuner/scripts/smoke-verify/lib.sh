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

# --- rules ---------------------------------------------------------------
# A repository has more than one kind of change worth exercising, and they are
# not proved the same way: a screen is proved in a browser, a migration by
# running it up and down, an endpoint by a real request. One `patterns=` with
# one hard-coded evidence list could only ever describe one of them, which is
# why the gate shipped frontend-only and stayed there.
#
# So the config carries named rules:
#
#   patterns.<rule>=<ERE over repo-relative paths>
#   counts.<rule>=<what proves THIS kind of change>
#   excludes.<rule>=<what someone will try to pass off as proof here>
#
# A bare `patterns=` (the pre-rules config) is still read, as the rule named
# `default`. Its state files keep their old paths too, so an existing install
# keeps its attestations across this upgrade.
smoke_rules() {
  {
    sed -n 's/^patterns\.\([A-Za-z0-9_][A-Za-z0-9_-]*\)=.*/\1/p' "$SMOKE_CFG" 2>/dev/null
    sed -n 's/^patterns=.*/default/p' "$SMOKE_CFG" 2>/dev/null | head -1
  } | tr -d '\r' | awk '!seen[$0]++'
}

# `default` reads the suffixed key first so that writing `patterns.default=`
# explicitly does what it looks like it does. Falling straight through to the
# bare key would ignore it while the config still reads as configured, which is
# the failure mode this whole file is built to avoid.
smoke_rule_get() { # $1=key $2=rule
  local value
  value="$(smoke_cfg_get "$1[.]$2")"
  if [ -z "$value" ] && [ "$2" = default ]; then
    value="$(smoke_cfg_get "$1")"
  fi
  printf '%s' "$value"
}

# `default` keeps the unsuffixed paths: an attestation written by the previous
# version must still release the gate after the upgrade, and a state file whose
# name changes silently is an attestation that silently stops counting.
smoke_state_file()  { if [ "$1" = default ]; then printf '%s/state' "$SMOKE_STATE_DIR"; else printf '%s/state.%s' "$SMOKE_STATE_DIR" "$1"; fi; }
smoke_blocks_file() { if [ "$1" = default ]; then printf '%s/blocks' "$SMOKE_STATE_DIR"; else printf '%s/blocks.%s' "$SMOKE_STATE_DIR" "$1"; fi; }

# Path from a porcelain line: strip the 3-char "XY " prefix; renames keep the
# destination side (the side that exists in the worktree). The caller disables
# core.quotePath so ordinary non-ASCII names remain real filesystem paths. Git
# can still C-quote control characters; surrounding quotes are stripped so the
# common path grammar stays readable, but such adversarial names are outside
# this advisory gate's boundary.
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
  git -c core.quotePath=false status --porcelain -uall 2>/dev/null \
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

smoke_state_get() { # $1=key [$2=state file, default: the pre-rules path]
  sed -n "s/^$1=//p" "${2:-$SMOKE_STATE}" 2>/dev/null | head -1
}
