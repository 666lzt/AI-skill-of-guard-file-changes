# Guard File Changes 使用手册

## 用途

`guard-file-changes` 是一个用于 AI Agent 项目开发的协作式文件安全 skill。它会记录 AI 的文件操作，对删除和跨工作区移动进行强保护，为普通修改保留回滚快照，并写入具备篡改检测能力的 JSONL 日志。

它不是操作系统级文件监控器。只有当 AI Agent 加载并遵守该 skill 的流程时，它才会生效。

## 存储位置

guard 默认把日志和快照存到项目外：

- 如果设置了 `CODEX_HOME`：`$env:CODEX_HOME\change-guard`
- 否则：`$HOME\.codex\change-guard`

主要目录：

- `sessions`：JSONL 审计日志。
- `snapshots`：用于回滚的文件快照。
- `locks`：协作式路径锁。
- `dir_manifests`：目录恢复清单。

## 开始会话

在执行文件变更前运行一次：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\guard-file-change.ps1 workspace-init
```

查看输出中的 `interrupted_ops`。如果存在未完成操作，先检查这些操作再继续。

如需强制指定工作区边界：

```powershell
$env:GUARD_WORKSPACE = "D:\path\to\workspace"
```

## 操作流程

### 修改已有文件

写入前先创建快照：

```powershell
$snap = powershell -ExecutionPolicy Bypass -File .\scripts\guard-file-change.ps1 snapshot-modify .\file.txt | ConvertFrom-Json
```

然后修改文件。操作完成后：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\guard-file-change.ps1 complete $snap.op_id ok
```

如果操作失败：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\guard-file-change.ps1 complete $snap.op_id failed
```

如果 `snapshot-modify` 返回 `SNAPSHOT_METADATA_ONLY`，表示该文件只记录元数据，不能回滚文件内容。

### 新增文件

创建文件后记录到 `新增区`：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\guard-file-change.ps1 log-add .\new-file.txt
```

### 删除文件或目录

删除前先执行：

```powershell
$pre = powershell -ExecutionPolicy Bypass -File .\scripts\guard-file-change.ps1 predelete .\old-file.txt | ConvertFrom-Json
```

如果输出状态为 `APPROVAL_REQUIRED`，必须先向用户请求明确确认，然后才能带 `--approved` 重新运行。

删除完成后：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\guard-file-change.ps1 complete $pre.op_id ok
```

### 移动或重命名文件

移动前先执行：

```powershell
$move = powershell -ExecutionPolicy Bypass -File .\scripts\guard-file-change.ps1 premove .\source.txt .\dest.txt | ConvertFrom-Json
```

如果需要审批，必须先询问用户，再带 `--approved` 重新运行。

移动完成后：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\guard-file-change.ps1 complete $move.op_id ok
```

## Guard 包装命令

如果希望 guard 在同一流程中完成“快照 + 操作 + complete”，使用包装命令。

写入：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\guard-file-change.ps1 guarded-write .\file.txt --content "new content"
```

删除：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\guard-file-change.ps1 guarded-delete .\old-file.txt
```

移动：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\guard-file-change.ps1 guarded-move .\source.txt .\dest.txt
```

## 回滚

查看可回滚状态：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\guard-file-change.ps1 inspect-rollback
```

查看单个文件：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\guard-file-change.ps1 inspect-rollback .\file.txt
```

恢复某个文件的最新保留快照：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\guard-file-change.ps1 restore-previous .\file.txt
```

恢复指定操作：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\guard-file-change.ps1 restore-previous <op_id>
```

如果当前文件和记录中的操作后状态不一致，脚本会拒绝静默覆盖，避免误伤用户后续修改。只有在用户明确确认后，才可以使用 `--force`。

## 敏感文件和大文件

敏感文件默认只记录元数据。常见敏感文件包括 `.env`、私钥、证书，文件名中包含 `secret`、`token`、`password`、`credential` 的文件，以及被高熵启发式判断为疑似密钥或 token 的内容。

超过 `GUARD_LARGE_FILE_THRESHOLD` 的大文件默认也只记录元数据。

只记录元数据的文件可以审计，但不能恢复内容。

## 默认保留策略

- `GUARD_LOG_KEEP_SESSIONS=50`
- `GUARD_SNAPSHOT_KEEP_DAYS=7`
- `GUARD_SNAPSHOT_KEEP_OPS=200`
- `GUARD_LARGE_DELETE_THRESHOLD=20`
- `GUARD_LARGE_FILE_THRESHOLD=20971520`
- `GUARD_ON_SNAPSHOT_FAIL=block`

只有在内容快照仍被保留且未被清除时，才能进行内容回滚。

## 退出码

- `20`：需要用户审批。
- `21`：大规模删除需要预览确认。
- `30`：快照失败。
- `31`：获取锁失败。
- `40`：回滚冲突。
- `41`：没有可恢复快照。
- `64`：命令用法错误。

## AI Agent 必须遵守的规则

- 不得在未调用 guard 的情况下执行 `Remove-Item`、`Rename-Item` 或 `Move-Item`。
- 未在当前会话获得用户明确确认时，不得传入 `--approved`。
- 修改、删除、移动操作完成后必须调用 `complete`。
- 如果文件是 metadata-only，必须告知用户该文件不能进行内容回滚。
- 如果存在更严格的 `AGENTS.md` 删除规则，必须遵守更严格的规则。
