# Guard File Changes User Manual

## Purpose

`guard-file-changes` is a cooperative safety skill for AI-assisted development. It records AI file operations, protects deletion and cross-boundary moves, keeps rollback snapshots for normal file modifications, and writes tamper-evident JSONL logs.

It is not an operating-system file monitor. It works when the AI agent loads the skill and follows its checklist.

## Storage

The guard stores logs and snapshots outside the project by default:

- `$env:CODEX_HOME\change-guard` when `CODEX_HOME` is set.
- `$HOME\.codex\change-guard` otherwise.

Main storage folders:

- `sessions`: JSONL audit logs.
- `snapshots`: file snapshots for rollback.
- `locks`: cooperative per-path lock files.
- `dir_manifests`: directory restore manifests.

## Start A Session

Run once before file-changing work:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\guard-file-change.ps1 workspace-init
```

Review `interrupted_ops` in the output. If any are listed, inspect them before continuing.

To force a workspace boundary:

```powershell
$env:GUARD_WORKSPACE = "D:\path\to\workspace"
```

## Operation Workflow

### Modify an existing file

Before writing:

```powershell
$snap = powershell -ExecutionPolicy Bypass -File .\scripts\guard-file-change.ps1 snapshot-modify .\file.txt | ConvertFrom-Json
```

Then modify the file. After the operation:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\guard-file-change.ps1 complete $snap.op_id ok
```

If the operation failed:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\guard-file-change.ps1 complete $snap.op_id failed
```

If `snapshot-modify` returns `SNAPSHOT_METADATA_ONLY`, content rollback is unavailable for that file.

### Add a new file

After creating the file:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\guard-file-change.ps1 log-add .\new-file.txt
```

### Delete a file or directory

Before deletion:

```powershell
$pre = powershell -ExecutionPolicy Bypass -File .\scripts\guard-file-change.ps1 predelete .\old-file.txt | ConvertFrom-Json
```

If the output status is `APPROVAL_REQUIRED`, ask the user for explicit confirmation, then rerun with `--approved`.

After deletion:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\guard-file-change.ps1 complete $pre.op_id ok
```

### Move or rename a file

Before moving:

```powershell
$move = powershell -ExecutionPolicy Bypass -File .\scripts\guard-file-change.ps1 premove .\source.txt .\dest.txt | ConvertFrom-Json
```

If approval is required, ask the user before rerunning with `--approved`.

After the move:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\guard-file-change.ps1 complete $move.op_id ok
```

## Guarded Wrapper Commands

Use wrapper commands when you want the guard to perform the operation in one flow.

Write:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\guard-file-change.ps1 guarded-write .\file.txt --content "new content"
```

Delete:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\guard-file-change.ps1 guarded-delete .\old-file.txt
```

Move:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\guard-file-change.ps1 guarded-move .\source.txt .\dest.txt
```

## Rollback

Inspect available rollback states:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\guard-file-change.ps1 inspect-rollback
```

Inspect one file:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\guard-file-change.ps1 inspect-rollback .\file.txt
```

Restore the latest retained snapshot for a file:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\guard-file-change.ps1 restore-previous .\file.txt
```

Restore a specific operation:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\guard-file-change.ps1 restore-previous <op_id>
```

If the current file differs from the recorded post-operation state, restore is blocked to avoid overwriting later user changes. Use `--force` only after explicit user confirmation.

## Sensitive And Large Files

Sensitive files are metadata-only by default. Examples include `.env`, private keys, certificates, files with `secret`, `token`, `password`, or `credential` in their names, and high-entropy token-like content.

Large files above `GUARD_LARGE_FILE_THRESHOLD` default to metadata-only snapshots.

Metadata-only records support audit history but not content rollback.

## Retention Defaults

- `GUARD_LOG_KEEP_SESSIONS=50`
- `GUARD_SNAPSHOT_KEEP_DAYS=7`
- `GUARD_SNAPSHOT_KEEP_OPS=200`
- `GUARD_LARGE_DELETE_THRESHOLD=20`
- `GUARD_LARGE_FILE_THRESHOLD=20971520`
- `GUARD_ON_SNAPSHOT_FAIL=block`

Rollback is available only while a content snapshot is retained.

## Exit Codes

- `20`: approval required.
- `21`: large delete preview confirmation required.
- `30`: snapshot failed.
- `31`: lock acquisition failed.
- `40`: rollback conflict.
- `41`: no restorable snapshot.
- `64`: usage error.

## Important Rules For AI Agents

- Never call `Remove-Item`, `Rename-Item`, or `Move-Item` without calling the guard first.
- Never pass `--approved` unless the user explicitly confirmed it in the current session.
- Always call `complete` after guarded modify/delete/move operations.
- Tell the user when a file is metadata-only and cannot be content-restored.
- Follow stricter `AGENTS.md` deletion rules when present.
