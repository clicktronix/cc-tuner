#!/usr/bin/env bash
# The Bash guard in hooks/register.ts refuses commands that print secret values and names commands
# that answer the same question instead. A refusal is only as safe as what it recommends, so the
# recommended commands are read out of the module itself and run here against values that span
# lines, the shape a PEM key takes in an environment or a .env file. A line-based tool such as
# `cut -d= -f1` prints such a value's continuation lines whole; these must not.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

module="$FLOW_PLUGIN/hooks/register.ts"
recommended() { sed -n "s/^const $1 = \"\(.*\)\"\$/\1/p" "$module"; }
CHECK_SET="$(recommended CHECK_SET)"
LIST_NAMES="$(recommended LIST_NAMES)"
CHECK_KEY="$(recommended CHECK_KEY)"
for name in CHECK_SET LIST_NAMES CHECK_KEY; do
  eval "value=\$$name"
  [ -n "$value" ] && pass "register.ts declares $name" || fail "register.ts declares $name"
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
printf 'PRIVATE_KEY="-----BEGIN PRIVATE KEY-----\nSYNTHETIC_PRIVATE_KEY_BODY\n-----END PRIVATE KEY-----"\nNORMAL_KEY=synthetic-value\n' > "$work/.env"
multiline="$(printf 'line-one\nSYNTHETIC_SECRET_CONTINUATION')"

out="$(env -i PATH="$PATH" ML_SECRET="$multiline" sh -c "${CHECK_SET//NAME/ML_SECRET}" 2>&1)"
equals "CHECK_SET answers with a length" "39" "${out// /}"
absent "CHECK_SET prints no value" "SYNTHETIC" "$out"

out="$(env -i PATH="$PATH" ML_SECRET="$multiline" sh -c "$LIST_NAMES" 2>&1)"
check  "LIST_NAMES lists the variable" "ML_SECRET" "$out"
absent "LIST_NAMES prints no continuation line" "SYNTHETIC" "$out"
absent "LIST_NAMES prints no first line" "line-one" "$out"

key="${CHECK_KEY//NAME/PRIVATE_KEY}"
out="$(cd "$work" && sh -c "${key//FILE/.env}" 2>&1)"
equals "CHECK_KEY answers with a count" "1" "$out"

control="$(cd "$work" && cut -d= -f1 .env)"
check "control: cut -d= -f1 does print the key body" "SYNTHETIC_PRIVATE_KEY_BODY" "$control"

exit $fails
