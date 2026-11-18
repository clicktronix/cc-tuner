#!/usr/bin/env bash
# Which forge hosts THIS repository?
#
#   host.sh [--delivery] [repo-root]
#
# Prints exactly ONE line, tab separated:
#
#   <host><TAB><via><TAB><remote><TAB><remote-host>
#
#   host         github | gitlab | local | other | ambiguous
#   via          url     the remote's host is github.com or gitlab.com
#                config  the remote's host is one gh (hosts.yml) or glab (config.yml) is logged in to
#                none    local, other and ambiguous
#   remote       the selected delivery remote; empty for local/ambiguous
#   remote-host  the host the remote points at, lower case, after resolving an SSH alias or a glab
#                `ssh_host`; it is the host a CLI logs in to. Empty when the remote is a filesystem
#                path or has no usable host
#
# --delivery appends a fifth field, the forge project path (owner/repo or group/subgroup/repo).
# It refuses an inconsistent fetch/push destination with exit 15 and a diagnostic on stderr.
# Exit 0 with the line, 2 when the directory is not inside a git repository (nothing printed).
#
# **One program, many callers, and that is the whole point.** Host detection began as code in doctor.sh
# and prose in /spec, /run, the spec template and the delivery-route reference. The copies disagreed
# on which remote counts (origin, or the first one, or "a remote"), on whether `other` is confirmed
# with the user, and on what a URL "names" -- the shell one was `*github.com*`, which calls
# `git@gitlab.com:a/github.com-mirror.git` GitHub. /run stops on a host mismatch, so every drift
# between two copies is a false stop. Doctor, /spec, /run and setup now ask this script.
#
# **Offline by construction.** The first version asked `gh repo view` / `glab repo view`, which are
# network calls: with no connection, or an expired token, an SSH-aliased GitHub repository became
# `other`, and doctor sent the stored token of a CLI to whatever host the remote named. Nothing here runs
# gh, glab or an auth check. What a CLI is *logged in to* is read from its own config file instead,
# which answers the real question -- "can that CLI act on this host?" -- without a request. Whether the
# login still works is the caller's check, made against the host this script names.
#
# Select the requested or configured push remote, then origin or the sole remote.
# Several candidates with no selection, or a configured remote that no longer exists, are ambiguous.
#
# The host is parsed from the URL, never matched as a substring: `scheme://[user@]host[:port]/path`
# (ssh, https, http, git; the authority ends at the first `/`, `?` or `#`) or scp-like `[user@]host:path`. A filesystem path or `file://` has no host
# and is `other`. A host that does not look like a hostname is dropped and is `other`, so it cannot
# reach `ssh` as an option or a caller's command line.
#
# SSH aliases: `ssh -G` resolves aliases (`Host github-work` / `HostName github.com`) from ssh_config.
# Setup accepts a known literal host directly. Delivery compares resolved endpoints too, treating
# GitHub's alternate SSH endpoint ssh.github.com as GitHub.
#
# glab `ssh_host`: a GitLab whose SSH endpoint differs from its web/API host (`ssh.forge.example` for
# `forge.example`) records it under that host, and glab resolves remotes through it. So does this
# script: a remote on the SSH endpoint is that GitLab, and the reported host is the configured one.
#
# Seams: CC_TUNER_SSH_CMD (default ssh), CC_TUNER_GH_HOSTS_FILE (default ${GH_CONFIG_DIR},
# ${XDG_CONFIG_HOME}/gh or ~/.config/gh, plus hosts.yml), CC_TUNER_GLAB_CONFIG_FILE (default
# ${GLAB_CONFIG_DIR}/config.yml, else glab's macOS and XDG locations). $GH_HOST and $GITLAB_HOST name one
# more configured host each, as gh and glab themselves treat them.
# Only sed, grep and tr besides git: doctor runs this on a minimal PATH. No awk, no `read` with a tab
# IFS. bash 3.2 compatible: macOS ships 3.2.57.
set -u

DELIVERY=no
if [ "${1:-}" = --delivery ]; then DELIVERY=yes; shift; fi
ROOT="${1:-$PWD}"
git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 2

lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

# gh keeps one top-level key per host in hosts.yml; everything nested is indented.
gh_hosts() {
  local f="${CC_TUNER_GH_HOSTS_FILE:-}" dir
  if [ -z "$f" ]; then
    dir="${GH_CONFIG_DIR:-}"
    if [ -z "$dir" ]; then
      if [ -n "${XDG_CONFIG_HOME:-}" ]; then dir="$XDG_CONFIG_HOME/gh"; else dir="$HOME/.config/gh"; fi
    fi
    f="$dir/hosts.yml"
  fi
  if [ -f "$f" ]; then
    sed -n 's/^\([^ #][^:]*\):.*/\1/p' "$f" | tr -d "\"'"
  fi
  if [ -n "${GH_HOST:-}" ]; then printf '%s\n' "$GH_HOST"; fi
}

