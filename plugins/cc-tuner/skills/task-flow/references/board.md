# Boards and epics

## Epics and sub-issues

GitHub has both mechanisms natively; do not invent a title-prefix convention.

**An epic is an issue whose type is `Epic`.** Issue Types are org-level and render as a badge on the
card, so an epic is filterable in a board view. If the org has no `Epic` type yet, an org admin adds
it once alongside `Task`/`Bug`/`Feature`; until then fall back to a `[Epic]` title prefix and say so.

```bash
gh api graphql -f query='query{organization(login:"<ORG>"){issueTypes(first:20){nodes{id name}}}}'
gh issue create --repo <owner>/<repo> --title "..." --project "<PROJECT TITLE>"   # then set the type
```

**Decomposition is sub-issues**, not a checklist in the body. The parent then carries a real progress
bar (`subIssuesSummary`), and each child gets its own card, branch and PR.

```bash
gh api graphql -f query='query{repository(owner:"<o>",name:"<r>"){issue(number:<N>){
  subIssuesSummary{total completed percentCompleted} subIssues(first:50){nodes{number title state}}}}}'
```

Use an epic for independently deliverable work or phases needing separate scope decisions. A coupled
change across repositories can share one issue; multiple PRs alone do not require an epic. Use `Refs`
on partial PRs and close the shared issue only after the whole result is verified and delivered.

The branch and PR attach to the **sub-issue**. The epic closes when its children close — never link
`Closes <epic>` from a child's PR.

## Board recipes (GitHub Projects)

Boards are GitHub-only: outside GitHub the spec says `board: none`. Use these recipes only when the
repository has a configured board. With `board: none`, omit `--project` from issue creation and skip
project commands, fields and project-scope setup.

**Create an issue directly on the board (preferred):**

```bash
gh issue create --repo <owner>/<repo> --title "..." --label "..." --project "<PROJECT TITLE>"
```

`--project` takes the project **title**, not `owner/number`. Then set fields — without
Status/Priority the card sits in the default column and drops out of filtered views:

```bash
gh project list --owner <owner> --limit 100 --format json        # resolve the board TITLE -> its NUMBER
gh project view <NUMBER> --owner <owner> --format json           # project node ID (item-edit's --project-id)
gh project field-list <NUMBER> --owner <owner> --limit 100 --format json   # once per board; field + option IDs
gh project item-add <NUMBER> --owner <owner> --url <issue-url> --format json   # existing issue -> prints the item ID
gh project item-list <NUMBER> --owner <owner> --limit 500 --format json    # find a card's item ID by its content URL
gh project item-edit --project-id <PID> --id <ITEM_ID> --field-id <FID> --single-select-option-id <OID>
gh project item-edit --project-id <PID> --id <ITEM_ID> --field-id <FID> --clear   # restore a field to unset
```

Always pass `--limit` on the `list`/`field-list`/`item-list` calls: they default to **30 rows**, so
a card beyond the first 30 silently drops out of the lookup. A lookup that returns exactly its
`--limit` rows may be truncated: retry with a larger limit before concluding "not found".

`item-edit` sets **one field per call**: Status and Priority are two edits.

**When a move fails.** An empty `item-list` lookup means the card is not on the board (or the lookup
was truncated, above): add it with `item-add`, which prints the item ID, then edit that ID.
Never run `item-edit` with an empty `--id`: the flags shift and it fails with an opaque
`invalid number: PVTSSF_…`. `The single select option Id does not belong to the field` means the
cached IDs are stale (a board rebuilt or an option renamed): refresh them via `field-list`, update the
cache, retry once. Write the cache in a task commit only while no candidate is under review; after
that, use the refreshed IDs for this session and leave the file for the next task, since an edit
would make the reviewed tree dirty.

Cache the IDs from `field-list` in `.claude/rules/task-flow.local.md` the first time you fetch them:
they are stable per board.

The `gh project *` commands need the `project` token scope; without it they fail with an opaque
GraphQL error. Fix once per machine: `gh auth refresh -s project`.

**Card lifecycle:** on the board when the spec is approved; In Progress when implementation opens
after recording the prior status; In review when the PR opens, where the board has that option; Done
after the merge that **fully completes** the issue (`Closes`/`Fixes` link). A partial `Refs #N` merge
returns the card to In Progress. An epic's card follows its first and last sub-issue. `/cc-tuner:spec` and
`/cc-tuner:run` name each moment; outside them, follow the same sequence.
