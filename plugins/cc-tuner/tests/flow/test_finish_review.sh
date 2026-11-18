#!/usr/bin/env bash
# Exercise the actual round publisher against a real checkout and a stateful GitHub stub.
set -eu
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
work=$(flow_workdir)
export REMOTE_STATE="$work/state"
mkdir "$REMOTE_STATE" "$work/bin"
export PATH="$work/bin:$PATH"
unset CC_TUNER_GH CC_TUNER_REMOTE
git init -q "$work/repo"
cd "$work/repo"
git remote add origin https://github.com/example/fixture.git
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -eu
echo "$*" >> "$REMOTE_STATE/calls"
if [ "$1 $2" = 'auth status' ]; then exit 0; fi
[ "$1 $2 $3" = 'api --hostname github.com' ] || exit 2
shift 3
endpoint=repos/example/fixture/pulls/2
case "$*" in
  user) echo '{"id":17}' ;;
  "--paginate --slurp $endpoint/reviews") jq -s '[.]' "$REMOTE_STATE/reviews" ;;
  "$endpoint") jq -n --arg sha "$(cat "$REMOTE_STATE/head")" '{head:{sha:$sha}}' ;;
  "--paginate --slurp $endpoint/commits") jq -Rs '[split("\n")|map(select(length>0)|{sha:.})]' "$REMOTE_STATE/commits" ;;
  "$endpoint/reviews --method POST -f event=COMMENT -f commit_id="*)
    [ "$8" = '-f' ]
    jq -cn --arg sha "${7#commit_id=}" --arg body "${9#body=}" \
      '{commit_id:$sha,body:$body,state:"COMMENTED",user:{id:17},html_url:"review-url"}' >> "$REMOTE_STATE/reviews"
    [ ! -f "$REMOTE_STATE/drop-response" ] || exit 1
    echo review-url ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$work/bin/gh"
: > "$REMOTE_STATE/reviews"
a=$(printf '%040d' 1)
b=$(printf '%040d' 2)
printf '%s\n' "$a" > "$REMOTE_STATE/head"
printf '%s\n' "$a" "$b" > "$REMOTE_STATE/commits"
publish() { python3 "$FLOW_PLUGIN/scripts/finish-review.py" "$@"; }
printf 'CC_CODEX_REQUIRED_REVIEW APPROVE thread=task head=%s tree=%s base_sha=%s spec_path=docs/a spec.md\n' "$a" "$a" "$b" > "$work/round-1"

publish "$work/round-1"
[ ! -e "$REMOTE_STATE/calls" ]
touch "$REMOTE_STATE/drop-response"
if publish "$work/round-1" --pr 2; then exit 1; fi
rm "$REMOTE_STATE/drop-response"
publish "$work/round-1" --pr 2
[ "$(wc -l < "$REMOTE_STATE/reviews" | tr -d ' ')" = 1 ]
printf '%s\n' "$b" > "$REMOTE_STATE/head"  # the README fix is now pushed
printf 'cc-tuner-verdict: APPROVE %s\n' "$b" > "$work/round-2"
publish "$work/round-2" --pr 2
jq -es --arg a "$a" --arg b "$b" \
  'map(.commit_id) == [$a,$b] and all(.[]; (.body|split("\n")[0]) == ("cc-tuner-verdict: APPROVE " + .commit_id))' "$REMOTE_STATE/reviews"
# A later round on the same commit has its own decision. Replaying A must not supersede it.
printf 'cc-tuner-verdict: REQUEST_CHANGES %s\n' "$b" > "$work/round-3"
publish "$work/round-3" --pr 2
publish "$work/round-1" --pr 2
jq -es 'length == 3 and (last.body|startswith("cc-tuner-verdict: REQUEST_CHANGES "))' "$REMOTE_STATE/reviews"
# If publication was delayed until the head moved, post against the original commit.
cp "$work/round-1" "$work/delayed"
publish "$work/delayed" --pr 2
jq -es --arg a "$a" 'last.commit_id == $a' "$REMOTE_STATE/reviews"
printf 'cc-tuner-verdict: APPROVE %040d\n' 3 > "$work/unrelated"
if publish "$work/unrelated" --pr 2; then exit 1; fi
printf 'NO_DECISION\n' > "$work/incomplete"
if publish "$work/incomplete" --pr 2; then exit 1; fi
jq -es 'length == 4' "$REMOTE_STATE/reviews"
# An entry from a deleted or different account cannot acknowledge our round.
jq -c '.user = null' "$REMOTE_STATE/reviews" > "$work/foreign"
jq -c '.user = {"id":99}' "$REMOTE_STATE/reviews" >> "$work/foreign"
mv "$work/foreign" "$REMOTE_STATE/reviews"
publish "$work/round-1" --pr 2
jq -es '[.[]|select(.user.id==17)]|length==1' "$REMOTE_STATE/reviews"
# Reusing a receipt filename for a different judgement must not rewrite the original round.
printf 'cc-tuner-verdict: REQUEST_CHANGES %s\n' "$a" > "$work/round-1"
if publish "$work/round-1" --pr 2; then exit 1; fi
echo 'PASS exact-SHA rounds, delayed publication, lost response and local-only handoff'