# glab keeps its hosts one level under `hosts:`, next to nested fields (`user:`, `token:`) that look
# the same, so the host indent is taken from the first entry and only keys at that indent count.
# Prints `H <host>` per host and `S <ssh_host> <host>` per nested `ssh_host:` field.
glab_hosts_in() { # glab_hosts_in <config.yml>
  local line t ind="" lead in_hosts=0 cur="" v
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in hosts:*) in_hosts=1; ind=""; continue ;; esac
    [ "$in_hosts" -eq 1 ] || continue
    t="${line#"${line%%[! ]*}"}"
    case "$t" in ''|'#'*) continue ;; esac
    lead="${line%"$t"}"
    if [ -z "$lead" ]; then in_hosts=0; continue; fi
    if [ -z "$ind" ]; then ind="$lead"; fi
    if [ "$lead" = "$ind" ]; then
      case "$t" in *:*) cur="$(printf '%s' "${t%%:*}" | tr -d "\"'")"; printf 'H %s\n' "$cur" ;; esac
    elif [ -n "$cur" ]; then
      case "$t" in ssh_host:*)
        v="$(printf '%s' "${t#ssh_host:}" | tr -d "\"' ")"
        [ -n "$v" ] && printf 'S %s %s\n' "$v" "$cur" ;;
      esac
    fi
  done < "$1"
}
glab_hosts() {
  local f
  if [ -n "${CC_TUNER_GLAB_CONFIG_FILE:-}" ]; then
    [ -f "$CC_TUNER_GLAB_CONFIG_FILE" ] && glab_hosts_in "$CC_TUNER_GLAB_CONFIG_FILE"
  elif [ -n "${GLAB_CONFIG_DIR:-}" ]; then
    [ -f "$GLAB_CONFIG_DIR/config.yml" ] && glab_hosts_in "$GLAB_CONFIG_DIR/config.yml"
  else
    for f in "$HOME/Library/Application Support/glab-cli/config.yml" \
             "${XDG_CONFIG_HOME:-$HOME/.config}/glab-cli/config.yml"; do
      [ -f "$f" ] && glab_hosts_in "$f"
    done
  fi
  if [ -n "${GITLAB_HOST:-}" ]; then printf 'H %s\n' "$GITLAB_HOST"; fi
}

GH_LIST="$(gh_hosts | tr 'A-Z' 'a-z')"
GLAB_ROWS="$(glab_hosts | tr 'A-Z' 'a-z')"
GLAB_LIST="$(printf '%s\n' "$GLAB_ROWS" | sed -n 's/^h //p')"
GLAB_SSH="$(printf '%s\n' "$GLAB_ROWS" | sed -n 's/^s //p')"

# classify <lowercase host> -> C_HOST, C_VIA, C_NAME (the host to report: a glab ssh_host maps to its host)
classify() {
  C_HOST=other; C_VIA=none; C_NAME="$1"
  case "$1" in
    github.com) C_HOST=github; C_VIA=url; return ;;
    gitlab.com) C_HOST=gitlab; C_VIA=url; return ;;
  esac
  local ssh to mapped=""
  while read -r ssh to; do
    if [ "$ssh" = "$1" ]; then
      case "$to" in ''|-*|*[!a-z0-9._-]*) ;; *) mapped="$to" ;; esac
      break
    fi
  done <<EOF
$GLAB_SSH
EOF
  if printf '%s\n' "$GH_LIST" | grep -qxF -- "$1"; then C_HOST=github; C_VIA=config
  elif printf '%s\n' "$GLAB_LIST" | grep -qxF -- "$1"; then C_HOST=gitlab; C_VIA=config
  elif [ -n "$mapped" ]; then C_HOST=gitlab; C_VIA=config; C_NAME="$mapped"
  fi
}

emit() {
  printf '%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4"
  if [ "$DELIVERY" = yes ]; then printf '\t%s' "${5:-}"; fi
  printf '\n'
  exit 0
}

REMOTES="$(git -C "$ROOT" remote 2>/dev/null)"
if [ -z "$REMOTES" ]; then emit local none "" ""; fi
REMOTE="${CC_TUNER_REMOTE:-}"
branch="$(git -C "$ROOT" symbolic-ref --short -q HEAD)" || branch=''
if [ -z "$REMOTE" ] && [ -n "$branch" ]; then
  REMOTE="$(git -C "$ROOT" config --get "branch.$branch.pushRemote")"
fi
[ -n "$REMOTE" ] || REMOTE="$(git -C "$ROOT" config --get remote.pushDefault)"
if [ -n "$REMOTE" ]; then
  printf '%s\n' "$REMOTES" | grep -qxF -- "$REMOTE" || emit ambiguous none "" ""
elif printf '%s\n' "$REMOTES" | grep -qx origin; then
  REMOTE=origin
elif [ "$(printf '%s\n' "$REMOTES" | grep -c '')" -eq 1 ]; then
  REMOTE="$REMOTES"
else
  emit ambiguous none "" ""
fi

