---
name: guard-file-changes
description: Cooperative AI file-change safety guard for project development. Use when Codex or another AI agent will create, modify, delete, move, rename, copy, overwrite, restore, or roll back files; when work may touch paths outside the current sandbox/workspace; when audit logs, snapshots, tamper-evident JSONL records, deletion approval, or rollback safety are required.
---

# Guard File Changes

Use this skill to keep AI file operations auditable and recoverable. It is a cooperative guardrail, not an operating-system filesystem interceptor: it works only when the agent loads this skill and follows the checklist.

The guard favors low-friction writes and additions, but strongly guards deletion and cross-boundary moves. Reliable content rollback requires a retained content snapshot. Sensitive and large files are metadata-only by default, so their content cannot be restored unless the user explicitly opts into content snapshotting.

## Script

Use the bundled PowerShell script:

```powershell
.\scripts\guard-file-change.ps1 <command> ...
```

PowerShell 5.1 or 7.x is supported. The script stores logs and snapshots in:

- `$env:CODEX_HOME\change-guard` when `CODEX_HOME` is set.
- `$HOME\.codex\change-guard` otherwise.

Do not track or guard the change-guard storage directory itself.

## Required Checklist

Follow these rules exactly:

```text
AT SESSION START:
  Call guard-file-change.ps1 workspace-init.
  Review interrupted_ops before proceeding.

BEFORE Set-Content / Add-Content / overwrite / copy over existing target:
  Call guard-file-change.ps1 snapshot-modify <path>.
  Save op_id.
  If result is SNAPSHOT_METADATA_ONLY, tell the user content rollback is unavailable.
  After the operation, call guard-file-change.ps1 complete <op_id> ok|failed.

AFTER New-Item / copy to a new destination:
  Call guard-file-change.ps1 log-add <path>.

BEFORE Remove-Item:
  Call guard-file-change.ps1 predelete <path>.
  If approval is required, ask the user and pass --approved only after explicit confirmation.
  After deletion, call guard-file-change.ps1 complete <op_id> ok|failed.

BEFORE Rename-Item / Move-Item / copy-and-delete-source:
  Call guard-file-change.ps1 premove <source> <dest>.
  If approval is required, ask the user and pass --approved only after explicit confirmation.
  After the move, call guard-file-change.ps1 complete <op_id> ok|failed.

NEVER call Remove-Item, Rename-Item, or Move-Item without first calling the guard.
NEVER pass --approved without explicit user confirmation in this session.
Use guarded-write/delete/move when true snapshot-operation atomicity is required.
```

## Operation Classes

- `修改区`: overwrite, append, direct file writes, and copy to an existing target. Call `snapshot-modify` before the write and `complete` after it.
- `新增区`: new files and copy to a new target. Call `log-add` after creation.
- `删除区`: `Remove-Item` and rollback of newly added files. Call `predelete` before deletion.
- `移动区`: `Rename-Item`, `Move-Item`, or copy plus source deletion. Call `premove` before the move.

For `Copy-Item`, classify each destination independently:

- Destination absent: `新增区`.
- Destination exists: `修改区`.
- Directory copy: expand into per-file add/modify records and keep a manifest.

## Approval Rules

The script resolves the workspace once at `workspace-init`, in this order:

1. `$env:GUARD_WORKSPACE`
2. nearest ancestor containing `.git`, `.hg`, or `.svn`
3. `$env:CODEX_HOME` if it is an ancestor of the current location
4. current location at first invocation

Deletion inside the resolved workspace requires snapshot and log only by default. Deletion outside the workspace requires explicit user confirmation before `--approved`.

Move operations are checked on both sides:

- External source: approval required because the move deletes from outside the workspace.
- External destination: approval required because the move may export data outside the workspace.

Directory deletion expands to a file list. If any child resolves outside the workspace, treat the whole operation as external. If the file count exceeds `GUARD_LARGE_DELETE_THRESHOLD` (default `20`), review the preview and require confirmation.

If applicable `AGENTS.md` files contain stricter deletion rules, follow the strictest rule. Check rules from the workspace/root through the target path's parent directory.

## Rollback

Use:

```powershell
.\scripts\guard-file-change.ps1 inspect-rollback [<path>]
.\scripts\guard-file-change.ps1 restore-previous <path|op_id> [--force]
```

Default rollback is single-level by path: `restore-previous <path>` restores the latest retained content snapshot for that path. `restore-previous <op_id>` restores a specific historical operation and is advanced usage.

Before restore, the script compares the current file state with the recorded post-operation state. If the file changed after the guarded operation, it refuses silent restore. Use `--force` only after explicit user confirmation.

Sensitive and large files are metadata-only by default. When `snapshot-modify` reports `SNAPSHOT_METADATA_ONLY`, tell the user that content rollback is unavailable for that file.

Snapshot retention defaults:

- `GUARD_LOG_KEEP_SESSIONS=50`
- `GUARD_SNAPSHOT_KEEP_DAYS=7`
- `GUARD_SNAPSHOT_KEEP_OPS=200`

Rollback is guaranteed only while a content snapshot is retained and was not purged.

## Commands

- `workspace-init`: start a guard session, resolve workspace root, report interrupted operations.
- `snapshot-modify <path>`: snapshot a file before modification and return `op_id`.
- `log-add <path>`: log a newly created file after creation.
- `predelete <path> [--approved] [--confirmed]`: snapshot and approve-check a deletion.
- `premove <source> <dest> [--approved]`: snapshot and approve-check a move.
- `complete <op_id> ok|failed`: record post-operation state for rollback conflict checks.
- `inspect-rollback [<path>]`: list restorable snapshots and verify the JSONL hash chain.
- `restore-previous <path|op_id> [--force]`: restore from a retained content snapshot.
- `guarded-write <path> --content <text> [--append]`: snapshot, write, and complete in one flow.
- `guarded-delete <path> [--approved] [--confirmed]`: predelete, delete, and complete in one flow.
- `guarded-move <source> <dest> [--approved]`: premove, move, and complete in one flow.
- `purge-snapshot <op_id>`: permanently remove snapshot content for an operation.

## Safety Notes

- The JSONL log is tamper-evident with a per-session hash chain. `inspect-rollback` reports `LOG_CHAIN_BROKEN` if records were modified or truncated.
- Symlink and junction paths are resolved for classification. If link path and target path have different classifications, use the stricter result.
- Locked files are retried. If snapshot still fails, the default policy is `block`; `GUARD_ON_SNAPSHOT_FAIL=warn` allows proceeding only with an explicit warning.
- True atomicity for normal writes is available only through `guarded-write`. Plain `snapshot-modify` is a cooperative snapshot lease.
