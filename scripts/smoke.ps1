# End-to-end check of a built release on Windows, Linux or macOS (PowerShell 7): starts it with a temporary home on a spare
# port, records a passing, a failing and a run with artifacts through run.ps1, and checks what
# the API, the SSE stream and the maintenance endpoints report. CI runs it after `mix release`; on a runner:
#
#   pwsh scripts/smoke.ps1 -Release orchestrator/_build/prod/rel/testor
param(
  [Parameter(Mandatory)][string]$Release,
  [int]$Port = 6799
)
$ErrorActionPreference = "Stop"
# As in the Taskfiles' sessions: a failing native command stops the script.
$PSNativeCommandUseErrorActionPreference = $true
$repo = Split-Path $PSScriptRoot
$work = Join-Path ([IO.Path]::GetTempPath()) ("testor-smoke-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$testorHome = Join-Path $work ".testor"
$project = Join-Path $work "demo"
$null = New-Item -ItemType Directory -Force -Path $testorHome, $project
Copy-Item (Join-Path (Join-Path $repo "runner") "run.ps1") $testorHome
$base = "http://127.0.0.1:$Port"
$failures = @()
function Check([string]$what, [bool]$ok, $detail = "") {
  if ($ok) { "ok    $what" } else { "FAIL  $what $detail"; $script:failures += $what }
}

$env:TESTOR_HOME = $testorHome
$env:TESTOR_WORKSPACES = $work
$env:TESTOR_PORT = "$Port"
$releasePath = (Resolve-Path $Release).Path
if ($IsWindows) {
  $bat = Join-Path $releasePath "bin\testor.bat"
  $server = Start-Process cmd.exe -ArgumentList "/c `"`"$bat`" start`"" -PassThru -WindowStyle Hidden
} else {
  $server = Start-Process (Join-Path $releasePath "bin/testor") -ArgumentList "start" -PassThru `
    -RedirectStandardOutput (Join-Path $work "stdout.log") -RedirectStandardError (Join-Path $work "stderr.log")
}
try {
  $deadline = (Get-Date).AddSeconds(60)
  do {
    Start-Sleep -Milliseconds 500
    try { $health = Invoke-RestMethod "$base/api/health" -TimeoutSec 2 } catch { $health = $null }
  } until ($health -or (Get-Date) -gt $deadline)
  Check "health" ([bool]$health) "(no answer on $base)"
  if (-not $health) { throw "testor did not start; see $testorHome\testor.log" }

  Set-Location $project
  & "$testorHome/run.ps1" -Project demo -Kind test -Body {
    # Vitest's marks, built here: this file stays ASCII for Windows PowerShell's parser.
    " $([char]0x2713) tests/a.test.ts (2 tests) 3ms"
    " $([char]0x276F) tests/b.test.ts (1 test | 1 failed) 2ms"
    [IO.File]::WriteAllBytes((Join-Path $env:SCREENSHOT_DIR "b-shot.png"), [Convert]::FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="))
  } | Out-Null
  $failed = $false
  try {
    & "$testorHome/run.ps1" -Project demo -Kind lint -Body { if ($IsWindows) { cmd /c "exit 3" } else { sh -c "exit 3" } } | Out-Null
  } catch { $failed = $true }
  Check "run.ps1 rethrows the command's failure" $failed

  & "$testorHome/run.ps1" -Project demo -Kind coverage -Artifacts report, "*.md", missing -Body {
    $null = New-Item -ItemType Directory -Force report, test-results/demo
    Set-Content -LiteralPath report/index.html -Value "<html><script>fetch('/api/state')</script></html>"
    Set-Content -LiteralPath report/data.json -Value '{"ok":true}'
    Set-Content -LiteralPath notes.md -Value "# notes"
    [IO.File]::WriteAllBytes((Join-Path (Get-Location) "test-results/demo/video.webm"), [byte[]](0..99))
    "coverage written"
  } | Out-Null

  $deadline = (Get-Date).AddSeconds(20)
  do {
    Start-Sleep -Milliseconds 500
    $state = Invoke-RestMethod "$base/api/state"
  } until (@($state.history).Count -ge 3 -or (Get-Date) -gt $deadline)
  $test = @($state.history) | Where-Object kind -eq "test" | Select-Object -First 1
  $lint = @($state.history) | Where-Object kind -eq "lint" | Select-Object -First 1
  $cov = @($state.history) | Where-Object kind -eq "coverage" | Select-Object -First 1
  Check "three runs in the history" (@($state.history).Count -eq 3) "($(@($state.history).Count))"
  Check "passing run recorded" ($test.status -eq "passed") "($($test.status))"
  Check "spec summary parsed" ($test.summary.specs -eq 2 -and $test.summary.failed -eq 1) "($($test.summary | ConvertTo-Json -Compress))"
  Check "screenshot kept" ($test.screenshots -eq 1) "($($test.screenshots))"
  Check "failing run recorded with its exit code" ($lint.status -eq "failed" -and $lint.exitCode -eq 3) "($($lint.status) $($lint.exitCode))"

  $detail = Invoke-RestMethod "$base/api/runs/$($test.id)"
  Check "screenshot matched to its spec" (@($detail.screenshots)[0].spec -eq "tests/b.test.ts") "($(@($detail.screenshots)[0].spec))"
  $shot = Invoke-WebRequest "$base$(@($detail.screenshots)[0].url)"
  Check "screenshot served" ($shot.StatusCode -eq 200 -and $shot.Headers["Content-Type"] -like "image/png*")

  Check "artifacts counted in the record" ($cov.artifacts -eq 4) "($($cov.artifacts))"
  $arts = @((Invoke-RestMethod "$base/api/runs/$($cov.id)").artifacts)
  $report = $arts | Where-Object kind -eq "report"
  $video = $arts | Where-Object kind -eq "video"
  Check "artifacts listed: a report, a Markdown file, a video" ($arts.Count -eq 3 -and $report.files -eq 2 -and $video -and ($arts | Where-Object path -eq "notes.md")) "($($arts | ConvertTo-Json -Compress))"
  $page = Invoke-WebRequest "$base$($report.url)"
  Check "report served in a sandbox" ($page.StatusCode -eq 200 -and "$($page.Headers["Content-Security-Policy"])" -like "sandbox*" -and "$($page.Headers["Content-Type"])" -like "text/html*")
  $part = Invoke-WebRequest "$base$($video.url)" -Headers @{ Range = "bytes=10-19" } -SkipHttpErrorCheck
  Check "video served by byte ranges" ($part.StatusCode -eq 206 -and $part.RawContentLength -eq 10 -and "$($part.Headers["Content-Range"])" -eq "bytes 10-19/100") "($($part.StatusCode) $($part.Headers["Content-Range"]))"
  $escape = Invoke-WebRequest "$base/artifacts/$($cov.id)/..%2F..%2Fruns%2F$($cov.id).json" -SkipHttpErrorCheck
  Check "artifacts stay inside their folder" ($escape.StatusCode -eq 404) "($($escape.StatusCode))"
  Check "artifacts gallery" (@(Invoke-RestMethod "$base/api/artifacts").Count -eq 1)

  # curl exits 28 when --max-time ends the stream, which is the point here.
  $PSNativeCommandUseErrorActionPreference = $false
  $curl = if ($IsWindows) { "curl.exe" } else { "curl" }
  $sse = & $curl -sN --max-time 3 "$base/events" 2>$null
  $PSNativeCommandUseErrorActionPreference = $true
  Check "SSE stream starts with a snapshot" (($sse -join "`n") -match "event: snapshot")

  $refused = $false
  try { Invoke-RestMethod -Method Post "$base/api/cleanup" | Out-Null } catch { $refused = $true }
  Check "POST without X-Testor is refused" $refused

  $h = @{ "X-Testor" = "1" }
  $null = Invoke-RestMethod -Method Post -Headers $h "$base/api/maintenance/scan"
  # The scan walks the temporary folder and the tool caches too, which CI machines fill.
  $deadline = (Get-Date).AddSeconds(180)
  do { Start-Sleep -Milliseconds 500; $maint = Invoke-RestMethod "$base/api/maintenance" } until ($maint.scan -or (Get-Date) -gt $deadline)
  Check "maintenance scan finds the project snapshot" ($maint.scan -and (@($maint.scan.targets).id -contains "snapshot:demo")) "($($maint | ConvertTo-Json -Compress -Depth 4))"
  Check "maintenance cleaning is off by default" ($maint.enabled -eq $false)
  $clean = Invoke-WebRequest -Method Post -Headers $h -ContentType "application/json" "$base/api/maintenance/clean" `
    -Body (@{ scanId = $maint.scan.id; targets = @("snapshot:demo") } | ConvertTo-Json) -SkipHttpErrorCheck
  Check "maintenance refuses to clean while off" ($clean.StatusCode -eq 403 -and (Test-Path $project)) "($($clean.StatusCode))"

  # Enabled (config.json is read on each request), it deletes the chosen snapshot and nothing else.
  Set-Location $work
  $keep = Join-Path $work "other"
  $null = New-Item -ItemType Directory -Force $keep
  '{ "maintenance": { "enabled": true } }' | Set-Content -LiteralPath (Join-Path $testorHome "config.json")
  $clean = Invoke-WebRequest -Method Post -Headers $h -ContentType "application/json" "$base/api/maintenance/clean" `
    -Body (@{ scanId = $maint.scan.id; targets = @("snapshot:demo") } | ConvertTo-Json) -SkipHttpErrorCheck
  Check "maintenance cleans when enabled" ($clean.StatusCode -eq 202) "($($clean.StatusCode) $($clean.Content))"
  $deadline = (Get-Date).AddSeconds(180)
  do { Start-Sleep -Milliseconds 500; $maint = Invoke-RestMethod "$base/api/maintenance" } until (($maint.lastClean -and $maint.scan) -or (Get-Date) -gt $deadline)
  $freed = @($maint.lastClean.targets) | Where-Object id -eq "snapshot:demo"
  Check "maintenance deleted the snapshot and reported it" (-not (Test-Path $project) -and $freed.freed -gt 0 -and @($freed.errors).Count -eq 0) "($($maint.lastClean | ConvertTo-Json -Compress -Depth 4))"
  Check "maintenance left the rest alone" ((Test-Path $keep) -and (Test-Path (Join-Path $testorHome "runs"))) ""
  Check "maintenance scanned again" (-not (@($maint.scan.targets).id -contains "snapshot:demo") -and (@($maint.scan.targets).id -contains "snapshot:other"))
  $stale = Invoke-WebRequest -Method Post -Headers $h -ContentType "application/json" "$base/api/maintenance/clean" `
    -Body (@{ scanId = "old"; targets = @("snapshot:other") } | ConvertTo-Json) -SkipHttpErrorCheck
  Check "maintenance refuses a stale scan" ($stale.StatusCode -eq 409 -and (Test-Path $keep)) "($($stale.StatusCode))"
  $unknown = Invoke-WebRequest -Method Post -Headers $h -ContentType "application/json" "$base/api/maintenance/clean" `
    -Body (@{ scanId = $maint.scan.id; targets = @("C:/Windows") } | ConvertTo-Json) -SkipHttpErrorCheck
  Check "maintenance refuses a target the scan does not have" ($unknown.StatusCode -eq 400) "($($unknown.StatusCode))"

  $deadline = (Get-Date).AddSeconds(30)
  do { Start-Sleep -Seconds 1; $device = Invoke-RestMethod "$base/api/device" } until (($device.static -and $null -ne $device.sample.cpu) -or (Get-Date) -gt $deadline)
  Check "device stats" ([bool]$device.static -and $null -ne $device.sample.cpu) "(static: $([bool]$device.static), cpu: $($device.sample.cpu))"
  Check "device static facts" ($device.static.os.name -and $device.static.cpu.threads -gt 0) "($($device.static.os.name))"
} finally {
  Set-Location $repo
  $PSNativeCommandUseErrorActionPreference = $false
  if ($IsWindows) {
    Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*$releasePath*" } |
      ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  } else {
    pkill -f "$releasePath/" 2>$null
  }
  Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
  if ($failures.Count) {
    foreach ($log in (Join-Path $testorHome "testor.log"), (Join-Path $work "stderr.log"), (Join-Path $work "stdout.log")) {
      if (Test-Path $log) { "--- $log"; Get-Content -Tail 40 $log }
    }
  }
  Start-Sleep -Milliseconds 500
  Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
if ($failures.Count) { throw "$($failures.Count) smoke check(s) failed: $($failures -join ', ')" }
"all smoke checks passed"
# curl's deliberate timeout (28) and the failing run's exit code (3) are not this script's.
$global:LASTEXITCODE = 0
