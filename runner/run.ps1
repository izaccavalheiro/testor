# Runs one task's command and records it for testor (the orchestrator reads these files).
# Needs PowerShell 7 (Windows, Linux or macOS). Next to it:
#   runs\<id>.json        project, kind, command, pid, start, end, status, exit code
#   logs\<id>.log         everything the command printed (it is still printed, unchanged)
#   screenshots\<id>\     images the run wrote under test-results, __screenshots__, screenshots
#                         or .vitest-attachments, plus anything saved to $env:SCREENSHOT_DIR
#   artifacts\<id>\       what -Artifacts names (reports, coverage, ...), videos from the same
#                         folders as screenshots, plus anything saved to $env:TESTOR_ARTIFACT_DIR
#   reports\<id>\         what -Reports names: result files testor reads (a mutation report)
# The folders are next to this script (the testor home). Recording never fails a run: only
# the command's own error is rethrown, so output, stderr and the exit code are unchanged.
#
#   & "$HOME/test-run/.testor/run.ps1" -Project my-app -Kind test -Body { npm test }
#   & ... -Artifacts coverage, playwright-report, "reports/*.md" -Body { npm run test:coverage }
#
# -Artifacts: files and folders, relative to the working folder (wildcards allowed), kept with
# the run when the run wrote them (a folder counts when any file in it is new). They are copied
# in order until artifacts.maxRunMB (config.json, default 256) is reached; the rest is skipped
# with a warning. The command sees $env:TESTOR_RUN_ID, $env:SCREENSHOT_DIR and
# $env:TESTOR_ARTIFACT_DIR (folders kept with the run).
#
# -TimeoutSeconds and -MemoryGuard (or $env:TESTOR_TIMEOUT_SECONDS, $env:TESTOR_MEMORY_GUARD):
# past the time, or past the guard's "stop" share of memory, the command's process tree is
# ended as a cancel ends it, and the run is recorded failed with reason "timeout" or "memory"
# (exit code 124 or 137 when the command's own was 0). At "warn" a line goes to the log.
#
# $env:TESTOR_LOCK=1 (remote.yml's SSH runs): one run of the project at a time on this machine.
# A second one is recorded "waiting" until the first ends; the lock is a file held open in
# locks\, which the system releases however the holder ends.
#
# -Reports (and $env:TESTOR_REPORTS, ";"-separated): files relative to the working folder
# (wildcards allowed) that testor reads when the run ends, such as Stryker's
# reports/mutation/mutation.json. Only files the run wrote are kept, 20 at most, 50 MB each.
param(
  [Parameter(Mandatory)][string]$Project,
  [Parameter(Mandatory)][string]$Kind,
  [Parameter(Mandatory)][scriptblock]$Body,
  [string[]]$Artifacts = @(),
  [string[]]$Reports = @(),
  # Ends the command's process tree after this many seconds (0: never); TESTOR_TIMEOUT_SECONDS.
  [int]$TimeoutSeconds = 0,
  # "warn,stop": percentages of the memory the run may use (its cgroup's limit on Linux, else
  # the machine's) at which it warns in the log and ends the tree; TESTOR_MEMORY_GUARD.
  [string]$MemoryGuard = ""
)

$root = $PSScriptRoot
$started = Get-Date
$workdir = (Get-Location).Path
$id = $started.ToUniversalTime().ToString("yyyyMMdd-HHmmss") + "-" + [guid]::NewGuid().ToString("N").Substring(0, 6)
$runFile = Join-Path (Join-Path $root "runs") "$id.json"
$logFile = Join-Path (Join-Path $root "logs") "$id.log"
$shotDir = Join-Path (Join-Path $root "screenshots") $id
$artDir = Join-Path (Join-Path $root "artifacts") $id
# Files this run wrote are the ones changed since it started; the margin covers file systems
# that keep modification times to the second (or two, on FAT).
$since = $started.AddSeconds(-2)
$imageExt = ".png", ".jpg", ".jpeg", ".webp", ".gif"
$videoExt = ".webm", ".mp4"
$maxRunBytes = 256MB
try {
  $configFile = Join-Path $root "config.json"
  if (Test-Path -LiteralPath $configFile) {
    $mb = (Get-Content -Raw -LiteralPath $configFile | ConvertFrom-Json).artifacts.maxRunMB
    if ($mb -gt 0) { $maxRunBytes = [long]$mb * 1MB }
  }
} catch { Write-Warning "testor: config.json: $_" }

