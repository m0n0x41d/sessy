# Fixture Notes

Observed on the local machine during the foundation step:

- Claude history is JSONL with keys `display`, `pastedContents`, `project`, `timestamp`, and usually `sessionId`.
- A smaller live subset of Claude history lines omits `sessionId`, so adapter work must treat it as optional at the parse boundary.
- Claude active session files in `~/.claude/sessions` are JSON objects with `pid`, `sessionId`, `cwd`, and `startedAt`.
- Claude project storage under `~/.claude/projects` contains nested session-memory and subagent files, so later adapter work should inspect the exact per-session layout before assuming a flat transcript path.
- Codex history is JSONL with keys `session_id`, `text`, and `ts`.
- Codex session transcripts live under `~/.codex/sessions/YYYY/MM/DD/rollout-...jsonl`.

The fixtures in this directory keep those observed field names and timestamp shapes while replacing real prompts, ids, and paths with sanitized sample data.
