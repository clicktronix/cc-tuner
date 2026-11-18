# Grooming an issue, and reading a groom record

Read under `/cc-tuner:spec --groom <issue>`, and when an issue given to `/spec` already carries a
`cc-tuner-groom:` record.

## `--groom <issue>`

Grooming prepares an issue for later, with no branch, spec or plan and nothing committed. It needs
an issue number or URL (for free text, create the issue first). It refuses under `tracker: none`,
and under `other` unless `docs/agents/issue-tracker.md` describes comments.

The route through `/spec`: read (section 1) → interview (section 3) → tag the acceptance criteria
(section 4) → the blind-spots pass (section 5) over what was gathered → one record on the issue.
Skip section 2 and everything after the blind-spots pass. It writes nothing but that record: a term
or ADR that `domain-modeling` settles goes into the record's Decisions, for the later `/spec` to
write on its branch.

The record's first line is `cc-tuner-groom: <date>`, then **Decisions** (each with its reason),
**Acceptance criteria**, **Open questions** and **Sources**. A blind-spots `incomplete: <reason>`
goes into Open questions.

## Where the record lives, and whose record is settled

A later `/spec <issue>` treats the newest record from a maintainer as settled and interviews only
its open questions and what the code now contradicts. A record from anyone else is a proposal for
the interview.

- `gh` — an issue comment; a maintainer's has `authorAssociation` `OWNER`, `MEMBER` or `COLLABORATOR`.
- `glab` — one note on the GitLab issue; a maintainer's author has project membership with
  `access_level >= 30` and `state == "active"` (`glab api projects/:id/members/all/<user id>`).
- `local` — resolve the issue through [local-issues.md](../../task-flow/references/local-issues.md),
  then append the record under `## Comments`, without committing; a later `/spec` treats it as settled.
