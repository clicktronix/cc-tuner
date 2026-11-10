#!/usr/bin/env bash
# Which forge hosts THIS repository?
#
#   host.sh [repo-root]
#
# Prints exactly ONE line, tab separated:
#
#   <host><TAB><via><TAB><remote><TAB><remote-host>
#
#   host         github | gitlab | local | other | ambiguous
#   via          url     the remote's host is github.com or gitlab.com
#                config  the remote's host is one gh (hosts.yml) or glab (config.yml) is logged in to
#                none    local, other and ambiguous
#   remote       the remote that was read: `origin`, else the only remote; empty for local/ambiguous
#   remote-host  the host the remote points at, lower case, after resolving an SSH alias; empty when the
#                remote is a filesystem path or has no usable host
#
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
# Remote choice: `origin` when it exists, else the only remote. Several remotes and no `origin` is
# `ambiguous`: picking one silently turned a GitLab repository with a GitHub mirror into whichever
# the CLI answered first, so the caller asks instead. No remote is `local`.
#
# The host is parsed from the URL, never matched as a substring: `scheme://[user@]host[:port]/path`
# (ssh, https, http, git) or scp-like `[user@]host:path`. A filesystem path or `file://` has no host
# and is `other`. A host that does not look like a hostname is dropped and is `other`, so it cannot
# reach `ssh` as an option or a caller's command line.
#
# SSH aliases: for an ssh-style remote whose literal host is not recognised, `ssh -G` resolves the
# alias (`Host github-work` / `HostName github.com`) from ssh_config, which reads local files only.
# A literal github.com or gitlab.com is not resolved: `Host github.com` + `HostName ssh.github.com`
# (port 443) is a real configuration and would otherwise stop being GitHub.
#
# Seams: CC_TUNER_SSH_CMD (default ssh), CC_TUNER_GH_HOSTS_FILE (default ${GH_CONFIG_DIR},
# ${XDG_CONFIG_HOME}/gh or ~/.config/gh, plus hosts.yml), CC_TUNER_GLAB_CONFIG_FILE (default
# ${GLAB_CONFIG_DIR}/config.yml, else glab's macOS and XDG locations). $GH_HOST and $GITLAB_HOST name one
# more configured host each, as gh and glab themselves treat them.
# Only sed, grep and tr besides git: doctor runs this on a minimal PATH. No awk, no `read` with a tab
# IFS. bash 3.2 compatible: macOS ships 3.2.57.
set -u

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
glab_hosts_in() { # glab_hosts_in <config.yml>
  local line t ind="" lead in_hosts=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in hosts:*) in_hosts=1; ind=""; continue ;; esac
    [ "$in_hosts" -eq 1 ] || continue
    t="${line#"${line%%[! ]*}"}"
    case "$t" in ''|'#'*) continue ;; esac
    lead="${line%"$t"}"
    if [ -z "$lead" ]; then in_hosts=0; continue; fi
    if [ -z "$ind" ]; then ind="$lead"; fi
    if [ "$lead" = "$ind" ]; then
      case "$t" in *:*) printf '%s\n' "${t%%:*}" | tr -d "\"'" ;; esac
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
  if [ -n "${GITLAB_HOST:-}" ]; then printf '%s\n' "$GITLAB_HOST"; fi
}

GH_LIST="$(gh_hosts | tr 'A-Z' 'a-z')"
GLAB_LIST="$(glab_hosts | tr 'A-Z' 'a-z')"

# classify <lowercase host> -> C_HOST, C_VIA
classify() {
  C_HOST=other; C_VIA=none
  case "$1" in
    github.com) C_HOST=github; C_VIA=url; return ;;
    gitlab.com) C_HOST=gitlab; C_VIA=url; return ;;
  esac
  if printf '%s\n' "$GH_LIST" | grep -qxF -- "$1"; then C_HOST=github; C_VIA=config
  elif printf '%s\n' "$GLAB_LIST" | grep -qxF -- "$1"; then C_HOST=gitlab; C_VIA=config
  fi
}

emit() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"; exit 0; }

REMOTES="$(git -C "$ROOT" remote 2>/dev/null)"
if [ -z "$REMOTES" ]; then emit local none "" ""; fi
if printf '%s\n' "$REMOTES" | grep -qx origin; then
  REMOTE=origin
elif [ "$(printf '%s\n' "$REMOTES" | grep -c '')" -eq 1 ]; then
  REMOTE="$REMOTES"
else
  emit ambiguous none "" ""
fi

URL="$(git -C "$ROOT" remote get-url "$REMOTE" 2>/dev/null)"
KIND=path; RHOST=""
case "$URL" in
  file://*) ;;
  *://*)
    scheme="${URL%%://*}"; rest="${URL#*://}"; auth="${rest%%/*}"; auth="${auth##*@}"
    RHOST="${auth%%:*}"
    case "$(lower "$scheme")" in ssh|git+ssh|ssh+git) KIND=ssh ;; *) KIND=net ;; esac
    ;;
  /*|./*|../*) ;;
  *:*)
    before="${URL%%:*}"
    case "$before" in */*) ;; *) RHOST="${before##*@}"; KIND=ssh ;; esac
    ;;
esac
RHOST="$(lower "$RHOST")"
case "$RHOST" in
  ''|-*|*[!a-z0-9._-]*) emit other none "$REMOTE" "" ;;
esac

classify "$RHOST"
if [ "$C_HOST" != other ] || [ "$KIND" != ssh ]; then emit "$C_HOST" "$C_VIA" "$REMOTE" "$RHOST"; fi

SSH_CMD="${CC_TUNER_SSH_CMD:-ssh}"
if command -v "${SSH_CMD%% *}" >/dev/null 2>&1; then
  resolved="$(lower "$($SSH_CMD -G -- "$RHOST" 2>/dev/null | sed -n 's/^hostname //p;/^hostname /q')")"
  case "$resolved" in
    ''|-*|*[!a-z0-9._-]*) ;;
    *) RHOST="$resolved"; classify "$RHOST" ;;
  esac
fi
emit "$C_HOST" "$C_VIA" "$REMOTE" "$RHOST"
