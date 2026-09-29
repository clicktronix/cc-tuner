#!/usr/bin/env bash
# Shared Git reader for review inventory and lens packets. Extra diff options/pathspecs follow refs.
set -euo pipefail
[ "$#" -ge 2 ] || { echo 'usage: review-diff.sh <base> <candidate> [diff options] [-- paths...]' >&2; exit 1; }
base="$(git rev-parse --verify --end-of-options "$1^{commit}")"
candidate="$(git rev-parse --verify --end-of-options "$2^{commit}")"
shift 2
exec git -c core.quotePath=false --literal-pathspecs diff --no-ext-diff --no-textconv --no-color --find-renames \
  --ignore-submodules=none --submodule=short "$base...$candidate" "$@"
