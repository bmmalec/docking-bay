# DockingBay

{{ONE_PARAGRAPH_DESCRIPTION}}

## Current State

**Last session**: {{DATE}}
{{LAST_SESSION_SUMMARY}}

## Toolkit

The shared development toolkit is mounted at `/toolkit`. Start every session by reading `/toolkit/TOOLKIT.md`.

Key commands:
```bash
python3 /toolkit/rallyai/rallyai.py context --project "{{RALLYAI_PROJECT_ID}}"
python3 /toolkit/rallyai/rallyai.py list-tasks --project "{{RALLYAI_PROJECT_ID}}"
python3 /toolkit/rallyai/rallyai.py create-task --project "{{RALLYAI_PROJECT_ID}}" --title "Task" --status "todo"
python3 /toolkit/rallyai/rallyai.py session --project "{{RALLYAI_PROJECT_ID}}" --summary "Summary" --duration 60
```

## RallyAI

- **Project name**: {{RALLYAI_PROJECT_NAME}}
- **Project ID**: {{RALLYAI_PROJECT_ID}}

## Sprint Focus

1. {{SPRINT_TASK_1}}
2. {{SPRINT_TASK_2}}
3. {{SPRINT_TASK_3}}

## Architecture Decisions

| Decision | Chosen | Rejected | Why |
|----------|--------|----------|-----|
| {{DECISION_TOPIC}} | {{CHOSEN}} | {{REJECTED}} | {{RATIONALE}} |

## Rules for Claude Code

- Read `/toolkit/TOOLKIT.md` at the start of every session
- Use the toolkit RallyAI CLI for all task tracking — never raw HTTP
- Do not modify files under `/toolkit` — it is a read-only shared mount
- Run tests before committing
- Follow existing code style in the project
- Log a session summary via `rallyai.py session` at the end of significant work
- Ask before making architectural changes not covered in this file

<!-- chat-command-center:start -->
## Chat Command Center
At the end of a session that changed something, put a final line in the last
commit message: "Next: <the one next action>". If this session has the
ArtifactData tool, also check in to the Chat Command Center board
(https://claude.ai/code/artifact/545932f4-5bc9-425d-a7c9-827e67f21601):
one card in the chats collection with the session link, where it left off,
the next action, the venture and a nudge date.
<!-- chat-command-center:end -->
