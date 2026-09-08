# A mutation assigned by the spec

Use only when the spec assigns a mutation. A regression already observed RED on pre-fix code and
GREEN after needs no additional mutation. The successful helper path costs three test-command runs
(baseline, mutant, restored control), including three builds when the test command is a build.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/mutate.sh" --help
bash "${CLAUDE_PLUGIN_ROOT}/scripts/mutate.sh" --expect '<what the killed test must say>' \
  <file> "<test command>" "<command that edits \$MUTATE_FILE>"
```

The helper owns verdicts, exit codes and restoration; its help describes the refusals. The
orchestrator must read the mutant log, not just `KILLED`. GREEN → RED → GREEN rules out an environment
that stayed broken, but cannot exclude a failure confined to the mutant run. A `ConnectionError`
instead of the intended assertion is not proof the guard worked. `--expect` is a filter, not proof
of cause: a traceback can echo the expected text from an assertion that never executed.

Run the assigned proof once for the guard. Repeat only if the guard or its test changes, not merely
because another commit moved HEAD. Copy the helper's output into the run log without rewriting its
verdict or figures. Keep its failure evidence and recovery instructions if restoration fails.

Historical reason: a live run spent ten builds re-proving one unchanged budget; other runs reported
a no-op mutant as survived or changed correct measurements while transcribing them. Preserve the
observations and test the intended failure, rather than buying another copy of the same proof.