# The files this change touches, for impact analysis: the agent's list (a snapshot job's,
# TESTOR_CHANGED_FILES), else git's (the branch's commits since it left its upstream's main, and
# what is not committed). Relative paths, 1,000 at most.
function Get-ChangedFiles {
  try {
    if ($env:TESTOR_CHANGED_FILES -and (Test-Path -LiteralPath $env:TESTOR_CHANGED_FILES)) { $paths = @(Get-Content -LiteralPath $env:TESTOR_CHANGED_FILES) }
    else {
      $inside = git rev-parse --is-inside-work-tree 2>$null
      if ($LASTEXITCODE -or "$inside".Trim() -ne "true") { $global:LASTEXITCODE = 0; return $null }
      $base = git merge-base HEAD "$(git rev-parse --abbrev-ref origin/HEAD 2>$null)".Trim() 2>$null
      $paths = @(if ($base -and -not $LASTEXITCODE) { git diff --name-only "$("$base".Trim())...HEAD" 2>$null }) +
        @(git status --porcelain 2>$null | ForEach-Object { ($_.Substring([math]::Min(3, $_.Length)) -split " -> ")[-1].Trim('"') })
    }
    $global:LASTEXITCODE = 0
    $paths = @($paths | Where-Object { $_ -and -not [IO.Path]::IsPathRooted($_) -and ($_ -split "[\\/]") -notcontains ".." } | ForEach-Object { $_ -replace "\\", "/" } | Select-Object -Unique -First 1000)
    if ($paths.Count) { , $paths } else { $null }
  } catch { $global:LASTEXITCODE = 0; $null }
}

$record = [ordered]@{
  id         = $id
  project    = $Project
  kind       = $Kind
  command    = ($Body.ToString().Trim() -replace "\s+", " ")
  pid        = $PID
  workdir    = $workdir
  startedAt  = $started.ToUniversalTime().ToString("o")
  status     = "running"
  # Who started it: the account and SSH client the runner sees, and who the workstation says
  # it is (TESTOR_ACTOR, from remote.yml: informative, not proof).
  actor      = [ordered]@{
    user     = [Environment]::UserName
    client   = if ($env:SSH_CLIENT) { ($env:SSH_CLIENT -split " ")[0] } else { $null }
    declared = if ($env:TESTOR_ACTOR) { $env:TESTOR_ACTOR } else { $null }
  }
  # What was tested, from the workstation (remote.yml): flaky specs are found per commit.
  source     = if ($env:TESTOR_COMMIT) {
    [ordered]@{
      commit      = $env:TESTOR_COMMIT
      branch      = $env:TESTOR_BRANCH
      dirty       = $env:TESTOR_DIRTY -eq "true"
      # When the commit was made: DORA's lead time for changes.
      committedAt = if ("$env:TESTOR_COMMITTED_AT" -match "^\d{4}-\d\d-\d\dT") { $env:TESTOR_COMMITTED_AT } else { $null }
    }
  } else { $null }
  # The job this run is for, when an agent started it (runner/agent.ps1).
  job        = if ($env:TESTOR_JOB_ID) { $env:TESTOR_JOB_ID } else { $null }
  # A scoped run's selection (files, names, affected), and the watch session it reruns for:
  # gates and commit statuses leave such runs out.
  select     = if ($env:TESTOR_SELECT) { try { $env:TESTOR_SELECT | ConvertFrom-Json -AsHashtable } catch { $null } } else { $null }
  session    = if ($env:TESTOR_SESSION) { $env:TESTOR_SESSION } else { $null }
  # A batch's shard (Testor.Shards): left out of gates, merged into the batch's run.
  shard      = if ("$env:TESTOR_SHARD_INDEX" -match "^\d+$" -and "$env:TESTOR_SHARD_TOTAL" -match "^\d+$") { [ordered]@{ index = [int]$env:TESTOR_SHARD_INDEX; total = [int]$env:TESTOR_SHARD_TOTAL } } else { $null }
  changedFiles = Get-ChangedFiles
  # The W3C trace this run belongs to (the agent gives a job's), for testor's spans.
  traceparent = if ("$env:TRACEPARENT" -match "^00-[0-9a-f]{32}-[0-9a-f]{16}-[0-9a-f]{2}$") { $env:TRACEPARENT } else { $null }
}

