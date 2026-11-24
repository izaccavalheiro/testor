# End-to-end check of a built release on Windows: starts it with a temporary home on a spare
# port, records a passing and a failing run through run.ps1, and checks what the API and the
# SSE stream report. CI runs it after `mix release`; on a runner:
#
#   pwsh scripts/smoke.ps1 -Release orchestrator\_build\prod\rel\testor
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
Copy-Item (Join-Path $repo "runner\run.ps1") $testorHome
$base = "http://127.0.0.1:$Port"
$failures = @()
function Check([string]$what, [bool]$ok, $detail = "") {
  if ($ok) { "ok    $what" } else { "FAIL  $what $detail"; $script:failures += $what }
}

$env:TESTOR_HOME = $testorHome
$env:TESTOR_WORKSPACES = $work
$env:TESTOR_PORT = "$Port"
$bat = Join-Path (Resolve-Path $Release) "bin\testor.bat"
$server = Start-Process cmd.exe -ArgumentList "/c `"`"$bat`" start`"" -PassThru -WindowStyle Hidden
try {
  $deadline = (Get-Date).AddSeconds(60)
  do {
    Start-Sleep -Milliseconds 500
    try { $health = Invoke-RestMethod "$base/api/health" -TimeoutSec 2 } catch { $health = $null }
  } until ($health -or (Get-Date) -gt $deadline)
  Check "health" ([bool]$health) "(no answer on $base)"
  if (-not $health) { throw "testor did not start; see $testorHome\testor.log" }

  Set-Location $project
  & "$testorHome\run.ps1" -Project demo -Kind test -Body {
    # Vitest's marks, built here: this file stays ASCII for Windows PowerShell's parser.
    " $([char]0x2713) tests/a.test.ts (2 tests) 3ms"
    " $([char]0x276F) tests/b.test.ts (1 test | 1 failed) 2ms"
    [IO.File]::WriteAllBytes((Join-Path $env:SCREENSHOT_DIR "b-shot.png"), [Convert]::FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="))
  } | Out-Null
  $failed = $false
  try { & "$testorHome\run.ps1" -Project demo -Kind lint -Body { cmd /c "exit 3" } | Out-Null } catch { $failed = $true }
  Check "run.ps1 rethrows the command's failure" $failed

  $deadline = (Get-Date).AddSeconds(20)
  do {
    Start-Sleep -Milliseconds 500
    $state = Invoke-RestMethod "$base/api/state"
  } until (@($state.history).Count -ge 2 -or (Get-Date) -gt $deadline)
  $test = @($state.history) | Where-Object kind -eq "test" | Select-Object -First 1
  $lint = @($state.history) | Where-Object kind -eq "lint" | Select-Object -First 1
  Check "two runs in the history" (@($state.history).Count -eq 2) "($(@($state.history).Count))"
  Check "passing run recorded" ($test.status -eq "passed") "($($test.status))"
  Check "spec summary parsed" ($test.summary.specs -eq 2 -and $test.summary.failed -eq 1) "($($test.summary | ConvertTo-Json -Compress))"
  Check "screenshot kept" ($test.screenshots -eq 1) "($($test.screenshots))"
  Check "failing run recorded with its exit code" ($lint.status -eq "failed" -and $lint.exitCode -eq 3) "($($lint.status) $($lint.exitCode))"

  $detail = Invoke-RestMethod "$base/api/runs/$($test.id)"
  Check "screenshot matched to its spec" (@($detail.screenshots)[0].spec -eq "tests/b.test.ts") "($(@($detail.screenshots)[0].spec))"
  $shot = Invoke-WebRequest "$base$(@($detail.screenshots)[0].url)"
  Check "screenshot served" ($shot.StatusCode -eq 200 -and $shot.Headers["Content-Type"] -like "image/png*")

  # curl exits 28 when --max-time ends the stream, which is the point here.
  $PSNativeCommandUseErrorActionPreference = $false
  $sse = & curl.exe -sN --max-time 3 "$base/events" 2>$null
  $PSNativeCommandUseErrorActionPreference = $true
  Check "SSE stream starts with a snapshot" (($sse -join "`n") -match "event: snapshot")

  $refused = $false
  try { Invoke-RestMethod -Method Post "$base/api/cleanup" | Out-Null } catch { $refused = $true }
  Check "POST without X-Testor is refused" $refused

  $deadline = (Get-Date).AddSeconds(30)
  do { Start-Sleep -Seconds 1; $device = Invoke-RestMethod "$base/api/device" } until (($device.static -and $null -ne $device.sample.cpu) -or (Get-Date) -gt $deadline)
  Check "device stats" ([bool]$device.static -and $null -ne $device.sample.cpu) "(static: $([bool]$device.static), cpu: $($device.sample.cpu))"
  Check "device static facts" ($device.static.os.name -and $device.static.cpu.threads -gt 0) "($($device.static.os.name))"
} finally {
  Set-Location $repo
  Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*$((Resolve-Path $Release).Path)*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
  if ($failures.Count -and (Test-Path "$testorHome\testor.log")) { Get-Content -Tail 40 "$testorHome\testor.log" }
  Start-Sleep -Milliseconds 500
  Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
if ($failures.Count) { throw "$($failures.Count) smoke check(s) failed: $($failures -join ', ')" }
"all smoke checks passed"
