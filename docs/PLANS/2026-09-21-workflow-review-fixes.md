# Fix workflow review findings

Correct the remaining findings from the 2026-09-21 cc-tuner/codex-tuner audit.

- All review diff readers include submodule updates regardless of Git configuration and disable
  external diff/text conversion. One shared command owns those options.
- Before publishing shards, validate actual packet budgets and exact candidate coverage. Refuse
  path-filter expansion or rename changes without partial stdout; explicit larger budgets may fit.
- Derive reviewer count from the accepted partition, including explicitly raised caps.
- Keep operational instructions concise; retain historical observations in existing case studies,
  without treating measurements from another agent type as current pricing evidence.
- Codex epic policy follows independently deliverable outcomes rather than repository/PR count.

Verification: regression tests for hidden submodules and file-to-directory changes must fail before
the fix; then run packet/contract tests and both repository suites. Preserve agent restrictions,
evidence reuse, partial-return recovery, isolation, and exact-SHA merge gates while shortening prose.

Changes stay in isolated worktrees. No commit, push, merge, release, or installed-plugin update.

Evidence: both full `bash tests/run.sh` suites pass; CC sharding has 63 assertions, Codex packet
tests have 16 cases. Regression inputs fail against the original inventory/path filtering and pass
after the fixes. Spec/Standards rechecks found no remaining reported blockers. Scenario anchors
and markdown links pass after retaining the existing section anchors. CC operational docs shrink
from 8039 to 5859 words; agent limits and authoritative merge gates remain intact.
