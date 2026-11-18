#!/usr/bin/env bash
# Run the documented transports with the verifier's actual file, including its last blank line.
set -eu -o pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
work=$(flow_workdir)
routes="$FLOW_PLUGIN/skills/run/references"
export VERIFY_FILE="$work/verify evidence.md" DELIVERY_HOST=github.com DELIVERY_PROJECT=example/fixture
cat > "$VERIFY_FILE" <<'RECORD'
cc-tuner-verified: 0000000000000000000000000000000000000001
- [cli] build output
      first line: `value`
      second line: $(literal)
- NOT PROVED: CI starts after publication.

RECORD
# Capture the payload at each CLI boundary, without rewriting it in the test.
gh() {
  [ "$1 $2 $3 $4" = 'pr comment 2 --body-file' ] && [ "$6" = '--repo' ] && [ "$7" = 'github.com/example/fixture' ] || return 2
  cat "$5" > "$work/github-body"
}
github=$(sed -n 's/.*`\(gh pr comment <pr> --body-file [^`]*\)`.*/\1/p' "$routes/delivery.md" | head -1)
[ -n "$github" ]; eval "${github/<pr>/2}"
cmp "$VERIFY_FILE" "$work/github-body"

glab() {
  [ "$*" = 'api --hostname gitlab.example --method POST projects/7/merge_requests/2/notes --input -' ] || return 2
  jq -jr '.body' > "$work/gitlab-body"
}
export GITLAB_PROJECT_ID=7 DELIVERY_HOST=gitlab.example
gitlab=$(sed -n '/^jq -Rs /,/--input -$/p' "$routes/route-gitlab.md")
[ -n "$gitlab" ]; eval "${gitlab/<iid>/2}"
cmp "$VERIFY_FILE" "$work/gitlab-body"

git init -q "$work/repo"
cd "$work/repo"
git -c user.name=Verifier -c user.email=test@example.invalid commit -qm base --allow-empty
git config user.name Verifier
git config user.email test@example.invalid
local_note=$(sed -n 's/.*`\(git notes --ref cc-tuner append -C [^`]*\)`.*/\1/p' "$routes/route-local.md")
[ -n "$local_note" ]; eval "${local_note/<verified sha>/HEAD}"
git notes --ref cc-tuner show HEAD > "$work/local-note"
cmp "$VERIFY_FILE" "$work/local-note"
echo 'PASS verifier-owned Markdown survives GitHub, GitLab and local-note transports byte for byte'