function Save-Record {
  try {
    $tmp = "$runFile.tmp"
    $record | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    Move-Item -LiteralPath $tmp -Destination $runFile -Force
  } catch { Write-Warning "testor: could not save the run record: $_" }
}

# Images and videos under the folders test runners write screenshots to.
# Whether a file starts as an image or a video does (PNG, JPEG, GIF, WebP, WebM, MP4): a file
# named .png that is not one (a test suite's fixture: "png" in a.png) is no screenshot, and
# would show as a broken image.
function Test-Media([IO.FileInfo]$file) {
  try {
    $stream = [IO.File]::OpenRead($file.FullName)
    try { $head = [byte[]]::new(12); $n = $stream.Read($head, 0, 12) } finally { $stream.Dispose() }
  } catch { return $false }
  if ($n -lt 4) { return $false }
  $text = [Text.Encoding]::ASCII.GetString($head, 0, $n)
  ($head[0] -eq 0x89 -and $text.Substring(1, 3) -eq "PNG") -or
    ($head[0] -eq 0xFF -and $head[1] -eq 0xD8 -and $head[2] -eq 0xFF) -or
    $text.StartsWith("GIF8") -or
    ($n -ge 12 -and $text.StartsWith("RIFF") -and $text.Substring(8, 4) -eq "WEBP") -or
    ($head[0] -eq 0x1A -and $head[1] -eq 0x45 -and $head[2] -eq 0xDF -and $head[3] -eq 0xA3) -or
    ($n -ge 8 -and $text.Substring(4, 4) -eq "ftyp")
}

function Find-Media([string]$dir, [bool]$inShotFolder) {
  foreach ($item in Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue) {
    # Links are never followed nor copied: one could point at files outside the project.
    if ($item.LinkType) { continue }
    if ($item.PSIsContainer) {
      if ($item.Name -in "node_modules", "target", ".git", ".venv", "playwright-report") { continue }
      $shots = $inShotFolder -or ($item.Name -in "test-results", "__screenshots__", "screenshots", ".vitest-attachments")
      Find-Media $item.FullName $shots
    } elseif ($inShotFolder -and ($item.Extension -in $imageExt -or $item.Extension -in $videoExt) -and $item.LastWriteTime -ge $since -and (Test-Media $item)) {
      $item
    }
  }
}

$copied = [Collections.Generic.HashSet[string]]::new()
$artBytes = [long]0
$skipped = [Collections.Generic.List[string]]::new()
# Copies files into the artifacts folder at their path relative to the working folder, all of
# them or none: a report missing half its files is worse than none.
function Copy-Artifact([object[]]$files, [string]$label) {
  $files = @($files | Where-Object { -not $script:copied.Contains($_.FullName) })
  if (-not $files.Count) { return }
  $size = [long]($files | Measure-Object -Property Length -Sum).Sum
  if ($script:artBytes + $size -gt $maxRunBytes) {
    $script:skipped.Add("$label ($([math]::Round($size / 1MB, 1)) MB)")
    return
  }
  foreach ($file in $files) {
    $target = Join-Path $artDir ([IO.Path]::GetRelativePath($workdir, $file.FullName))
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
    [IO.File]::Copy($file.FullName, $target, $true)
    $null = $script:copied.Add($file.FullName)
  }
  $script:artBytes += $size
}

