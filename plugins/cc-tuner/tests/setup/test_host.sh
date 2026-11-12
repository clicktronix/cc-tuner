#!/usr/bin/env bash
# Tests for scripts/setup/host.sh, the one offline owner of "which forge is this repository on".
#
# Every case builds a throwaway repository and drives the real program through its seams: fixture
# config files stand in for `gh` and `glab` configuration, and a stub `ssh` answers `ssh -G`. gh and
# glab stubs on PATH record every call, which is how "no network" is asserted rather than assumed.
set -u
HOST="$(cd "$(dirname "$0")/../../scripts/setup" && pwd)/host.sh"
fails=0

# The developer's own gh/glab configuration must never decide a test.
unset GH_CONFIG_DIR GLAB_CONFIG_DIR GITLAB_HOST GH_HOST XDG_CONFIG_HOME CC_TUNER_GH_HOSTS_FILE CC_TUNER_GLAB_CONFIG_FILE

T="$(mktemp -d)" || { echo "FATAL: mktemp failed"; exit 1; }
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
BIN="$T/bin"; mkdir -p "$BIN"
CALLS="$T/calls"; : > "$CALLS"

# gh/glab that fail loudly and log: host detection must never reach for them.
for c in gh glab; do
  printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 1\n' "$c" "$CALLS" > "$BIN/$c"; chmod +x "$BIN/$c"
done
# ssh -G stub: alias -> real host, anything else resolves to itself, every call logged.
SSH="$BIN/ssh-stub"
cat > "$SSH" <<EOF
#!/bin/sh
echo "ssh \$*" >> "$CALLS"
case "\$3" in
  github-work)  echo "hostname github.com" ;;
  gitlab-work)  echo "hostname gitlab.com" ;;
  ghe-alias)    echo "hostname ghe.corp.example" ;;
  *)            echo "hostname \$3" ;;
esac
echo "port 22"
EOF
chmod +x "$SSH"

GH_HOSTS="$T/hosts.yml"
printf 'github.com:\n    git_protocol: https\n    users:\n        someone:\n    user: someone\nghe.corp.example:\n    user: me\n    git_protocol: ssh\n' > "$GH_HOSTS"
# Shape copied from a real glab 1.102 config: top-level scalars, then `hosts:` with comments and nested
# fields (some empty, like `user:`) that must not be mistaken for hosts, then another top-level key.
GLAB_CFG="$T/glab.yml"
cat > "$GLAB_CFG" <<'EOF'
# Default GitLab hostname to use.
host: gitlab.com
hosts:
    gitlab.com:
        # What protocol to use to access the API endpoint.
        api_protocol: https
        user:
        token: !!null
    git.corp.example:
        api_protocol: https
        user:
        use_keyring: false
    "quoted.corp.example":
        user:
    forge.corp.example:
        ssh_host: ssh.forge.corp.example
        api_host: forge.corp.example
telemetry: true
EOF