# resolve_url <effective Git URL> -> forge classification and CLI project path.
resolve_url() {
  local url="$1" kind=path rhost="" scheme="" rest auth="" before resolved
  local ssh_cmd="${CC_TUNER_SSH_CMD:-ssh}"
  PROJECT=""
  case "$url" in
    file://*) ;;
    *://*)
      scheme="$(lower "${url%%://*}")"; rest="${url#*://}"; auth="${rest%%[/?#]*}"
      if [ "${rest#"$auth"/}" != "$rest" ]; then PROJECT="${rest#"$auth"/}"; fi
      auth="${auth##*@}"; rhost="${auth%%:*}"
      case "$scheme" in ssh|git+ssh|ssh+git) kind=ssh ;; *) kind=net ;; esac
      ;;
    /*|./*|../*) ;;
    *:*)
      before="${url%%:*}"
      case "$before" in
        */*) ;;
        *) rhost="${before##*@}"; kind=ssh; PROJECT="${url#*:}"; PROJECT="${PROJECT#/}" ;;
      esac
      ;;
  esac
  rhost="$(lower "$rhost")"
  case "$rhost" in ''|-*|*[!a-z0-9._-]*) C_HOST=other; C_VIA=none; C_NAME=""; PROJECT=""; return ;; esac

  classify "$rhost"
  if [ "$kind" = ssh ] && { [ "$C_HOST" = other ] || [ "$DELIVERY" = yes ]; } &&
      command -v "${ssh_cmd%% *}" >/dev/null 2>&1; then
    resolved="$(lower "$($ssh_cmd -G -- "$rhost" 2>/dev/null | sed -n 's/^hostname //p;/^hostname /q')")"
    case "$resolved" in ''|-*|*[!a-z0-9._-]*) ;; *) classify "$resolved" ;; esac
  fi
  [ "$DELIVERY" = yes ] || return 0

  # A web port identifies a distinct service, while the forge CLI targets the login hostname.
  # GitHub's hosted alternate SSH endpoint is a transport for the same API repository.
  case "$kind:$C_NAME" in ssh:ssh.github.com) classify github.com ;; esac
  case "$scheme:$auth" in
    http:*:80|https:*:443|git:*:9418|ssh:*|git+ssh:*|ssh+git:*|:*) ;;
    *:*:*) PROJECT="" ;;
    http:*|https:*|git:*) ;;
    *) PROJECT="" ;;
  esac

  PROJECT="${PROJECT%/}"; PROJECT="${PROJECT%.git}"
  case "$PROJECT" in *[!a-zA-Z0-9._/-]*) PROJECT="" ;; esac
  case "/$PROJECT/" in *//*|*/./*|*/../*) PROJECT="" ;; esac
  case "$C_HOST:$PROJECT" in
    github:*/*/*) PROJECT="" ;;
    github:*/*|gitlab:*/*) ;;
    *) PROJECT="" ;;
  esac
}

delivery_fail() { printf 'host: remote %s %s\n' "$REMOTE" "$1" >&2; exit 15; }

URL="$(git -C "$ROOT" remote get-url -- "$REMOTE" 2>/dev/null)"
resolve_url "$URL"
if [ "$DELIVERY" = no ]; then emit "$C_HOST" "$C_VIA" "$REMOTE" "$C_NAME"; fi

[ -n "$URL" ] || delivery_fail 'has no fetch URL'
case "$C_HOST" in
  github|gitlab) [ -n "$PROJECT" ] || delivery_fail 'has no usable forge project path' ;;
esac
PUSH_URL="$(git -C "$ROOT" remote get-url --push --all -- "$REMOTE" 2>/dev/null && printf '.')" ||
  delivery_fail 'has no push URL'
PUSH_URL="${PUSH_URL%$'\n.'}"
case "$PUSH_URL" in
  "") delivery_fail 'has no push URL' ;;
  *$'\n'*) delivery_fail 'has multiple push URLs; select a remote that pushes to one repository' ;;
esac

if [ "$URL" != "$PUSH_URL" ]; then
  FETCH_HOST="$C_HOST"; FETCH_VIA="$C_VIA"; FETCH_NAME="$C_NAME"; FETCH_PROJECT="$PROJECT"
  resolve_url "$PUSH_URL"
  PUSH_PROJECT="$PROJECT"; CHECK_PROJECT="$FETCH_PROJECT"
  if [ "$FETCH_HOST" = github ]; then
    PUSH_PROJECT="$(lower "$PUSH_PROJECT")"; CHECK_PROJECT="$(lower "$CHECK_PROJECT")"
  fi
  [ -n "$CHECK_PROJECT" ] && [ "$FETCH_HOST:$FETCH_NAME:$CHECK_PROJECT" = "$C_HOST:$C_NAME:$PUSH_PROJECT" ] ||
    delivery_fail 'fetches and pushes to different repositories; select a remote that uses one repository'
  emit "$FETCH_HOST" "$FETCH_VIA" "$REMOTE" "$FETCH_NAME" "$FETCH_PROJECT"
fi
emit "$C_HOST" "$C_VIA" "$REMOTE" "$C_NAME" "$PROJECT"