function Save-Reports {
  $wanted = @($Reports) + @("$env:TESTOR_REPORTS" -split ";") | ForEach-Object { "$_".Trim() } | Where-Object { $_ }
  $dir = Join-Path (Join-Path $root "reports") $id
  $kept = @()
  foreach ($pattern in $wanted) {
    if ([IO.Path]::IsPathRooted($pattern)) { Write-Warning "testor: report '$pattern' is not relative to the working folder; skipped"; continue }
    foreach ($file in @(Get-ChildItem -Path (Join-Path $workdir $pattern) -File -Force -ErrorAction SilentlyContinue | Where-Object { -not $_.LinkType })) {
      if ($file.LastWriteTime -lt $since) { Write-Warning "testor: report $($file.Name) was not written by this run; not kept"; continue }
      if ($file.Length -gt 50MB) { Write-Warning "testor: report $($file.Name) is over 50 MB; not kept"; continue }
      if ($kept.Count -ge 20) { Write-Warning "testor: 20 reports at most; $($file.Name) not kept"; continue }
      $name = $file.Name
      for ($n = 2; $name -in $kept; $n++) { $name = "$n-$($file.Name)" }
      $null = New-Item -ItemType Directory -Force -Path $dir
      Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $dir $name)
      $kept += $name
    }
  }
}

function Save-Artifacts {
  foreach ($pattern in $Artifacts) {
    if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
    $pattern = $pattern.Trim()
    if ([IO.Path]::IsPathRooted($pattern)) { Write-Warning "testor: artifact '$pattern' is not relative to the working folder; skipped"; continue }
    foreach ($item in @(Get-Item -Path (Join-Path $workdir $pattern) -Force -ErrorAction SilentlyContinue)) {
      if ($item.LinkType) { Write-Warning "testor: artifact '$pattern' is a link; skipped"; continue }
      $rel = [IO.Path]::GetRelativePath($workdir, $item.FullName)
      if ($rel -eq "." -or $rel -eq ".." -or $rel.StartsWith("..$([IO.Path]::DirectorySeparatorChar)") -or [IO.Path]::IsPathRooted($rel)) {
        Write-Warning "testor: artifact '$pattern' is outside the working folder; skipped"; continue
      }
      $files = if ($item.PSIsContainer) { @(Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { -not $_.LinkType }) } else { @($item) }
      # Reports copy their assets with the original dates, so one new file is enough.
      if (-not ($files | Where-Object { $_.LastWriteTime -ge $since } | Select-Object -First 1)) { continue }
      Copy-Artifact $files $rel
    }
  }
}