mkrepo() { # mkrepo <name> [remote-name url]... -> repo path in $REPO
  REPO="$T/$1"; shift; rm -rf "$REPO"
  mkdir -p "$REPO"; git -C "$REPO" init -q -b main
  while [ $# -ge 2 ]; do git -C "$REPO" remote add "$1" "$2"; shift 2; done
}
run_host() { # run_host [root]  (stdout in $OUT, status in $RC)
  OUT="$(CC_TUNER_SSH_CMD="$SSH" CC_TUNER_GH_HOSTS_FILE="$GH_HOSTS" CC_TUNER_GLAB_CONFIG_FILE="$GLAB_CFG" \
         PATH="$BIN:$PATH" bash "$HOST" "$@" 2>&1)"; RC=$?
}
tab() { printf '%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4"; }
want() { # want <name> <host> <via> <remote> <remote-host>
  n="$1"; shift
  exp="$(tab "$@")"
  if [ "$OUT" = "$exp" ] && [ "$RC" -eq 0 ]; then echo "PASS $n"
  else echo "FAIL $n (want '$exp' rc 0, got '$OUT' rc $RC)"; fails=1; fi
}
case_url() { # case_url <name> <url> <host> <via> <remote-host>
  mkrepo "r-$1" origin "$2"; run_host "$REPO"; want "$1" "$3" "$4" origin "$5"
}

# --- exact host from the URL ---------------------------------------------------------------------
case_url https-github       https://github.com/acme/app.git        github url github.com
case_url scp-github         git@github.com:acme/app.git            github url github.com
case_url ssh-url-github     ssh://git@github.com:22/acme/app.git   github url github.com
case_url git-scheme-github  git://github.com/acme/app.git          github url github.com
case_url userinfo-github    https://user:pw@github.com/acme/app    github url github.com
case_url uppercase-host     https://GitHub.COM/acme/app.git        github url github.com
case_url https-gitlab       https://gitlab.com/acme/app.git        gitlab url gitlab.com
case_url scp-gitlab         git@gitlab.com:acme/app.git            gitlab url gitlab.com
# The old substring match called this github.
case_url mirror-name-is-not-host  git@gitlab.com:acme/github.com-mirror.git  gitlab url gitlab.com
case_url lookalike-host     https://github.com.evil.example/a/b    other  none github.com.evil.example
# `?` and `#` end the authority, so a later `@github.com` is not the host.
case_url query-before-at    'https://evil.example?@github.com/a/b'  other  none evil.example
case_url fragment-before-at 'https://evil.example#@github.com/a/b'  other  none evil.example
case_url unknown-host       git@git.example.org:acme/app.git       other  none git.example.org

# --- hosts the CLIs are configured for -----------------------------------------------------------
case_url ghe-from-config    https://ghe.corp.example/acme/app.git  github config ghe.corp.example
case_url gl-self-hosted     git@git.corp.example:acme/app.git      gitlab config git.corp.example
case_url gl-quoted-key      https://quoted.corp.example/a/b        gitlab config quoted.corp.example
# `user:` is a field under a host, not a host.
case_url glab-field-not-host https://user/a/b                      other  none user
case_url glab-later-key-not-host https://telemetry/a/b             other  none telemetry
case_url gh-field-not-host  https://someone/a/b                    other  none someone
# glab's `ssh_host` maps a separate SSH endpoint to the configured host, which is also the host to log in to.
case_url gl-ssh-host-scp    git@ssh.forge.corp.example:team/app.git          gitlab config forge.corp.example
case_url gl-ssh-host-url    ssh://git@ssh.forge.corp.example/team/app.git    gitlab config forge.corp.example
case_url gl-ssh-host-https  https://forge.corp.example/team/app.git          gitlab config forge.corp.example
case_url glab-nested-key-not-host https://api_host/a/b                       other  none api_host

mkrepo gl-env origin https://gl.env.example/a/b
OUT="$(GITLAB_HOST=gl.env.example CC_TUNER_GH_HOSTS_FILE="$GH_HOSTS" CC_TUNER_GLAB_CONFIG_FILE="$GLAB_CFG" PATH="$BIN:$PATH" bash "$HOST" "$REPO" 2>&1)"; RC=$?
want "gitlab-host-env" gitlab config origin gl.env.example

# default config locations, through the variables gh and glab themselves honour
mkdir -p "$T/ghdir" "$T/glabdir"; cp "$GH_HOSTS" "$T/ghdir/hosts.yml"; cp "$GLAB_CFG" "$T/glabdir/config.yml"
mkrepo dirs-gh origin https://ghe.corp.example/a/b
OUT="$(GH_CONFIG_DIR="$T/ghdir" PATH="$BIN:$PATH" bash "$HOST" "$REPO" 2>&1)"; RC=$?
want "gh-config-dir" github config origin ghe.corp.example
mkrepo dirs-gl origin https://git.corp.example/a/b
OUT="$(GLAB_CONFIG_DIR="$T/glabdir" PATH="$BIN:$PATH" bash "$HOST" "$REPO" 2>&1)"; RC=$?
want "glab-config-dir" gitlab config origin git.corp.example
mkdir -p "$T/xdg/gh"; cp "$GH_HOSTS" "$T/xdg/gh/hosts.yml"
mkrepo dirs-xdg origin https://ghe.corp.example/a/b
OUT="$(XDG_CONFIG_HOME="$T/xdg" PATH="$BIN:$PATH" bash "$HOST" "$REPO" 2>&1)"; RC=$?
want "gh-xdg-config-home" github config origin ghe.corp.example
mkrepo no-config origin https://ghe.corp.example/a/b
OUT="$(PATH="$BIN:$PATH" bash "$HOST" "$REPO" 2>&1)"; RC=$?
want "no-config-files-is-other" other none origin ghe.corp.example

# --- SSH aliases ---------------------------------------------------------------------------------
case_url alias-github       git@github-work:acme/app.git           github url github.com
case_url alias-gitlab       ssh://git@gitlab-work/acme/app.git     gitlab url gitlab.com
case_url alias-ghe          git@ghe-alias:acme/app.git             github config ghe.corp.example
: > "$CALLS"
case_url literal-skips-ssh  git@github.com:acme/app.git            github url github.com
if [ -s "$CALLS" ]; then echo "FAIL literal-github-does-not-call-ssh ($(cat "$CALLS"))"; fails=1; else echo "PASS literal-github-does-not-call-ssh"; fi
: > "$CALLS"
case_url https-skips-ssh    https://git.example.org/a/b            other  none git.example.org
if [ -s "$CALLS" ]; then echo "FAIL https-does-not-call-ssh ($(cat "$CALLS"))"; fails=1; else echo "PASS https-does-not-call-ssh"; fi
# an alias nobody can resolve stays the alias
mkrepo no-ssh origin git@github-work:acme/app.git
OUT="$(CC_TUNER_SSH_CMD=/nonexistent/ssh PATH="$BIN:$PATH" bash "$HOST" "$REPO" 2>&1)"; RC=$?
want "alias-without-ssh-is-other" other none origin github-work
# a host that could pass for an ssh option is never handed to ssh
: > "$CALLS"
case_url option-like-host   'git@-oProxyCommand:a/b'               other  none ""
if [ -s "$CALLS" ]; then echo "FAIL option-like-host-not-sent-to-ssh ($(cat "$CALLS"))"; fails=1; else echo "PASS option-like-host-not-sent-to-ssh"; fi

# --- not a URL a forge serves --------------------------------------------------------------------
mkrepo path-abs origin "$T/somewhere/else.git";        run_host "$REPO"; want "path-remote"          other none origin ""
mkrepo path-rel origin ../sibling.git;                  run_host "$REPO"; want "relative-path-remote" other none origin ""
mkrepo path-file origin file:///srv/git/app.git;        run_host "$REPO"; want "file-url-remote"      other none origin ""
mkrepo path-github-named origin /srv/github.com/app.git; run_host "$REPO"; want "path-naming-github"  other none origin ""

# --- which remote --------------------------------------------------------------------------------
mkrepo none;                                            run_host "$REPO"; want "no-remote-is-local" local none "" ""
mkrepo only upstream https://github.com/acme/app.git;   run_host "$REPO"; want "only-remote-used"   github url upstream github.com
mkrepo both origin https://gitlab.com/acme/app.git mirror https://github.com/acme/app.git
run_host "$REPO"; want "origin-wins-over-mirror" gitlab url origin gitlab.com
mkrepo both2 mirror https://github.com/acme/app.git origin https://gitlab.com/acme/app.git
run_host "$REPO"; want "origin-wins-regardless-of-order" gitlab url origin gitlab.com
mkrepo amb a https://github.com/acme/app.git b https://gitlab.com/acme/app.git
run_host "$REPO"; want "several-remotes-no-origin-ambiguous" ambiguous none "" ""

# --- where it runs from, and what it is not ------------------------------------------------------
mkrepo sub origin https://github.com/acme/app.git; mkdir -p "$REPO/a/b"
OUT="$(cd "$REPO/a/b" && CC_TUNER_SSH_CMD="$SSH" PATH="$BIN:$PATH" bash "$HOST" 2>&1)"; RC=$?
want "defaults-to-working-directory" github url origin github.com
mkdir -p "$T/plain"; run_host "$T/plain"
if [ "$RC" -eq 2 ] && [ -z "$OUT" ]; then echo "PASS not-a-repo-exit2-prints-nothing"; else echo "FAIL not-a-repo-exit2-prints-nothing (rc $RC: $OUT)"; fails=1; fi

# --- offline -------------------------------------------------------------------------------------
: > "$CALLS"
for u in https://github.com/a/b https://gitlab.com/a/b https://git.example.org/a/b git@github-work:a/b https://ghe.corp.example/a/b; do
  mkrepo offline origin "$u"; run_host "$REPO"
done
mkrepo offline-none; run_host "$REPO"
if grep -qE '^(gh|glab) ' "$CALLS"; then echo "FAIL never-runs-gh-or-glab ($(grep -E '^(gh|glab) ' "$CALLS"))"; fails=1; else echo "PASS never-runs-gh-or-glab"; fi

# --- minimal PATH: doctor runs on one, and host.sh is called from it -------------------------------
M="$T/min"; mkdir -p "$M"
for u in sed tr grep head dirname bash cat git; do ln -s "$(command -v "$u")" "$M/$u"; done
mkrepo minrepo origin https://ghe.corp.example/a/b
OUT="$(CC_TUNER_GH_HOSTS_FILE="$GH_HOSTS" PATH="$M" bash "$HOST" "$REPO" 2>&1)"; RC=$?
want "minimal-path-without-ssh" github config origin ghe.corp.example

exit $fails
