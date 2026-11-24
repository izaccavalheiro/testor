# Runs one task's command and records it for testor (the orchestrator reads these files).
# Needs PowerShell 7 (Windows, Linux or macOS). Next to it:
#   runs\<id>.json        project, kind, command, pid, start, end, status, exit code
#   logs\<id>.log         everything the command printed (it is still printed, unchanged)
#   screenshots\<id>\     images the run wrote under test-results, __screenshots__, screenshots
#                         or .vitest-attachments, plus anything saved to $env:SCREENSHOT_DIR
# The folders are next to this script (the testor home). Recording never fails a run: only
# the command's own error is rethrown, so output, stderr and the exit code are unchanged.
#
#   & "$HOME/test-run/.testor/run.ps1" -Project my-app -Kind test -Body { npm test }
#
# The command sees $env:TESTOR_RUN_ID and $env:SCREENSHOT_DIR (a folder kept with the run).
param(
  [Parameter(Mandatory)][string]$Project,
  [Parameter(Mandatory)][string]$Kind,
  [Parameter(Mandatory)][scriptblock]$Body
)

$root = $PSScriptRoot
$started = Get-Date
$workdir = (Get-Location).Path
$id = $started.ToUniversalTime().ToString("yyyyMMdd-HHmmss") + "-" + [guid]::NewGuid().ToString("N").Substring(0, 6)
$runFile = Join-Path (Join-Path $root "runs") "$id.json"
$logFile = Join-Path (Join-Path $root "logs") "$id.log"
$shotDir = Join-Path (Join-Path $root "screenshots") $id

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

function Find-Screenshots([string]$dir, [bool]$inShotFolder) {
  foreach ($item in Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue) {
    if ($item.PSIsContainer) {
      if ($item.Name -in "node_modules", "target", ".git", ".venv", "playwright-report") { continue }
      $shots = $inShotFolder -or ($item.Name -in "test-results", "__screenshots__", "screenshots", ".vitest-attachments")
      Find-Screenshots $item.FullName $shots
    } elseif ($inShotFolder -and $item.Extension -in ".png", ".jpg", ".jpeg", ".webp", ".gif" -and $item.LastWriteTime -ge $started) {
      $item
    }
  }
}

try {
  $null = New-Item -ItemType Directory -Force -Path (Join-Path $root "runs"), (Join-Path $root "logs"), $shotDir
} catch { Write-Warning "testor: $_" }
Save-Record
$env:TESTOR_RUN_ID = $id
$env:SCREENSHOT_DIR = $shotDir

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

    foreach ($file in @(Find-Screenshots $workdir $false)) {
      $rel = [IO.Path]::GetRelativePath($workdir, $file.FullName)
      $target = Join-Path $shotDir $rel
      $null = New-Item -ItemType Directory -Force -Path (Split-Path $target)
      Copy-Item -LiteralPath $file.FullName -Destination $target -Force
    }
    $images = @(Get-ChildItem -LiteralPath $shotDir -Recurse -File -ErrorAction SilentlyContinue)
    $record.screenshots = $images.Count
    if ($images.Count -eq 0) { Remove-Item -LiteralPath $shotDir -Recurse -Force -ErrorAction SilentlyContinue }
  } catch { Write-Warning "testor: $_" }
  Save-Record
}
if ($failure) { throw $failure }
# A non-zero exit that did not throw (no $PSNativeCommandUseErrorActionPreference) is handed back.
$global:LASTEXITCODE = $record.exitCode