try {
  $null = New-Item -ItemType Directory -Force -Path (Join-Path $root "runs"), (Join-Path $root "logs"), $shotDir, $artDir
} catch { Write-Warning "testor: $_" }
Save-Record
# The project's lock: a run already holding it makes this one wait, shown as waiting.
$lock = $null
if ($env:TESTOR_LOCK -eq "1") {
  $lockDir = Join-Path $root "locks"
  $null = New-Item -ItemType Directory -Force -Path $lockDir
  $lockFile = Join-Path $lockDir (($Project -replace "[^\w.-]", "_") + ".lock")
  while (-not $lock) {
    try {
      $lock = [IO.File]::Open($lockFile, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch [IO.IOException] {
      if (-not $record.waiting) { $record.waiting = "another run of $Project holds its lock"; Save-Record; [Console]::Error.WriteLine("testor: waiting for the run of $Project in progress") }
      Start-Sleep -Milliseconds 500
    }
  }
  if ($record.waiting) { $record.Remove("waiting"); Save-Record }
}
$env:TESTOR_RUN_ID = $id
$env:SCREENSHOT_DIR = $shotDir
$env:TESTOR_ARTIFACT_DIR = $artDir

# A deadline and a memory guard, given to the watcher below; what it saw, shared with it.
if (-not $TimeoutSeconds -and "$env:TESTOR_TIMEOUT_SECONDS" -match "^\d+$") { $TimeoutSeconds = [int]$env:TESTOR_TIMEOUT_SECONDS }
if (-not $MemoryGuard) { $MemoryGuard = "$env:TESTOR_MEMORY_GUARD" }
$deadline = if ($TimeoutSeconds -gt 0) { [DateTime]::UtcNow.AddSeconds($TimeoutSeconds).Ticks } else { [long]0 }
$guard = $null
if ($MemoryGuard -match "^\s*(\d{1,3})\s*,\s*(\d{1,3})\s*$" -and [int]$Matches[1] -le [int]$Matches[2] -and [int]$Matches[2] -le 100) {
  $guard = @([int]$Matches[1], [int]$Matches[2])
} elseif ($MemoryGuard) { Write-Warning "testor: memory guard '$MemoryGuard' is not 'warn,stop' (percentages); off" }
# What this session had started before the run (run.ps1 called in a session that runs other
# things: a test of testor itself) is not the run's: never ended, never counted. Taken now,
# before the command starts.
$before = [Collections.Generic.HashSet[int]]::new()
if ($deadline -gt 0 -or $guard) {
  try {
    $parentOf = @{}
    if ($IsWindows) { foreach ($p in Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId) { $parentOf[[int]$p.ProcessId] = [int]$p.ParentProcessId } }
    else { foreach ($line in (ps -A -o pid=,ppid=)) { $f = -split $line; if ($f.Count -eq 2) { $parentOf[[int]$f[0]] = [int]$f[1] } } }
    $queue = [Collections.Generic.Queue[int]]::new(); $queue.Enqueue($PID)
    while ($queue.Count) {
      $p = $queue.Dequeue()
      foreach ($k in @($parentOf.Keys | Where-Object { $parentOf[$_] -eq $p -and $_ -ne $p })) { if ($before.Add($k)) { $queue.Enqueue($k) } }
    }
  } catch { Write-Warning "testor: the processes before the run: $_" }
}
$shared = [hashtable]::Synchronized(@{ reason = $null; done = $false; record = $record; runFile = $runFile; peak = [long]0; notes = [Collections.Concurrent.ConcurrentQueue[string]]::new() })

# Cancelling: the orchestrator writes cancel\<id>, and this session ends its own process tree
# (this PowerShell included), so the orchestrator never kills processes of another account.
# The record stays "running"; the orchestrator sees the process gone and settles it.
$watcher = $null
try {
  # A runspace of its own on a thread of this process: no module to load (Start-ThreadJob's
  # ThreadJob module took seconds to load in a fresh PowerShell on macOS).
  $watcher = [powershell]::Create()
  $null = $watcher.AddScript({
    param($file, $owner, $deadline, $guard, $shared, $before)
    # Ending the watcher when the run ends stops this pipeline: that is not an error to report.
    trap {
      if ($_.Exception -isnot [Management.Automation.PipelineStoppedException]) { [Console]::Error.WriteLine("testor: cancel watcher: $_") }
      break
    }
    # The process tree under $root (this PowerShell's pid): pid -> parent, and memory.
    function Get-Tree([int]$root) {
      $parents = @{}; $memory = @{}
      if ($IsWindows) {
        foreach ($p in Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, WorkingSetSize) {
          $parents[[int]$p.ProcessId] = [int]$p.ParentProcessId; $memory[[int]$p.ProcessId] = [long]$p.WorkingSetSize
        }
      } else {
        foreach ($line in (ps -A -o pid=,ppid=,rss=)) {
          $f = -split $line
          if ($f.Count -eq 3) { $parents[[int]$f[0]] = [int]$f[1]; $memory[[int]$f[0]] = [long]$f[2] * 1024 }
        }
      }
      $children = @{}
      foreach ($k in $parents.Keys) { if ($k -ne $parents[$k] -and -not $before.Contains($k)) { $children[$parents[$k]] += @($k) } }
      $tree = [Collections.Generic.List[int]]::new()
      $queue = [Collections.Generic.Queue[int]]::new()
      $queue.Enqueue($root)
      while ($queue.Count) {
        $p = $queue.Dequeue()
        if ($tree.Contains($p)) { continue }
        $tree.Add($p)
        foreach ($child in @($children[$p])) { if ($child) { $queue.Enqueue($child) } }
      }
      @{ pids = $tree; bytes = [long]($tree | ForEach-Object { $memory[$_] } | Measure-Object -Sum).Sum }
    }
    # The share of memory in use, in %: the cgroup's (Linux, with a limit), else the tree's.
    function Get-MemoryShare {
      if ($IsLinux) {
        $limit = $null; $used = $null
        if (Test-Path /sys/fs/cgroup/memory.max) {
          $raw = (Get-Content -Raw /sys/fs/cgroup/memory.max).Trim()
          if ($raw -ne "max") { $limit = [double]$raw; $used = [double](Get-Content -Raw /sys/fs/cgroup/memory.current).Trim() }
        } elseif (Test-Path /sys/fs/cgroup/memory/memory.limit_in_bytes) {
          $raw = [double](Get-Content -Raw /sys/fs/cgroup/memory/memory.limit_in_bytes).Trim()
          if ($raw -lt 1PB) { $limit = $raw; $used = [double](Get-Content -Raw /sys/fs/cgroup/memory/memory.usage_in_bytes).Trim() }
        }
        if ($limit) { return 100 * $used / $limit }
      }
      $total = [GC]::GetGCMemoryInfo().TotalAvailableMemoryBytes
      100 * (Get-Tree $owner).bytes / $total
    }
    # Every process of the tree but this PowerShell; then, if it is still not done, this one too
    # (its record written first, as the run's end would write it).
    function Stop-Run([string]$reason) {
      $shared.reason = $reason
      foreach ($p in @((Get-Tree $owner).pids | Where-Object { $_ -ne $owner })) {
        try { [Diagnostics.Process]::GetProcessById($p).Kill() } catch { }
      }
      $until = (Get-Date).AddSeconds(5)
      while ((Get-Date) -lt $until) { if ($shared.done) { return }; Start-Sleep -Milliseconds 200 }
      $r = $shared.record
      $r.status = "failed"; $r.reason = $reason; $r.exitCode = $(if ($reason -eq "timeout") { 124 } else { 137 })
      $r.endedAt = (Get-Date).ToUniversalTime().ToString("o")
      $r | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $shared.runFile -Encoding utf8NoBOM
      [Diagnostics.Process]::GetCurrentProcess().Kill()
    }
    $warned = $false; $sampled = [DateTime]::MinValue
    while (-not (Test-Path -LiteralPath $file)) {
      if ($deadline -gt 0 -and [DateTime]::UtcNow.Ticks -ge $deadline) { Stop-Run "timeout"; return }
      if ($guard -and ([DateTime]::UtcNow - $sampled).TotalSeconds -ge 1) {
        $sampled = [DateTime]::UtcNow
        $share = try { Get-MemoryShare } catch { 0 }
        # The tree's peak, for sizing (memory.peakMB) where the cgroup keeps none.
        try { $b = (Get-Tree $owner).bytes; if ($b -gt $shared.peak) { $shared.peak = $b } } catch { }
        if ($share -ge $guard[1]) { $shared.notes.Enqueue("testor: memory at $([math]::Round($share))%, over the guard's $($guard[1])%: ending the run"); Stop-Run "memory"; return }
        if ($share -ge $guard[0] -and -not $warned) { $warned = $true; $shared.notes.Enqueue("testor: memory at $([math]::Round($share))%, over the guard's warning at $($guard[0])%") }
      }
      Start-Sleep -Milliseconds 300
    }
    if ($IsWindows) { taskkill /PID $owner /T /F | Out-Null; return }
    $tree = (Get-Tree $owner).pids
    # Killed with system calls, no program started: on macOS a kill program started after the
    # tree was stopped never ran. Every other process first, this PowerShell last.
    foreach ($p in @($tree | Where-Object { $_ -ne $owner })) {
      try { [Diagnostics.Process]::GetProcessById($p).Kill() } catch { }
    }
    [Diagnostics.Process]::GetCurrentProcess().Kill()
  }.ToString()).AddArgument((Join-Path (Join-Path $root "cancel") $id)).AddArgument($PID).AddArgument($deadline).AddArgument($guard).AddArgument($shared).AddArgument($before)
  $null = $watcher.BeginInvoke()
} catch { Write-Warning "testor: no cancel watcher: $_"; $watcher = $null }

# Secrets stay out of the stored log: the values of environment variables whose names look
# secret (TOKEN, SECRET, PASSWORD, PASSWD, API_KEY, PRIVATE_KEY, CREDENTIAL) or are listed in
# $env:TESTOR_MASK (comma-separated names; the agent lists a job's secrets there), 6 characters
# or longer, are written as ***; so is each line of one that spans lines (a key, a certificate).
# The terminal still gets the output unchanged. Unique by value, then longest first:
# Sort-Object -Unique would compare lengths and leave one of two equally long secrets unmasked.
$maskNames = @("$env:TESTOR_MASK" -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$secrets = @(Get-ChildItem env: | Where-Object {
    ($_.Name -match "TOKEN|SECRET|PASSWORD|PASSWD|API_?KEY|PRIVATE_?KEY|CREDENTIAL" -or $_.Name -in $maskNames) -and
    "$($_.Value)".Length -ge 6 } | ForEach-Object {
    $value = "$($_.Value)"
    $value
    if ($value -match "\n") { $value -split "\r?\n" | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -ge 6 } }
  } | Select-Object -Unique | Sort-Object Length -Descending)
function Hide-Secrets([string]$line) {
  foreach ($secret in $secrets) { $line = $line.Replace($secret, "***") }
  $line
}

$failure = $null
$global:LASTEXITCODE = 0
# Native output is decoded with the console code page (IBM850 here) once it passes through
# PowerShell, which would garble UTF-8 such as Vitest's check marks; UTF-8 both ways keeps it.
$encoding = [Console]::OutputEncoding
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$log = $null
# Beside the log, one character per line of it: o (stdout) or e (stderr), so a client following
# the run (testor run) writes each line back to the stream it came from.
$marks = $null
try {
  $log = [IO.StreamWriter]::new($logFile, $false, [Text.UTF8Encoding]::new($false))
  $log.AutoFlush = $true
  $marks = [IO.StreamWriter]::new([IO.Path]::ChangeExtension($logFile, ".streams"), $false, [Text.UTF8Encoding]::new($false))
  $marks.AutoFlush = $true
} catch { Write-Warning "testor: no log: $_" }
function Write-Log([string]$line, [string]$stream) {
  if (-not $log) { return }
  $log.WriteLine($line)
  if ($marks) { $marks.Write($stream * ([regex]::Matches($line, "`n").Count + 1)) }
}
try {
  # Every line goes to the log; stdout stays stdout and a native program's stderr goes back to
  # stderr as plain text, so callers that separate the two (rust:fmt | sed) are unaffected.
  & $Body 2>&1 | ForEach-Object {
    $note = $null
    while ($shared.notes.TryDequeue([ref]$note)) { [Console]::Error.WriteLine($note); Write-Log $note "e" }
    if ($_ -is [Management.Automation.ErrorRecord] -and $_.Exception -is [Management.Automation.RemoteException]) {
      $line = $_.ToString()
      [Console]::Error.WriteLine($line)
      Write-Log (Hide-Secrets $line) "e"
    } else {
      Write-Log (Hide-Secrets $(if ($_ -is [string]) { $_ } else { ($_ | Out-String).TrimEnd() })) "o"
      $_
    }
  }
} catch {
  $failure = $_
  Write-Log ("`n" + (Hide-Secrets ($_ | Out-String).TrimEnd())) "e"
} finally {
  $shared.done = $true
  if ($lock) { $lock.Dispose() }
  if ($watcher) { try { $watcher.Stop(); $watcher.Dispose() } catch { } }
  $note = $null
  while ($shared.notes.TryDequeue([ref]$note)) { [Console]::Error.WriteLine($note); Write-Log $note "e" }
  [Console]::OutputEncoding = $encoding
  if ($log) { $log.Dispose() }
  if ($marks) { $marks.Dispose() }
  # Runs on success, on failure and on Ctrl+C; a killed session is marked aborted by the server.
  try {
    $ended = Get-Date
    $exit = if ($failure -and $failure.Exception.PSObject.Properties["ExitCode"]) { $failure.Exception.ExitCode }
            elseif ($failure) { if ($LASTEXITCODE) { $LASTEXITCODE } else { 1 } }
            else { $LASTEXITCODE }
    # Ended by its timeout or memory guard: failed, whatever the command's own exit code.
    if ($shared.reason -and -not $exit) { $exit = if ($shared.reason -eq "timeout") { 124 } else { 137 } }
    $record.status = if ($failure -or $exit) { "failed" } else { "passed" }
    $record.exitCode = $exit

    if ($failure) { $record.error = Hide-Secrets ($failure.Exception.Message -split "`n")[0] }
    if ($shared.reason) {
      $record.reason = $shared.reason
      $record.error = if ($shared.reason -eq "timeout") { "timed out after $TimeoutSeconds s" } else { "stopped by the memory guard at $($guard[1])%" }
    }
    $record.endedAt = $ended.ToUniversalTime().ToString("o")
    $record.durationMs = [int]($ended - $started).TotalMilliseconds
    # The peak memory (predictive sizing): the container's, else what the memory guard saw.
    $peak = if ($IsLinux -and (Test-Path /sys/fs/cgroup/memory.peak)) { try { [long](Get-Content -Raw /sys/fs/cgroup/memory.peak).Trim() } catch { 0 } } else { $shared.peak }
    if ($peak -gt 0) { $record.memory = [ordered]@{ peakMB = [math]::Round($peak / 1MB) } }

    $videos = @()
    foreach ($file in @(Find-Media $workdir $false)) {
      if ($file.Extension -in $videoExt) { $videos += $file; continue }
      $rel = [IO.Path]::GetRelativePath($workdir, $file.FullName)
      $target = Join-Path $shotDir $rel
      $null = New-Item -ItemType Directory -Force -Path (Split-Path $target)
      Copy-Item -LiteralPath $file.FullName -Destination $target -Force
    }
    # What the command wrote into SCREENSHOT_DIR itself, kept only if it is an image.
    Get-ChildItem -LiteralPath $shotDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { -not (Test-Media $_) } |
      Remove-Item -Force -ErrorAction SilentlyContinue
    $images = @(Get-ChildItem -LiteralPath $shotDir -Recurse -File -ErrorAction SilentlyContinue)
    $record.screenshots = $images.Count
    if ($images.Count -eq 0) { Remove-Item -LiteralPath $shotDir -Recurse -Force -ErrorAction SilentlyContinue }
  } catch { Write-Warning "testor: $_" }
  try {
    Save-Artifacts
    foreach ($video in $videos) { Copy-Artifact @($video) ([IO.Path]::GetRelativePath($workdir, $video.FullName)) }
    if ($skipped.Count) {
      $record.artifactsSkipped = @($skipped)
      Write-Warning "testor: artifacts over the run's $([math]::Round($maxRunBytes / 1MB)) MB limit (artifacts.maxRunMB) were not kept: $($skipped -join ', ')"
    }
  } catch { Write-Warning "testor: artifacts: $_" }
  try { Save-Reports } catch { Write-Warning "testor: reports: $_" }
  try {
    $kept = @(Get-ChildItem -LiteralPath $artDir -Recurse -File -Force -ErrorAction SilentlyContinue)
    $record.artifacts = $kept.Count
    $record.artifactsBytes = [long]($kept | Measure-Object -Property Length -Sum).Sum
    if ($kept.Count -eq 0) { Remove-Item -LiteralPath $artDir -Recurse -Force -ErrorAction SilentlyContinue }
  } catch { Write-Warning "testor: $_" }
  Save-Record
}
if ($failure) { throw $failure }
# A non-zero exit that did not throw (no $PSNativeCommandUseErrorActionPreference) is handed back.
$global:LASTEXITCODE = $record.exitCode
