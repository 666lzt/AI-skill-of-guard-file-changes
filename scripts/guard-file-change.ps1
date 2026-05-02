$ErrorActionPreference = "Stop"

$Command = $null
$Rest = @()
if ($args.Count -gt 0) {
    $Command = [string]$args[0]
    if ($args.Count -gt 1) {
        $Rest = @($args | Select-Object -Skip 1)
    }
}
if ($env:GUARD_DEBUG_ARGS) {
    [ordered]@{ command = $Command; rest = @($Rest) } | ConvertTo-Json -Depth 4
}

$ExitApprovalRequired = 20
$ExitConfirmationRequired = 21
$ExitSnapshotFailed = 30
$ExitLockFailed = 31
$ExitConflict = 40
$ExitNotRestorable = 41
$ExitUsage = 64

function New-Utf8NoBomEncoding {
    return New-Object System.Text.UTF8Encoding($false)
}

function Write-TextNoBom {
    param([string]$Path, [string]$Text)
    $parent = [System.IO.Path]::GetDirectoryName($Path)
    if ($parent -and -not [System.IO.Directory]::Exists($parent)) {
        [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Text, (New-Utf8NoBomEncoding))
}

function Append-TextNoBom {
    param([string]$Path, [string]$Text)
    $parent = [System.IO.Path]::GetDirectoryName($Path)
    if ($parent -and -not [System.IO.Directory]::Exists($parent)) {
        [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    [System.IO.File]::AppendAllText($Path, $Text, (New-Utf8NoBomEncoding))
}

function ConvertTo-JsonLine {
    param([object]$Value, [int]$Depth = 12)
    return ($Value | ConvertTo-Json -Depth $Depth -Compress)
}

function Get-Sha256Text {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = (New-Utf8NoBomEncoding).GetBytes($Text)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-Sha256File {
    param([string]$Path)
    if (-not [System.IO.File]::Exists($Path)) {
        return $null
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace("-", "").ToLowerInvariant()
    }
    finally {
        if ($stream) { $stream.Dispose() }
        $sha.Dispose()
    }
}

function Get-PathHash {
    param([string]$Path)
    return Get-Sha256Text -Text $Path
}

function Get-IsoNow {
    return ([DateTime]::UtcNow.ToString("o"))
}

function Get-GuardRoot {
    if ($env:CODEX_HOME) {
        return [System.IO.Path]::Combine($env:CODEX_HOME, "change-guard")
    }
    return [System.IO.Path]::Combine($HOME, ".codex", "change-guard")
}

function Ensure-GuardDirs {
    $root = Get-GuardRoot
    foreach ($name in @("sessions", "snapshots", "locks", "dir_manifests", "state")) {
        [System.IO.Directory]::CreateDirectory([System.IO.Path]::Combine($root, $name)) | Out-Null
    }
    return $root
}

function Resolve-PathForGuard {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Path is required."
    }
    if ([System.IO.File]::Exists($Path) -or [System.IO.Directory]::Exists($Path)) {
        return ([System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).ProviderPath))
    }
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath([System.IO.Path]::Combine((Get-Location).ProviderPath, $Path))
}

function ConvertTo-LongPath {
    param([string]$Path)
    $isWindowsPlatform = ([Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
    if (-not $isWindowsPlatform) {
        return $Path
    }
    if ($Path.StartsWith("\\?\")) {
        return $Path
    }
    if ($Path.StartsWith("\\")) {
        $unc = $Path.TrimStart("\")
        if ($Path.Length -gt 200) {
            return "\\?\UNC\$unc"
        }
        return $Path
    }
    if ($Path.Length -gt 200) {
        return "\\?\$Path"
    }
    return $Path
}

function Get-FileState {
    param([string]$Path)
    $resolved = Resolve-PathForGuard -Path $Path
    if ([System.IO.File]::Exists($resolved)) {
        $item = Get-Item -LiteralPath $resolved -Force
        return [ordered]@{
            path = $resolved
            exists = $true
            is_dir = $false
            hash = Get-Sha256File -Path $resolved
            size = [int64]$item.Length
            mtime = $item.LastWriteTimeUtc.ToString("o")
            ctime = $item.CreationTimeUtc.ToString("o")
            attrs = ([int]$item.Attributes)
        }
    }
    if ([System.IO.Directory]::Exists($resolved)) {
        $item = Get-Item -LiteralPath $resolved -Force
        return [ordered]@{
            path = $resolved
            exists = $true
            is_dir = $true
            hash = $null
            size = $null
            mtime = $item.LastWriteTimeUtc.ToString("o")
            ctime = $item.CreationTimeUtc.ToString("o")
            attrs = ([int]$item.Attributes)
        }
    }
    return [ordered]@{
        path = $resolved
        exists = $false
        is_dir = $false
        hash = $null
        size = $null
        mtime = $null
        ctime = $null
        attrs = $null
    }
}

function Test-AncestorPath {
    param([string]$Ancestor, [string]$Path)
    $a = [System.IO.Path]::GetFullPath($Ancestor).TrimEnd("\", "/")
    $p = [System.IO.Path]::GetFullPath($Path).TrimEnd("\", "/")
    if ($p.Equals($a, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    return $p.StartsWith($a + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
}

function Find-VcsRoot {
    param([string]$StartPath)
    $dir = Get-Item -LiteralPath $StartPath -Force
    if (-not $dir.PSIsContainer) {
        $dir = $dir.Directory
    }
    while ($dir) {
        foreach ($marker in @(".git", ".hg", ".svn")) {
            if ([System.IO.Directory]::Exists([System.IO.Path]::Combine($dir.FullName, $marker)) -or [System.IO.File]::Exists([System.IO.Path]::Combine($dir.FullName, $marker))) {
                return $dir.FullName
            }
        }
        $dir = $dir.Parent
    }
    return $null
}

function Resolve-WorkspaceRoot {
    $cwd = (Get-Location).ProviderPath
    if ($env:GUARD_WORKSPACE) {
        return Resolve-PathForGuard -Path $env:GUARD_WORKSPACE
    }
    $vcs = Find-VcsRoot -StartPath $cwd
    if ($vcs) {
        return Resolve-PathForGuard -Path $vcs
    }
    if ($env:CODEX_HOME) {
        $codexHome = Resolve-PathForGuard -Path $env:CODEX_HOME
        if (Test-AncestorPath -Ancestor $codexHome -Path $cwd) {
            return $codexHome
        }
    }
    return Resolve-PathForGuard -Path $cwd
}

function Get-ActiveSessionPath {
    return [System.IO.Path]::Combine((Get-GuardRoot), "state", "active-session.json")
}

function Get-SessionLogPath {
    param([string]$SessionId)
    return [System.IO.Path]::Combine((Get-GuardRoot), "sessions", "$SessionId.jsonl")
}

function Read-JsonFile {
    param([string]$Path)
    if (-not [System.IO.File]::Exists($Path)) {
        return $null
    }
    $text = [System.IO.File]::ReadAllText($Path, (New-Utf8NoBomEncoding))
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }
    return $text | ConvertFrom-Json
}

function Write-JsonFile {
    param([string]$Path, [object]$Value)
    Write-TextNoBom -Path $Path -Text ((ConvertTo-JsonLine -Value $Value -Depth 16) + [Environment]::NewLine)
}

function Get-LastRecordHash {
    param([string]$LogPath)
    if (-not [System.IO.File]::Exists($LogPath)) {
        return "GENESIS"
    }
    $last = "GENESIS"
    foreach ($line in [System.IO.File]::ReadLines($LogPath, (New-Utf8NoBomEncoding))) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $obj = $line | ConvertFrom-Json
            if ($obj.record_hash) {
                $last = [string]$obj.record_hash
            }
        }
        catch {
            continue
        }
    }
    return $last
}

function Acquire-LogLock {
    param([string]$LogPath)
    $lockPath = "$LogPath.lock"
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $parent = [System.IO.Path]::GetDirectoryName($lockPath)
            if ($parent -and -not [System.IO.Directory]::Exists($parent)) {
                [System.IO.Directory]::CreateDirectory($parent) | Out-Null
            }
            return [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        }
        catch {
            Start-Sleep -Milliseconds 100
        }
    }
    throw "Unable to acquire log lock for $LogPath within 5 seconds."
}

function Append-LogRecord {
    param([object]$Session, [System.Collections.Specialized.OrderedDictionary]$Record)
    $logPath = Get-SessionLogPath -SessionId $Session.session_id
    $lock = $null
    try {
        $lock = Acquire-LogLock -LogPath $logPath
        if (-not $Record.Contains("timestamp")) {
            $Record["timestamp"] = Get-IsoNow
        }
        if (-not $Record.Contains("session_id")) {
            $Record["session_id"] = $Session.session_id
        }
        $Record["prev_record_hash"] = Get-LastRecordHash -LogPath $logPath
        $jsonWithoutHash = ConvertTo-JsonLine -Value $Record -Depth 18
        $Record["record_hash"] = Get-Sha256Text -Text $jsonWithoutHash
        $json = ConvertTo-JsonLine -Value $Record -Depth 18
        Append-TextNoBom -Path $logPath -Text ($json + [Environment]::NewLine)
        return $Record
    }
    finally {
        if ($lock) { $lock.Dispose() }
    }
}

function Read-SessionRecords {
    param([object]$Session, [switch]$VerifyChain, [switch]$LogErrors)
    $logPath = Get-SessionLogPath -SessionId $Session.session_id
    $records = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $expectedPrev = "GENESIS"
    $lineNo = 0
    if (-not [System.IO.File]::Exists($logPath)) {
        return @{ records = $records; errors = $errors; chain_ok = $true }
    }
    foreach ($line in [System.IO.File]::ReadLines($logPath, (New-Utf8NoBomEncoding))) {
        $lineNo++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $obj = $line | ConvertFrom-Json
            if ($VerifyChain) {
                if ([string]$obj.prev_record_hash -ne $expectedPrev) {
                    [void]$errors.Add("LOG_CHAIN_BROKEN at line $lineNo")
                }
                $copy = [ordered]@{}
                foreach ($prop in $obj.PSObject.Properties) {
                    if ($prop.Name -ne "record_hash") {
                        $copy[$prop.Name] = $prop.Value
                    }
                }
                $rehash = Get-Sha256Text -Text (ConvertTo-JsonLine -Value $copy -Depth 18)
                if ($rehash -ne [string]$obj.record_hash) {
                    [void]$errors.Add("LOG_CHAIN_BROKEN hash mismatch at line $lineNo")
                }
                if ($obj.record_hash) {
                    $expectedPrev = [string]$obj.record_hash
                }
            }
            [void]$records.Add($obj)
        }
        catch {
            [void]$errors.Add("log_parse_error at line $lineNo")
            if ($LogErrors) {
                Append-LogRecord -Session $Session -Record ([ordered]@{
                    type = "log_parse_error"
                    line = $lineNo
                    error = $_.Exception.Message
                }) | Out-Null
            }
        }
    }
    return @{ records = $records; errors = $errors; chain_ok = ($errors.Count -eq 0) }
}

function Ensure-Session {
    Ensure-GuardDirs | Out-Null
    $activePath = Get-ActiveSessionPath
    $session = Read-JsonFile -Path $activePath
    if (-not $session) {
        return Invoke-WorkspaceInit -Silent
    }
    $cwd = (Get-Location).ProviderPath
    if (-not (Test-AncestorPath -Ancestor $session.workspace_root -Path $cwd)) {
        Append-LogRecord -Session $session -Record ([ordered]@{
            type = "workspace_drift_warning"
            cwd = $cwd
            workspace_root = $session.workspace_root
        }) | Out-Null
    }
    return $session
}

function Get-EnvInt {
    param([string]$Name, [int]$Default)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $Default
    }
    $parsed = 0
    if ([int]::TryParse($value, [ref]$parsed)) {
        return $parsed
    }
    return $Default
}

function Test-GuardStoragePath {
    param([string]$Path)
    $root = Get-GuardRoot
    return Test-AncestorPath -Ancestor $root -Path $Path
}

function Test-UncPath {
    param([string]$Path)
    return $Path.StartsWith("\\")
}

function Test-InternalPath {
    param([object]$Session, [string]$Path)
    $resolved = Resolve-PathForGuard -Path $Path
    if ((Test-UncPath -Path $resolved) -and -not ($env:GUARD_WORKSPACE -and (Test-AncestorPath -Ancestor $Session.workspace_root -Path $resolved))) {
        return $false
    }
    return Test-AncestorPath -Ancestor $Session.workspace_root -Path $resolved
}

function Get-ApplicableAgentsFiles {
    param([object]$Session, [string]$TargetPath)
    $files = New-Object System.Collections.ArrayList
    $root = [System.IO.Path]::GetFullPath($Session.workspace_root).TrimEnd("\", "/")
    $target = Resolve-PathForGuard -Path $TargetPath
    $dir = $target
    if ([System.IO.File]::Exists($target)) {
        $dir = [System.IO.Path]::GetDirectoryName($target)
    }
    elseif (-not [System.IO.Directory]::Exists($target)) {
        $dir = [System.IO.Path]::GetDirectoryName($target)
        if (-not $dir) { $dir = $root }
    }
    if (-not (Test-AncestorPath -Ancestor $root -Path $dir)) {
        $candidate = [System.IO.Path]::Combine($root, "AGENTS.md")
        if ([System.IO.File]::Exists($candidate)) { [void]$files.Add($candidate) }
        return $files
    }
    $chain = New-Object System.Collections.ArrayList
    $currentInfo = Get-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
    if (-not $currentInfo) {
        $currentInfo = Get-Item -LiteralPath ([System.IO.Path]::GetDirectoryName($dir)) -Force -ErrorAction SilentlyContinue
    }
    while ($currentInfo -and (Test-AncestorPath -Ancestor $root -Path $currentInfo.FullName)) {
        [void]$chain.Add($currentInfo.FullName)
        if ($currentInfo.FullName.TrimEnd("\", "/").Equals($root, [System.StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $currentInfo = $currentInfo.Parent
    }
    foreach ($folder in @($chain | Sort-Object Length)) {
        $candidate = [System.IO.Path]::Combine($folder, "AGENTS.md")
        if ([System.IO.File]::Exists($candidate)) { [void]$files.Add($candidate) }
    }
    return $files
}

function Test-StrictDeleteRule {
    param([object]$Session, [string]$TargetPath)
    foreach ($agents in (Get-ApplicableAgentsFiles -Session $Session -TargetPath $TargetPath)) {
        try {
            $text = [System.IO.File]::ReadAllText($agents, (New-Utf8NoBomEncoding))
            if (($text -match "删除|delete|Remove-Item") -and ($text -match "许可|批准|确认|permission|approval|confirm")) {
                return $true
            }
        }
        catch {
            continue
        }
    }
    return $false
}

function Test-SensitiveName {
    param([string]$Path)
    $name = [System.IO.Path]::GetFileName($Path)
    $patterns = @(
        ".env", ".env.*", "*.pem", "*.key", "*.p12", "*.pfx", "*.cer", "*.crt", "*.der",
        "id_rsa", "id_ed25519", "id_ecdsa", "*.ppk",
        "*secret*", "*credential*", "*token*", "*password*", "*passwd*", "*apikey*",
        "secrets.json", "secrets.yaml", "secrets.yml"
    )
    foreach ($pattern in $patterns) {
        if ($name -like $pattern) {
            return $true
        }
    }
    return $false
}

function Get-ShannonEntropy {
    param([byte[]]$Bytes)
    if (-not $Bytes -or $Bytes.Length -eq 0) { return 0.0 }
    $counts = @{}
    foreach ($b in $Bytes) {
        $key = [int]$b
        if (-not $counts.ContainsKey($key)) { $counts[$key] = 0 }
        $counts[$key]++
    }
    $entropy = 0.0
    foreach ($count in $counts.Values) {
        $p = [double]$count / [double]$Bytes.Length
        $entropy -= $p * ([Math]::Log($p, 2))
    }
    return $entropy
}

function Test-SensitiveContent {
    param([string]$Path)
    if (-not [System.IO.File]::Exists($Path)) { return $false }
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $length = [Math]::Min(4096, [int]$stream.Length)
        $buffer = New-Object byte[] $length
        [void]$stream.Read($buffer, 0, $length)
        $entropy = Get-ShannonEntropy -Bytes $buffer
        $text = (New-Utf8NoBomEncoding).GetString($buffer)
        return ($entropy -gt 5.5 -and $text -match "\S{40,}")
    }
    catch {
        return $false
    }
    finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Acquire-PathLease {
    param([string]$Path)
    $guardRoot = Ensure-GuardDirs
    $lockPath = [System.IO.Path]::Combine($guardRoot, "locks", ((Get-PathHash -Path $Path) + ".lock"))
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            return [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        }
        catch {
            Start-Sleep -Milliseconds 100
        }
    }
    throw "Unable to acquire lock for $Path within 5 seconds."
}

function Copy-WithRetry {
    param([string]$Source, [string]$Destination)
    $last = $null
    for ($i = 0; $i -lt 3; $i++) {
        try {
            [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($Destination)) | Out-Null
            [System.IO.File]::Copy((ConvertTo-LongPath -Path $Source), (ConvertTo-LongPath -Path $Destination), $true)
            return
        }
        catch {
            $last = $_
            Start-Sleep -Milliseconds 500
        }
    }
    throw $last
}

function Get-SnapshotPolicy {
    $policy = $env:GUARD_ON_SNAPSHOT_FAIL
    if ([string]::IsNullOrWhiteSpace($policy)) { return "block" }
    if ($policy -notin @("block", "warn")) { return "block" }
    return $policy
}

function New-Snapshot {
    param(
        [object]$Session,
        [string]$Path,
        [string]$OperationType = "snapshot",
        [string]$OpId,
        [switch]$AllowSensitiveContent,
        [switch]$AllowLargeContent
    )
    $resolved = Resolve-PathForGuard -Path $Path
    if (Test-GuardStoragePath -Path $resolved) {
        throw "Refusing to snapshot guard storage path: $resolved"
    }
    if (-not $OpId) { $OpId = [guid]::NewGuid().ToString() }
    $lease = $null
    try {
        $lease = Acquire-PathLease -Path $resolved
    }
    catch {
        Append-LogRecord -Session $Session -Record ([ordered]@{
            type = "lock_failed"
            op_id = $OpId
            path = $resolved
            error = $_.Exception.Message
        }) | Out-Null
        throw
    }

    try {
        $state = Get-FileState -Path $resolved
        $contentSnapshotted = $false
        $snapshotRef = $null
        $sensitiveReason = $null
        $linkInfo = $null
        $largeThreshold = [int64](Get-EnvInt -Name "GUARD_LARGE_FILE_THRESHOLD" -Default (20 * 1024 * 1024))

        if ($state.exists -and -not $state.is_dir) {
            $item = Get-Item -LiteralPath $resolved -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                $linkInfo = [ordered]@{
                    is_link = $true
                    link_type = "reparse_point"
                    target = $item.Target
                }
                $sensitiveReason = "link_metadata_only"
            }
            elseif ((Test-SensitiveName -Path $resolved) -and -not $AllowSensitiveContent) {
                $sensitiveReason = "sensitive_filename"
            }
            elseif ((Test-SensitiveContent -Path $resolved) -and -not $AllowSensitiveContent) {
                $sensitiveReason = "sensitive_entropy"
                Append-LogRecord -Session $Session -Record ([ordered]@{
                    type = "sensitive_detected_by_entropy"
                    op_id = $OpId
                    path = $resolved
                }) | Out-Null
            }
            elseif (($state.size -gt $largeThreshold) -and -not $AllowLargeContent) {
                $sensitiveReason = "large_file"
            }

            if (-not $sensitiveReason) {
                $ext = [System.IO.Path]::GetExtension($resolved)
                if ([string]::IsNullOrEmpty($ext)) { $ext = ".bin" }
                $snapshotDir = [System.IO.Path]::Combine((Get-GuardRoot), "snapshots", $Session.session_id, $OpId)
                [System.IO.Directory]::CreateDirectory($snapshotDir) | Out-Null
                $contentName = "content$ext"
                $snapshotPath = [System.IO.Path]::Combine($snapshotDir, $contentName)
                Copy-WithRetry -Source $resolved -Destination $snapshotPath
                $snapshotRef = [System.IO.Path]::Combine($Session.session_id, $OpId, $contentName)
                $contentSnapshotted = $true
                $meta = [ordered]@{
                    path = $resolved
                    hash = $state.hash
                    size = $state.size
                    mtime = $state.mtime
                    ctime = $state.ctime
                    attrs = $state.attrs
                    snapshot_ref = $snapshotRef
                    link = $linkInfo
                }
                Write-JsonFile -Path ([System.IO.Path]::Combine($snapshotDir, "meta.json")) -Value $meta
            }
        }

        $record = Append-LogRecord -Session $Session -Record ([ordered]@{
            type = $OperationType
            op_id = $OpId
            path = $resolved
            exists = $state.exists
            is_dir = $state.is_dir
            hash = $state.hash
            size = $state.size
            mtime = $state.mtime
            ctime = $state.ctime
            attrs = $state.attrs
            content_snapshotted = $contentSnapshotted
            snapshot_ref = $snapshotRef
            metadata_only_reason = $sensitiveReason
            link = $linkInfo
        })
        return $record
    }
    catch {
        Append-LogRecord -Session $Session -Record ([ordered]@{
            type = "snapshot_failed"
            op_id = $OpId
            path = $resolved
            error = $_.Exception.Message
            policy = (Get-SnapshotPolicy)
        }) | Out-Null
        if ((Get-SnapshotPolicy) -eq "warn") {
            return Append-LogRecord -Session $Session -Record ([ordered]@{
                type = $OperationType
                op_id = $OpId
                path = $resolved
                content_snapshotted = $false
                metadata_only_reason = "snapshot_failed_warn"
            })
        }
        throw
    }
    finally {
        if ($lease) { $lease.Dispose() }
    }
}

function Get-InterruptedOps {
    param([object]$Session)
    $parsed = Read-SessionRecords -Session $Session
    $started = @{}
    $completed = @{}
    foreach ($r in $parsed.records) {
        if ($r.op_id -and $r.type -in @("snapshot", "predelete", "premove")) {
            $started[[string]$r.op_id] = $true
        }
        if ($r.op_id -and $r.type -eq "complete") {
            $completed[[string]$r.op_id] = $true
        }
    }
    $interrupted = New-Object System.Collections.ArrayList
    foreach ($key in $started.Keys) {
        if (-not $completed.ContainsKey($key)) {
            [void]$interrupted.Add($key)
        }
    }
    return $interrupted
}

function Invoke-Prune {
    param([object]$Session)
    $root = Ensure-GuardDirs
    $keepSessions = Get-EnvInt -Name "GUARD_LOG_KEEP_SESSIONS" -Default 50
    $keepDays = Get-EnvInt -Name "GUARD_SNAPSHOT_KEEP_DAYS" -Default 7
    $keepOps = Get-EnvInt -Name "GUARD_SNAPSHOT_KEEP_OPS" -Default 200
    $sessionsDir = [System.IO.Path]::Combine($root, "sessions")
    $logs = Get-ChildItem -LiteralPath $sessionsDir -Filter "*.jsonl" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending
    $expiredLogs = @($logs | Select-Object -Skip $keepSessions)
    foreach ($log in $expiredLogs) {
        if ($log.BaseName -eq $Session.session_id) { continue }
        try { Remove-Item -LiteralPath $log.FullName -Force } catch {}
    }
    $snapRoot = [System.IO.Path]::Combine($root, "snapshots")
    if (-not [System.IO.Directory]::Exists($snapRoot)) { return }
    $cutoff = [DateTime]::UtcNow.AddDays(-1 * $keepDays)
    $snapshots = Get-ChildItem -LiteralPath $snapRoot -Directory -Recurse -ErrorAction SilentlyContinue | Where-Object {
        $_.FullName -match "[\\/]snapshots[\\/][^\\/]+[\\/][^\\/]+$"
    } | Sort-Object LastWriteTimeUtc -Descending
    $index = 0
    foreach ($snap in $snapshots) {
        $index++
        if ($snap.FullName -like "*\$($Session.session_id)\*") { continue }
        if ($snap.LastWriteTimeUtc -gt $cutoff -and $index -le $keepOps) { continue }
        try { Remove-Item -LiteralPath $snap.FullName -Recurse -Force } catch {}
    }
}

function Invoke-WorkspaceInit {
    param([switch]$Silent)
    $root = Ensure-GuardDirs
    $session = [ordered]@{
        session_id = [guid]::NewGuid().ToString()
        workspace_root = (Resolve-WorkspaceRoot)
        guard_root = $root
        started_at = Get-IsoNow
    }
    Write-JsonFile -Path (Get-ActiveSessionPath) -Value $session
    Append-LogRecord -Session $session -Record ([ordered]@{
        type = "session_start"
        workspace_root = $session.workspace_root
        guard_root = $root
        ps_version = $PSVersionTable.PSVersion.ToString()
        cwd = (Get-Location).ProviderPath
    }) | Out-Null
    if ($PSVersionTable.PSVersion.Major -lt 5) {
        Append-LogRecord -Session $session -Record ([ordered]@{
            type = "environment_warning"
            warning = "PowerShell 5.1 or 7.x is required."
            ps_version = $PSVersionTable.PSVersion.ToString()
        }) | Out-Null
    }
    $interrupted = Get-InterruptedOps -Session $session
    if ($interrupted.Count -gt 0) {
        Append-LogRecord -Session $session -Record ([ordered]@{
            type = "session_recovery"
            interrupted_ops = @($interrupted)
        }) | Out-Null
    }
    Invoke-Prune -Session $session
    if (-not $Silent) {
        [ordered]@{
            ok = $true
            session_id = $session.session_id
            workspace_root = $session.workspace_root
            guard_root = $root
            interrupted_ops = @($interrupted)
        } | ConvertTo-Json -Depth 8
        return
    }
    return $session
}

function Get-ArgValue {
    param([Alias("Args")][string[]]$ArgList, [string]$Name)
    for ($i = 0; $i -lt $ArgList.Count; $i++) {
        if ($ArgList[$i] -eq $Name -and ($i + 1) -lt $ArgList.Count) {
            return $ArgList[$i + 1]
        }
    }
    return $null
}

function Test-Flag {
    param([Alias("Args")][string[]]$ArgList, [string]$Name)
    return ($ArgList -contains $Name)
}

function Require-PathArg {
    param([Alias("Args")][string[]]$ArgList, [string]$Usage)
    foreach ($arg in $ArgList) {
        if (-not $arg.StartsWith("--")) {
            return $arg
        }
    }
    throw $Usage
}

function Invoke-SnapshotModify {
    $session = Ensure-Session
    $path = Require-PathArg -Args $Rest -Usage "Usage: snapshot-modify <path>"
    try {
        $record = New-Snapshot -Session $session -Path $path -OperationType "snapshot"
        $status = "OK"
        if (-not $record.content_snapshotted) { $status = "SNAPSHOT_METADATA_ONLY" }
        [ordered]@{
            status = $status
            op_id = $record.op_id
            path = $record.path
            content_snapshotted = $record.content_snapshotted
            metadata_only_reason = $record.metadata_only_reason
        } | ConvertTo-Json -Depth 8
    }
    catch {
        Write-Error $_.Exception.Message
        exit $ExitSnapshotFailed
    }
}

function Invoke-LogAdd {
    $session = Ensure-Session
    $path = Require-PathArg -Args $Rest -Usage "Usage: log-add <path>"
    $state = Get-FileState -Path $path
    $opId = [guid]::NewGuid().ToString()
    Append-LogRecord -Session $session -Record ([ordered]@{
        type = "add"
        op_id = $opId
        path = $state.path
        exists = $state.exists
        is_dir = $state.is_dir
        hash = $state.hash
        size = $state.size
        mtime = $state.mtime
        ctime = $state.ctime
        attrs = $state.attrs
    }) | Out-Null
    [ordered]@{ status = "OK"; op_id = $opId; path = $state.path } | ConvertTo-Json -Depth 6
}

function Expand-DirectoryFiles {
    param([object]$Session, [string]$Path)
    $result = New-Object System.Collections.ArrayList
    $visited = @{}
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue((Resolve-PathForGuard -Path $Path))
    while ($queue.Count -gt 0) {
        $dir = [string]$queue.Dequeue()
        $real = Resolve-PathForGuard -Path $dir
        $hash = Get-PathHash -Path $real
        if ($visited.ContainsKey($hash)) {
            Append-LogRecord -Session $Session -Record ([ordered]@{
                type = "circular_symlink_detected"
                path = $real
            }) | Out-Null
            continue
        }
        $visited[$hash] = $true
        foreach ($child in Get-ChildItem -LiteralPath $real -Force) {
            if ($child.PSIsContainer) {
                $queue.Enqueue($child.FullName)
            }
            else {
                [void]$result.Add($child.FullName)
            }
        }
    }
    return $result
}

function Save-DirectoryManifest {
    param([string]$OpId, [string]$RootPath)
    $manifestPath = [System.IO.Path]::Combine((Get-GuardRoot), "dir_manifests", "$OpId.json")
    $dirs = New-Object System.Collections.ArrayList
    if ([System.IO.Directory]::Exists($RootPath)) {
        foreach ($dir in Get-ChildItem -LiteralPath $RootPath -Recurse -Directory -Force -ErrorAction SilentlyContinue) {
            [void]$dirs.Add((Resolve-PathForGuard -Path $dir.FullName))
        }
        [void]$dirs.Add((Resolve-PathForGuard -Path $RootPath))
    }
    Write-JsonFile -Path $manifestPath -Value ([ordered]@{ root = (Resolve-PathForGuard -Path $RootPath); dirs = @($dirs) })
    return $manifestPath
}

function Invoke-PreDelete {
    param([switch]$ReturnOnly)
    $session = Ensure-Session
    $path = Require-PathArg -Args $Rest -Usage "Usage: predelete <path> [--approved] [--confirmed]"
    $approved = Test-Flag -Args $Rest -Name "--approved"
    $confirmed = Test-Flag -Args $Rest -Name "--confirmed"
    $resolved = Resolve-PathForGuard -Path $path
    $opId = [guid]::NewGuid().ToString()
    $isInternal = Test-InternalPath -Session $session -Path $resolved
    $strict = Test-StrictDeleteRule -Session $session -TargetPath $resolved
    if ((-not $isInternal -or $strict) -and -not $approved) {
        Append-LogRecord -Session $session -Record ([ordered]@{
            type = "approval_required"
            op_id = $opId
            operation = "delete"
            path = $resolved
            internal = $isInternal
            strict_agents_rule = $strict
        }) | Out-Null
        $message = "Deletion approval required for $resolved. Ask the user, then rerun with --approved."
        if ($ReturnOnly) { throw $message }
        [ordered]@{
            status = "APPROVAL_REQUIRED"
            op_id = $opId
            operation = "delete"
            path = $resolved
            internal = $isInternal
            strict_agents_rule = $strict
            message = $message
        } | ConvertTo-Json -Depth 8
        exit $ExitApprovalRequired
    }

    $files = New-Object System.Collections.ArrayList
    $isDir = [System.IO.Directory]::Exists($resolved)
    $manifestRef = $null
    if ($isDir) {
        $manifestRef = Save-DirectoryManifest -OpId $opId -RootPath $resolved
        $expanded = Expand-DirectoryFiles -Session $session -Path $resolved
        foreach ($file in $expanded) { [void]$files.Add($file) }
        foreach ($file in $files) {
            if (-not (Test-InternalPath -Session $session -Path $file) -and -not $approved) {
                Append-LogRecord -Session $session -Record ([ordered]@{
                    type = "approval_required"
                    op_id = $opId
                    operation = "delete"
                    path = $file
                    reason = "directory_child_external"
                }) | Out-Null
                [ordered]@{
                    status = "APPROVAL_REQUIRED"
                    op_id = $opId
                    operation = "delete"
                    path = $file
                    reason = "directory_child_external"
                    message = "Directory deletion includes an external target. Ask the user, then rerun with --approved."
                } | ConvertTo-Json -Depth 8
                exit $ExitApprovalRequired
            }
        }
        $threshold = Get-EnvInt -Name "GUARD_LARGE_DELETE_THRESHOLD" -Default 20
        if ($files.Count -gt $threshold -and -not $confirmed) {
            Append-LogRecord -Session $session -Record ([ordered]@{
                type = "delete_preview_required"
                op_id = $opId
                path = $resolved
                file_count = $files.Count
                preview = @($files)
            }) | Out-Null
            [ordered]@{
                status = "CONFIRMATION_REQUIRED"
                op_id = $opId
                file_count = $files.Count
                preview = @($files)
                message = "Rerun predelete with --confirmed after reviewing the preview."
            } | ConvertTo-Json -Depth 10
            exit $ExitConfirmationRequired
        }
    }
    else {
        [void]$files.Add($resolved)
    }

    foreach ($file in $files) {
        if ([System.IO.File]::Exists($file)) {
            [void](New-Snapshot -Session $session -Path $file -OperationType "snapshot" -OpId $opId)
        }
    }
    Append-LogRecord -Session $session -Record ([ordered]@{
        type = "predelete"
        op_id = $opId
        path = $resolved
        internal = $isInternal
        strict_agents_rule = $strict
        is_dir = $isDir
        file_count = $files.Count
        dir_manifest_ref = $manifestRef
    }) | Out-Null
    $out = [ordered]@{
        status = "OK"
        op_id = $opId
        path = $resolved
        internal = $isInternal
        file_count = $files.Count
        content_snapshotted = $true
    }
    if (-not $ReturnOnly) {
        $out | ConvertTo-Json -Depth 10
        return
    }
    return $out
}

function Invoke-PreMove {
    param([switch]$ReturnOnly)
    $session = Ensure-Session
    $nonFlags = @($Rest | Where-Object { -not $_.StartsWith("--") })
    if ($nonFlags.Count -lt 2) { throw "Usage: premove <source> <dest> [--approved]" }
    $source = Resolve-PathForGuard -Path $nonFlags[0]
    $dest = Resolve-PathForGuard -Path $nonFlags[1]
    $approved = Test-Flag -Args $Rest -Name "--approved"
    $sourceInternal = Test-InternalPath -Session $session -Path $source
    $destInternal = Test-InternalPath -Session $session -Path $dest
    $strict = (Test-StrictDeleteRule -Session $session -TargetPath $source)
    $opId = [guid]::NewGuid().ToString()
    if ((-not $sourceInternal -or -not $destInternal -or $strict) -and -not $approved) {
        Append-LogRecord -Session $session -Record ([ordered]@{
            type = "approval_required"
            op_id = $opId
            operation = "move"
            source = $source
            dest = $dest
            source_internal = $sourceInternal
            dest_internal = $destInternal
            strict_agents_rule = $strict
        }) | Out-Null
        $message = "Move approval required for $source -> $dest. Ask the user, then rerun with --approved."
        if ($ReturnOnly) { throw $message }
        [ordered]@{
            status = "APPROVAL_REQUIRED"
            op_id = $opId
            operation = "move"
            source = $source
            dest = $dest
            source_internal = $sourceInternal
            dest_internal = $destInternal
            strict_agents_rule = $strict
            message = $message
        } | ConvertTo-Json -Depth 8
        exit $ExitApprovalRequired
    }
    if ([System.IO.File]::Exists($source)) {
        [void](New-Snapshot -Session $session -Path $source -OperationType "snapshot" -OpId $opId)
    }
    Append-LogRecord -Session $session -Record ([ordered]@{
        type = "premove"
        op_id = $opId
        source = $source
        dest = $dest
        source_internal = $sourceInternal
        dest_internal = $destInternal
        strict_agents_rule = $strict
    }) | Out-Null
    $out = [ordered]@{ status = "OK"; op_id = $opId; source = $source; dest = $dest }
    if (-not $ReturnOnly) {
        $out | ConvertTo-Json -Depth 8
        return
    }
    return $out
}

function Invoke-Complete {
    $session = Ensure-Session
    $nonFlags = @($Rest | Where-Object { -not $_.StartsWith("--") })
    if ($nonFlags.Count -lt 2) { throw "Usage: complete <op_id> <ok|failed>" }
    $opId = $nonFlags[0]
    $status = $nonFlags[1]
    $parsed = Read-SessionRecords -Session $session
    $paths = New-Object System.Collections.ArrayList
    foreach ($r in $parsed.records) {
        if ($r.op_id -and [string]$r.op_id -eq $opId) {
            if ($r.path) { [void]$paths.Add([string]$r.path) }
            if ($r.source) { [void]$paths.Add([string]$r.source) }
            if ($r.dest) { [void]$paths.Add([string]$r.dest) }
        }
    }
    $states = New-Object System.Collections.ArrayList
    foreach ($p in @($paths | Select-Object -Unique)) {
        [void]$states.Add((Get-FileState -Path $p))
    }
    $record = [ordered]@{
        type = "complete"
        op_id = $opId
        status = $status
        after_states = @($states)
    }
    if ($states.Count -eq 1) {
        $record["after_exists"] = $states[0].exists
        $record["after_hash"] = $states[0].hash
        $record["after_size"] = $states[0].size
        $record["after_mtime"] = $states[0].mtime
    }
    Append-LogRecord -Session $session -Record $record | Out-Null
    [ordered]@{ status = "OK"; op_id = $opId; completed_status = $status; after_states = @($states) } | ConvertTo-Json -Depth 12
}

function Find-RestorableSnapshot {
    param([object]$Session, [string]$PathOrOpId)
    $parsed = Read-SessionRecords -Session $Session -VerifyChain
    $snapshots = @($parsed.records | Where-Object { $_.type -eq "snapshot" -and $_.content_snapshotted -eq $true })
    $byOp = @($snapshots | Where-Object { [string]$_.op_id -eq $PathOrOpId })
    if ($byOp.Count -gt 0) {
        return $byOp[$byOp.Count - 1]
    }
    $resolved = Resolve-PathForGuard -Path $PathOrOpId
    $byPath = @($snapshots | Where-Object { [string]$_.path -eq $resolved })
    if ($byPath.Count -gt 0) {
        return $byPath[$byPath.Count - 1]
    }
    return $null
}

function Find-CompleteRecord {
    param([object]$Session, [string]$OpId)
    $parsed = Read-SessionRecords -Session $Session
    $complete = @($parsed.records | Where-Object { $_.type -eq "complete" -and [string]$_.op_id -eq $OpId })
    if ($complete.Count -eq 0) { return $null }
    return $complete[$complete.Count - 1]
}

function Invoke-InspectRollback {
    $session = Ensure-Session
    $target = $null
    if ($Rest.Count -gt 0) { $target = ($Rest | Where-Object { -not $_.StartsWith("--") } | Select-Object -First 1) }
    $parsed = Read-SessionRecords -Session $session -VerifyChain -LogErrors
    $items = New-Object System.Collections.ArrayList
    foreach ($r in $parsed.records) {
        if ($r.type -ne "snapshot" -or $r.content_snapshotted -ne $true) { continue }
        if ($target) {
            $resolvedTarget = Resolve-PathForGuard -Path $target
            if ([string]$r.path -ne $resolvedTarget -and [string]$r.op_id -ne $target) { continue }
        }
        $complete = Find-CompleteRecord -Session $session -OpId ([string]$r.op_id)
        $current = Get-FileState -Path ([string]$r.path)
        $changed = $false
        if ($complete -and $complete.after_hash -and $current.hash -ne $complete.after_hash) {
            $changed = $true
        }
        [void]$items.Add([ordered]@{
            op_id = $r.op_id
            path = $r.path
            timestamp = $r.timestamp
            content_snapshotted = $r.content_snapshotted
            snapshot_ref = $r.snapshot_ref
            current_hash = $current.hash
            recorded_post_hash = $(if ($complete) { $complete.after_hash } else { $null })
            changed_since_op = $changed
        })
    }
    [ordered]@{
        status = $(if ($parsed.chain_ok) { "OK" } else { "LOG_CHAIN_BROKEN" })
        errors = @($parsed.errors)
        restorable = @($items)
    } | ConvertTo-Json -Depth 14
}

function Invoke-RestorePrevious {
    $session = Ensure-Session
    $target = Require-PathArg -Args $Rest -Usage "Usage: restore-previous <path|op_id> [--force]"
    $force = Test-Flag -Args $Rest -Name "--force"
    $snapshot = Find-RestorableSnapshot -Session $session -PathOrOpId $target
    if (-not $snapshot) {
        Write-Error "No content snapshot is available for $target."
        exit $ExitNotRestorable
    }
    $complete = Find-CompleteRecord -Session $session -OpId ([string]$snapshot.op_id)
    $current = Get-FileState -Path ([string]$snapshot.path)
    if ($complete -and $complete.after_hash -and $current.hash -ne $complete.after_hash -and -not $force) {
        [ordered]@{
            status = "CONFLICT"
            op_id = $snapshot.op_id
            path = $snapshot.path
            current_hash = $current.hash
            recorded_post_hash = $complete.after_hash
            message = "Current file differs from the recorded post-operation state. Use --force only after explicit confirmation, or create a conflict copy manually."
        } | ConvertTo-Json -Depth 8
        exit $ExitConflict
    }
    if ($force) {
        Append-LogRecord -Session $session -Record ([ordered]@{
            type = "forced_restore"
            op_id = $snapshot.op_id
            path = $snapshot.path
        }) | Out-Null
    }
    $contentPath = [System.IO.Path]::Combine((Get-GuardRoot), "snapshots", [string]$snapshot.snapshot_ref)
    if (-not [System.IO.File]::Exists($contentPath)) {
        Write-Error "Snapshot content is missing: $contentPath"
        exit $ExitNotRestorable
    }
    Copy-WithRetry -Source $contentPath -Destination ([string]$snapshot.path)
    $item = Get-Item -LiteralPath ([string]$snapshot.path) -Force
    if ($snapshot.mtime) { $item.LastWriteTimeUtc = [DateTime]::Parse([string]$snapshot.mtime).ToUniversalTime() }
    if ($snapshot.ctime) { $item.CreationTimeUtc = [DateTime]::Parse([string]$snapshot.ctime).ToUniversalTime() }
    if ($snapshot.attrs -ne $null) { $item.Attributes = [System.IO.FileAttributes]([int]$snapshot.attrs) }
    Append-LogRecord -Session $session -Record ([ordered]@{
        type = "restore"
        op_id = $snapshot.op_id
        path = $snapshot.path
        restored_hash = (Get-Sha256File -Path ([string]$snapshot.path))
    }) | Out-Null
    [ordered]@{ status = "OK"; op_id = $snapshot.op_id; path = $snapshot.path } | ConvertTo-Json -Depth 8
}

function Invoke-GuardedWrite {
    $session = Ensure-Session
    $path = Require-PathArg -Args $Rest -Usage "Usage: guarded-write <path> --content <text> [--append]"
    $content = Get-ArgValue -Args $Rest -Name "--content"
    $fromFile = Get-ArgValue -Args $Rest -Name "--from-file"
    $append = Test-Flag -Args $Rest -Name "--append"
    if ($null -eq $content -and $null -eq $fromFile) {
        throw "guarded-write requires --content or --from-file."
    }
    $record = New-Snapshot -Session $session -Path $path -OperationType "snapshot"
    try {
        $resolved = Resolve-PathForGuard -Path $path
        if ($fromFile) {
            if ($append) {
                $bytes = [System.IO.File]::ReadAllBytes((Resolve-PathForGuard -Path $fromFile))
                $stream = [System.IO.File]::Open($resolved, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
            }
            else {
                Copy-WithRetry -Source (Resolve-PathForGuard -Path $fromFile) -Destination $resolved
            }
        }
        elseif ($append) {
            Append-TextNoBom -Path $resolved -Text $content
        }
        else {
            Write-TextNoBom -Path $resolved -Text $content
        }
        $script:Rest = @([string]$record.op_id, "ok")
        Invoke-Complete | Out-Null
        [ordered]@{ status = "OK"; op_id = $record.op_id; path = $resolved } | ConvertTo-Json -Depth 8
    }
    catch {
        $script:Rest = @([string]$record.op_id, "failed")
        Invoke-Complete | Out-Null
        throw
    }
}

function Invoke-GuardedDelete {
    $session = Ensure-Session | Out-Null
    $pre = Invoke-PreDelete -ReturnOnly
    try {
        Remove-Item -LiteralPath $pre.path -Recurse -Force
        $script:Rest = @([string]$pre.op_id, "ok")
        Invoke-Complete | Out-Null
        [ordered]@{ status = "OK"; op_id = $pre.op_id; path = $pre.path } | ConvertTo-Json -Depth 8
    }
    catch {
        $script:Rest = @([string]$pre.op_id, "failed")
        Invoke-Complete | Out-Null
        throw
    }
}

function Invoke-GuardedMove {
    $session = Ensure-Session | Out-Null
    $pre = Invoke-PreMove -ReturnOnly
    try {
        Move-Item -LiteralPath $pre.source -Destination $pre.dest -Force
        $script:Rest = @([string]$pre.op_id, "ok")
        Invoke-Complete | Out-Null
        [ordered]@{ status = "OK"; op_id = $pre.op_id; source = $pre.source; dest = $pre.dest } | ConvertTo-Json -Depth 8
    }
    catch {
        $script:Rest = @([string]$pre.op_id, "failed")
        Invoke-Complete | Out-Null
        throw
    }
}

function Invoke-PurgeSnapshot {
    $session = Ensure-Session
    $opId = Require-PathArg -Args $Rest -Usage "Usage: purge-snapshot <op_id>"
    $parsed = Read-SessionRecords -Session $session
    $snapshots = @($parsed.records | Where-Object { $_.type -eq "snapshot" -and [string]$_.op_id -eq $opId -and $_.snapshot_ref })
    if ($snapshots.Count -eq 0) {
        Write-Error "No snapshot content found for $opId."
        exit $ExitNotRestorable
    }
    foreach ($snap in $snapshots) {
        $contentPath = [System.IO.Path]::Combine((Get-GuardRoot), "snapshots", [string]$snap.snapshot_ref)
        if ([System.IO.File]::Exists($contentPath)) {
            Remove-Item -LiteralPath $contentPath -Force
        }
    }
    Append-LogRecord -Session $session -Record ([ordered]@{
        type = "purge_snapshot"
        op_id = $opId
        content_snapshotted = $false
    }) | Out-Null
    [ordered]@{ status = "OK"; op_id = $opId; purged = $true } | ConvertTo-Json -Depth 6
}

if (-not $Command) {
    Write-Error "Usage: guard-file-change.ps1 <workspace-init|snapshot-modify|log-add|predelete|premove|complete|inspect-rollback|restore-previous|guarded-write|guarded-delete|guarded-move|purge-snapshot> ..."
    exit $ExitUsage
}

try {
    switch ($Command) {
        "workspace-init" { Invoke-WorkspaceInit }
        "snapshot-modify" { Invoke-SnapshotModify }
        "log-add" { Invoke-LogAdd }
        "predelete" { Invoke-PreDelete }
        "premove" { Invoke-PreMove }
        "complete" { Invoke-Complete }
        "inspect-rollback" { Invoke-InspectRollback }
        "restore-previous" { Invoke-RestorePrevious }
        "guarded-write" { Invoke-GuardedWrite }
        "guarded-delete" { Invoke-GuardedDelete }
        "guarded-move" { Invoke-GuardedMove }
        "purge-snapshot" { Invoke-PurgeSnapshot }
        default {
            Write-Error "Unknown command: $Command"
            exit $ExitUsage
        }
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
