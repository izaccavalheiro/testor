# Runs one task's command and records it for testor (the orchestrator reads these files).
# Needs PowerShell 7 (Windows, Linux or macOS). Next to it:
#   runs\<id>.json        project, kind, command, pid, start, end, status, exit code
#   logs\<id>.log         everything the command printed (it is still printed, unchanged)
#   screenshots\<id>\     images the run wrote under test-results, __screenshots__, screenshots
#                         or .vitest-attachments, plus anything saved to $env:SCREENSHOT_DIR
#   artifacts\<id>\       what -Artifacts names (reports, coverage, ...), videos from the same
#                         folders as screenshots, plus anything saved to $env:TESTOR_ARTIFACT_DIR
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
param(
  [Parameter(Mandatory)][string]$Project,
  [Parameter(Mandatory)][string]$Kind,
  [Parameter(Mandatory)][scriptblock]$Body,
  [string[]]$Artifacts = @()
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

$record = [ordered]@{
  id         = $id
  project    = $Project
  kind       = $Kind
  command    = ($Body.ToString().Trim() -replace "\s+", " ")
  pid        = $PID
  workdir    = $workdir
  startedAt  = $started.ToUniversalTime().ToString("o")
  status     = "running"
}

function Save-Record {
  try {
    $tmp = "$runFile.tmp"
    $record | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    Move-Item -LiteralPath $tmp -Destination $runFile -Force
  } catch { Write-Warning "testor: could not save the run record: $_" }
}

# Images and videos under the folders test runners write screenshots to.
function Find-Media([string]$dir, [bool]$inShotFolder) {
  foreach ($item in Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue) {
    # Links are never followed nor copied: one could point at files outside the project.
    if ($item.LinkType) { continue }
    if ($item.PSIsContainer) {
      if ($item.Name -in "node_modules", "target", ".git", ".venv", "playwright-report") { continue }
      $shots = $inShotFolder -or ($item.Name -in "test-results", "__screenshots__", "screenshots", ".vitest-attachments")
      Find-Media $item.FullName $shots
    } elseif ($inShotFolder -and ($item.Extension -in $imageExt -or $item.Extension -in $videoExt) -and $item.LastWriteTime -ge $since) {
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
$env:TESTOR_RUN_ID = $id
$env:SCREENSHOT_DIR = $shotDir
$env:TESTOR_ARTIFACT_DIR = $artDir

$failure = $null
$global:LASTEXITCODE = 0
# Native output is decoded with the console code page (IBM850 here) once it passes through
# PowerShell, which would garble UTF-8 such as Vitest's check marks; UTF-8 both ways keeps it.
$encoding = [Console]::OutputEncoding
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$log = $null
try {
  $log = [IO.StreamWriter]::new($logFile, $false, [Text.UTF8Encoding]::new($false))
  $log.AutoFlush = $true
} catch { Write-Warning "testor: no log: $_" }
try {
  # Every line goes to the log; stdout stays stdout and a native program's stderr goes back to
  # stderr as plain text, so callers that separate the two (rust:fmt | sed) are unaffected.
  & $Body 2>&1 | ForEach-Object {
    if ($_ -is [Management.Automation.ErrorRecord] -and $_.Exception -is [Management.Automation.RemoteException]) {
      $line = $_.ToString()
      [Console]::Error.WriteLine($line)
      if ($log) { $log.WriteLine($line) }
    } else {
      if ($log) { $log.WriteLine($(if ($_ -is [string]) { $_ } else { ($_ | Out-String).TrimEnd() })) }
      $_
    }
  }
} catch {
  $failure = $_
  if ($log) { $log.WriteLine("`n" + ($_ | Out-String).TrimEnd()) }
} finally {
  [Console]::OutputEncoding = $encoding
  if ($log) { $log.Dispose() }
  # Runs on success, on failure and on Ctrl+C; a killed session is marked aborted by the server.
  try {
    $ended = Get-Date
    $exit = if ($failure -and $failure.Exception.PSObject.Properties["ExitCode"]) { $failure.Exception.ExitCode }
            elseif ($failure) { if ($LASTEXITCODE) { $LASTEXITCODE } else { 1 } }
            else { $LASTEXITCODE }
    $record.status = if ($failure -or $exit) { "failed" } else { "passed" }
    $record.exitCode = $exit
    if ($failure) { $record.error = ($failure.Exception.Message -split "`n")[0] }
    $record.endedAt = $ended.ToUniversalTime().ToString("o")
    $record.durationMs = [int]($ended - $started).TotalMilliseconds

    $videos = @()
    foreach ($file in @(Find-Media $workdir $false)) {
      if ($file.Extension -in $videoExt) { $videos += $file; continue }
      $rel = [IO.Path]::GetRelativePath($workdir, $file.FullName)
      $target = Join-Path $shotDir $rel
      $null = New-Item -ItemType Directory -Force -Path (Split-Path $target)
      Copy-Item -LiteralPath $file.FullName -Destination $target -Force
    }
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
