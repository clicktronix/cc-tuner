# Runtime cleanup

Start a preview, a dedicated MCP server or a disposable container as a Bash call with
`run_in_background: true`, and run a container attached (`docker run --rm --init`, not `-d`).
Stop each with TaskStop when its consumers finish, including work handed back without a merge, and
release each exclusive lease the work took (`mcp__cc-tuner__peers_release <key>`). A task the guard
refuses to stop stays running; name it in the final answer. Claude Code stops the rest when the
session exits, and cc-tuner's hook stops them on `/clear`. When the user asks to keep one running
past the session, start it detached instead and name it in the final answer.
