---
name: agent-rules
description: Loads the applicable repository rules and linked contracts for a review or change. Use before reviewing or changing code in a repository, and when the work enters another repository or subsystem.
---

# Agent Rules

Load the repository instructions needed for a review or change. Setup owns installation.

1. Resolve each target repository, including siblings reached during the task. Read its root
   `AGENTS.override.md` or `AGENTS.md` and applicable nested instruction files. Reuse full text
   already loaded in this session; a filename, heading list, or summary is not the rule body.
2. Follow the repository's rule index when present, and also inspect the inventory and frontmatter of
   `.claude/rules/**/*.md` so an outdated index cannot hide a newly added rule. Read every rule
   without `paths`, then the full bodies of rules whose scope covers the files or behaviour being
   reviewed or changed, including planned new files. Resolve patterns relative to their owning
   project, not the plugin or shell directory. For other rule locations, follow the repository's
   own instructions.
3. Read relevant architecture, contracts, and procedures linked by those rules. If scope is
   ambiguous, read the rule before deciding whether it applies. Report missing required files or
   conflicting instructions; do not invent their contents or silently treat the gap as permission.
4. Revisit selection when the task crosses a subsystem or repository boundary. Briefly name the
   rule files read and any unresolved gap, then continue the user's task. Do not turn discovery
   into a separate approval or planning workflow.

Claude Code loads `.claude/rules` natively; do not reload bodies already supplied. Codex loads only
the project-root-to-working-directory chain, so read rule bodies explicitly. This skill is guidance,
not a gate: keep mechanically checkable invariants in the repository's tests and linters.
