# End-to-end check of a built release on Windows, Linux or macOS (PowerShell 7): starts it with a temporary home on a spare
# port, records a passing, a failing and a run with artifacts through run.ps1, and checks what
# the API (the dashboard's and /api/v1), the SSE stream, MCP, the maintenance endpoints, the
# cancellation of a process tree, device stats and authentication (set up with the release's
# CLI) do. CI runs it after `mix release`; on a runner:
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

# The temporary folder and the tools' caches the maintenance scan measures: a sandbox, so the
# scan takes seconds on a runner whose real ones hold gigabytes.
$sandboxed = "TMP", "TEMP", "TMPDIR", "npm_config_cache", "PIP_CACHE_DIR", "GOCACHE", "CARGO_HOME", "PLAYWRIGHT_BROWSERS_PATH"
$savedEnv = @{}
foreach ($name in $sandboxed) {
  $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name)
  $dir = Join-Path (Join-Path $work "sandbox") $name
  $null = New-Item -ItemType Directory -Force $dir
  [Environment]::SetEnvironmentVariable($name, $dir)
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
  # A secret in the environment that the run prints: the terminal shows it, the log must not.
  $env:DEMO_API_TOKEN = "smoke-s3cret-value"
  & "$testorHome/run.ps1" -Project demo -Kind test -Body {
    "deploying with $env:DEMO_API_TOKEN"
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

  # The versioned API and MCP (authentication still off).
  $page1 = Invoke-RestMethod "$base/api/v1/runs?limit=2"
  Check "v1: runs are paged" (@($page1.data).Count -eq 2 -and $page1.next) "($($page1 | ConvertTo-Json -Compress -Depth 2))"
  $page2 = Invoke-RestMethod "$base/api/v1/runs?limit=2&before=$($page1.next)"
  Check "v1: the next page" (@($page2.data).Count -eq 1 -and -not $page2.next)
  $openapi = Invoke-RestMethod "$base/api/v1/openapi.json"
  Check "v1: OpenAPI document" ($openapi.openapi -eq "3.1.0" -and $openapi.paths."/runs")
  $grep = Invoke-WebRequest "$base/api/v1/runs/$($test.id)/log?grep=failed"
  $plain = Invoke-WebRequest "$base/api/v1/runs/$($test.id)/log"
  Check "secrets are masked in the stored log" ($plain.Content -match "deploying with \*\*\*" -and $plain.Content -notmatch "s3cret") "($($plain.Content))"
  Check "v1: log filtered" ($grep.Content -match "tests/b.test.ts" -and "$($grep.Headers["X-Log-Matches"])" -eq "1") "($($grep.Content))"
  # DNS rebinding: a name that is not this machine's is refused; IP addresses and localhost are not.
  $rebound = Invoke-WebRequest "$base/api/health" -Headers @{ Host = "rebind.attacker.example" } -SkipHttpErrorCheck
  Check "edge: an unknown Host is refused" ($rebound.StatusCode -eq 421) "($($rebound.StatusCode))"
  $local = Invoke-WebRequest "$base/api/health" -Headers @{ Host = "localhost" } -SkipHttpErrorCheck
  Check "edge: localhost is answered" ($local.StatusCode -eq 200) "($($local.StatusCode))"
  function Mcp($method, $params, $headers = @{}) {
    $body = @{ jsonrpc = "2.0"; id = 1; method = $method; params = $params } | ConvertTo-Json -Depth 6 -Compress
    Invoke-RestMethod -Method Post -ContentType "application/json" -Headers $headers "$base/mcp" -Body $body
  }
  $init = Mcp "initialize" @{ protocolVersion = "2025-06-18"; capabilities = @{}; clientInfo = @{ name = "smoke"; version = "1" } }
  Check "mcp: initialize" ($init.result.protocolVersion -eq "2025-06-18" -and $init.result.serverInfo.name -eq "testor")
  $tools = Mcp "tools/list" @{}
  Check "mcp: tools" (@($tools.result.tools).name -contains "get_run_log" -and @($tools.result.tools).name -contains "cancel_run")
  $listed = Mcp "tools/call" @{ name = "list_runs"; arguments = @{ status = "failed" } }
  Check "mcp: list_runs" (@($listed.result.structuredContent.runs).Count -eq 1 -and -not $listed.result.isError)

  # A mutation run hands over its report (-Reports): testor reads it when the run ends. A report
  # the run did not write is not kept.
  $null = New-Item -ItemType Directory -Force stale
  Set-Content -LiteralPath stale/old.json -Value '{}'
  (Get-Item stale/old.json).LastWriteTime = (Get-Date).AddDays(-1)
  & "$testorHome/run.ps1" -Project demo -Kind mutation -Reports "reports/mutation/mutation.json", "stale/old.json" -Body {
    $null = New-Item -ItemType Directory -Force reports/mutation
    $mutants = '[{"id":"1","mutatorName":"ArithmeticOperator","replacement":"-","status":"Killed","location":{"start":{"line":1,"column":1},"end":{"line":1,"column":2}}},' +
      '{"id":"2","mutatorName":"BooleanLiteral","replacement":"false","status":"Survived","location":{"start":{"line":1,"column":1},"end":{"line":1,"column":5}}}]'
    Set-Content -LiteralPath reports/mutation/mutation.json -Value ('{"schemaVersion":"2","thresholds":{"high":80,"low":60},"files":{"src/a.js":{"language":"javascript","source":"true + 1","mutants":' + $mutants + '}}}')
    "Final mutation score of 50.00 is greater than or equal to break threshold 0"
  } 3>$null | Out-Null
  $deadline = (Get-Date).AddSeconds(20)
  do {
    Start-Sleep -Milliseconds 500
    $mut = @((Invoke-RestMethod "$base/api/state").history) | Where-Object kind -eq "mutation" | Select-Object -First 1
  } until (($mut -and $mut.mutation) -or (Get-Date) -gt $deadline)
  Check "mutation: the report's score is in the record" ($mut.mutation.score -eq 50 -and $mut.mutation.source -eq "report") "($($mut.mutation | ConvertTo-Json -Compress))"
  Check "mutation: only the report the run wrote is kept" (@($mut.reports).Count -eq 1) "($(@($mut.reports).file -join ', '))"
  $mutDetail = Invoke-RestMethod "$base/api/runs/$($mut.id)"
  Check "mutation: surviving mutants with the run" (@($mutDetail.mutation.survivors)[0].original -eq "true" -and @($mutDetail.mutation.survivors)[0].replacement -eq "false")
  $badge = Invoke-WebRequest "$base/api/v1/projects/demo/badge.svg?metric=mutation"
  Check "mutation: a score badge" ($badge.Content -match "50\.0%")

  # A Jest run with jest-junit: its spec table comes from the report, not the log.
  & "$testorHome/run.ps1" -Project demo -Kind jest -Reports "junit.xml" -Body {
    Set-Content -LiteralPath junit.xml -Value ('<testsuites><testsuite name="sum"><testcase classname="sum" name="adds" time="0.01" file="src/sum.test.js"/>' +
      '<testcase classname="sum" name="fails" time="0.02" file="src/sum.test.js"><failure message="no"/></testcase></testsuite></testsuites>')
    "Tests: 1 failed, 1 passed, 2 total"
  } | Out-Null
  $deadline = (Get-Date).AddSeconds(20)
  do {
    Start-Sleep -Milliseconds 500
    $jest = @((Invoke-RestMethod "$base/api/state").history) | Where-Object kind -eq "jest" | Select-Object -First 1
  } until (($jest -and $jest.specsFrom) -or (Get-Date) -gt $deadline)
  Check "junit: the spec table from the report" ($jest.specsFrom -eq "reports" -and $jest.summary.tests -eq 2 -and $jest.summary.failed -eq 1) "($($jest.summary | ConvertTo-Json -Compress))"
  $exported = Invoke-WebRequest "$base/api/v1/runs/$($jest.id)/report.junit.xml"
  Check "junit: exported again" ($exported.Content -match 'testcase name="fails"')

  # A run past its timeout: its tree ended, recorded failed with reason timeout.
  $t0 = Get-Date
  $timedOut = $false
  try {
    & "$testorHome/run.ps1" -Project demo -Kind hang -TimeoutSeconds 3 -Body { pwsh -NoProfile -Command "Start-Sleep 60" } 2>$null | Out-Null
  } catch { $timedOut = $true }
  $hangSeconds = ((Get-Date) - $t0).TotalSeconds
  $deadline = (Get-Date).AddSeconds(15)
  do {
    Start-Sleep -Milliseconds 500
    $hang = @((Invoke-RestMethod "$base/api/state").history) | Where-Object kind -eq "hang" | Select-Object -First 1
  } until ($hang -or (Get-Date) -gt $deadline)
  Check "timeout: the run ends at its timeout" ($hangSeconds -lt 30 -and ($timedOut -or $LASTEXITCODE)) "($([math]::Round($hangSeconds)) s)"
  Check "timeout: recorded failed, reason timeout" ($hang.status -eq "failed" -and $hang.reason -eq "timeout") "($($hang.status) $($hang.reason))"

  # The memory guard ends a run that takes more than its share, before the system does.
  $total = [GC]::GetGCMemoryInfo().TotalAvailableMemoryBytes
  $grab = [long][math]::Min($total * 0.04, 3GB)
  if ($total * 0.02 -lt 2.5GB) {
    try {
      & "$testorHome/run.ps1" -Project demo -Kind greedy -MemoryGuard "1,2" -TimeoutSeconds 60 -Body {
        pwsh -NoProfile -Command "`$a = [byte[]]::new($grab); [Array]::Fill(`$a, [byte]1); Start-Sleep 50"
      } 2>$null | Out-Null
    } catch { }
    $deadline = (Get-Date).AddSeconds(15)
    do {
      Start-Sleep -Milliseconds 500
      $greedy = @((Invoke-RestMethod "$base/api/state").history) | Where-Object kind -eq "greedy" | Select-Object -First 1
    } until ($greedy -or (Get-Date) -gt $deadline)
    Check "memory guard: the run is ended, reason memory" ($greedy.status -eq "failed" -and $greedy.reason -eq "memory") "($($greedy.status) $($greedy.reason) $($greedy.error))"
  } else { "skip  memory guard: this machine has too much memory for the check" }

  # TESTOR_LOCK (remote.yml's SSH runs): a second run of the project waits for the first.
  $bg = if ($IsWindows) { @{ WindowStyle = "Hidden" } } else { @{ RedirectStandardOutput = (Join-Path $work "lock.out"); RedirectStandardError = (Join-Path $work "lock.err") } }
  $lockWait = Start-Process pwsh -PassThru @bg -ArgumentList "-NoProfile", "-Command", "`$env:TESTOR_LOCK = '1'; & '$testorHome/run.ps1' -Project locked -Kind first -Body { Start-Sleep 6 }"
  Start-Sleep -Seconds 2
  $env:TESTOR_LOCK = "1"
  $t0 = Get-Date
  & "$testorHome/run.ps1" -Project locked -Kind second -Body { "quick" } 3>$null 2>$null | Out-Null
  $env:TESTOR_LOCK = $null
  $lockWait.WaitForExit()
  Check "lock: a second run of the project waits for the first" (((Get-Date) - $t0).TotalSeconds -ge 3)

  # Cancelling kills the run's whole process tree, on every OS.
  $hidden = if ($IsWindows) { @{ WindowStyle = "Hidden" } } else { @{} }
  $slowErr = Join-Path $work "slow.err"
  if (-not $IsWindows) { $hidden = @{ RedirectStandardError = $slowErr; RedirectStandardOutput = (Join-Path $work "slow.out") } }
  $slow = Start-Process pwsh -PassThru @hidden -ArgumentList "-NoProfile", "-Command", "& '$testorHome/run.ps1' -Project slow -Kind slow -Body { pwsh -NoProfile -Command 'Start-Sleep 120' }"
  $deadline = (Get-Date).AddSeconds(30)
  do { Start-Sleep -Milliseconds 500; $running = @((Invoke-RestMethod "$base/api/v1/runs?status=running").data) } until ($running.Count -or (Get-Date) -gt $deadline)
  Check "a long run is seen running" ($running.Count -eq 1)
  Check "the run records who started it" ($running[0].actor.user -eq [Environment]::UserName) "($($running[0].actor | ConvertTo-Json -Compress))"
  # run.ps1 ends its own tree when asked: the request testor writes (cancel/<id>) is enough.
  $runPid = (Invoke-RestMethod "$base/api/runs/$($running[0].id)").run.pid
  $null = New-Item -ItemType Directory -Force (Join-Path $testorHome "cancel")
  Set-Content -LiteralPath (Join-Path (Join-Path $testorHome "cancel") $running[0].id) -Value ""
  $ended = $slow.WaitForExit(4000)
  $state = if ($IsWindows -or $ended) { "" } else { "; ps: " + ((ps -o pid=,stat=,comm= -p $runPid 2>$null) -join " ") + "; children: " + ((ps -A -o pid=,ppid=,stat=,comm= | Where-Object { (-split $_)[1] -eq "$runPid" }) -join " | ") + "; stderr: " + ((Get-Content $slowErr -ErrorAction SilentlyContinue) -join " / ") }
  Check "the run ended itself when asked" $ended "(pid $runPid still there after 4 s$state)"
  $cancel = Invoke-RestMethod -Method Post -ContentType "application/json" "$base/api/v1/runs/$($running[0].id)/cancel" -Body "{}"
  Check "cancel settles the run" ($cancel.status -eq "cancelled" -and -not $cancel.warning) "($($cancel.warning))"
  $gone = $slow.WaitForExit(15000)
  Check "cancel killed the process tree" $gone

  # Finished runs are signed: an in-toto statement in a DSSE envelope.
  $deadline = (Get-Date).AddSeconds(15)
  do { Start-Sleep -Milliseconds 500; $att = Invoke-WebRequest "$base/api/v1/runs/$($test.id)/attestation" -SkipHttpErrorCheck } until ($att.StatusCode -eq 200 -or (Get-Date) -gt $deadline)
  $statement = if ($att.StatusCode -eq 200) { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($att.Content | ConvertFrom-Json).payload)) | ConvertFrom-Json }
  Check "a finished run is attested" ($statement.predicate.run.id -eq $test.id -and @($statement.subject).name -contains "log") "($($att.StatusCode))"
  $key = Invoke-RestMethod "$base/api/v1/attestation/key"
  Check "the attestation key is published" ($key.algorithm -eq "ed25519" -and $key.publicKey -match "BEGIN PUBLIC KEY")

  $deadline = (Get-Date).AddSeconds(30)
  do { Start-Sleep -Seconds 1; $device = Invoke-RestMethod "$base/api/device" } until (($device.static -and $null -ne $device.sample.cpu) -or (Get-Date) -gt $deadline)
  Check "device stats" ([bool]$device.static -and $null -ne $device.sample.cpu) "(static: $([bool]$device.static), cpu: $($device.sample.cpu))"
  Check "device static facts" ($device.static.os.name -and $device.static.cpu.threads -gt 0) "($($device.static.os.name))"

  # Authentication, set up with the release's CLI: from now on everything needs credentials.
  # No parentheses or double quotes in eval's expression: testor.bat hands it through cmd.exe.
  $bin = Join-Path $releasePath $(if ($IsWindows) { "bin/testor.bat" } else { "bin/testor" })
  $env:TESTOR_PASSWORD = "smoke-test-password"
  & $bin eval "Testor.Auth.CLI.user ~s[smoke], ~s[admin]" | Out-Null
  & $bin eval "Testor.Auth.CLI.user ~s[viewer], ~s[viewer]" | Out-Null
  Remove-Item Env:TESTOR_PASSWORD
  Start-Sleep -Milliseconds 1500
  $anon = Invoke-WebRequest "$base/api/v1/runs" -SkipHttpErrorCheck
  Check "auth: credentials required" ($anon.StatusCode -eq 401 -and "$($anon.Headers["WWW-Authenticate"])" -like "Basic*") "($($anon.StatusCode))"
  $health = Invoke-RestMethod "$base/api/health"
  Check "auth: health stays public" ($health.ok -and $health.auth -and -not $health.home)
  $basic = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("smoke:smoke-test-password")) }
  $viewer = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("viewer:smoke-test-password")) }
  Check "auth: Basic" ((Invoke-WebRequest "$base/api/v1/runs" -Headers $basic).StatusCode -eq 200)
  $wrong = Invoke-WebRequest "$base/api/v1/runs" -Headers @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("smoke:nope")) } -SkipHttpErrorCheck
  Check "auth: a wrong password is refused" ($wrong.StatusCode -eq 401)
  $token = Invoke-RestMethod -Method Post -Headers $basic -ContentType "application/x-www-form-urlencoded" "$base/api/v1/auth/token" -Body "grant_type=client_credentials&scope=read"
  $bearer = @{ Authorization = "Bearer $($token.access_token)" }
  $me = Invoke-RestMethod "$base/api/v1/auth/me" -Headers $bearer
  Check "auth: a Bearer token from the token endpoint" ($me.user -eq "smoke" -and $me.via -eq "bearer" -and "$($me.scopes)" -eq "read")
  $forbidden = Invoke-WebRequest -Method Post -Headers $bearer "$base/api/v1/cleanup" -SkipHttpErrorCheck
  Check "auth: a read token cannot change anything" ($forbidden.StatusCode -eq 403)
  $denied = Invoke-WebRequest -Method Post -Headers ($viewer + @{ "X-Testor" = "1" }) "$base/api/cleanup" -SkipHttpErrorCheck
  Check "auth: a viewer cannot change anything" ($denied.StatusCode -eq 403)
  $cliToken = (& $bin eval "Testor.Auth.CLI.token ~s[smoke], 1" | Select-Object -Last 1).Trim()
  $mcp = Mcp "tools/call" @{ name = "list_runs"; arguments = @{} } @{ Authorization = "Bearer $cliToken" }
  Check "auth: MCP with a token from the CLI" (@($mcp.result.structuredContent.runs).Count -ge 3)
  $mcpAnon = Invoke-WebRequest -Method Post -ContentType "application/json" "$base/mcp" -Body '{"jsonrpc":"2.0","id":1,"method":"ping"}' -SkipHttpErrorCheck
  Check "auth: MCP needs credentials" ($mcpAnon.StatusCode -eq 401)
  $signed = @((Invoke-RestMethod "$base/api/v1/runs/$($test.id)" -Headers $basic).screenshots)[0].url
  Check "auth: screenshots are linked signed" ($signed -like "/s/*")
  Check "auth: a signed link needs no credentials" ((Invoke-WebRequest "$base$signed").StatusCode -eq 200)
  Check "auth: links are bound to their viewer (v2)" ($signed -like "/s/v2.*")
  Check "auth: the viewer opens it" ((Invoke-WebRequest "$base$signed" -Headers $basic).StatusCode -eq 200)
  $other = Invoke-WebRequest "$base$signed" -Headers $viewer -SkipHttpErrorCheck
  Check "auth: another signed-in user gets 403" ($other.StatusCode -eq 403)
  $parts = $signed.Split("/")[2].Split(".")
  $stale = $signed.Replace($parts[1], [string]([long]$parts[1] - 3600))
  $staleReply = Invoke-WebRequest "$base$stale" -SkipHttpErrorCheck
  Check "auth: a stale link opens nothing" ($staleReply.StatusCode -eq 404)
  $plain = Invoke-WebRequest "$base/shots/$($test.id)/$(Split-Path -Leaf $signed)" -SkipHttpErrorCheck
  Check "auth: an unsigned link does" ($plain.StatusCode -eq 401)
  & $bin eval "Testor.Auth.CLI.revoke ~s[smoke]" | Out-Null
  Start-Sleep -Milliseconds 1500
  $revoked = Invoke-WebRequest "$base/api/v1/auth/me" -Headers $bearer -SkipHttpErrorCheck
  Check "auth: revoked tokens stop working" ($revoked.StatusCode -eq 401)

  # The terminal stays unchanged: a run's stderr holds only what the command wrote there.
  $quietErr = Join-Path $work "quiet.err"
  $quietDir = New-Item -ItemType Directory -Force (Join-Path $work "quiet")
  $quiet = Start-Process pwsh -Wait -PassThru -RedirectStandardError $quietErr -RedirectStandardOutput (Join-Path $work "quiet.out") `
    -ArgumentList "-NoProfile", "-Command", "Set-Location '$quietDir'; & '$testorHome/run.ps1' -Project quiet -Kind quiet -Body { 'ok' }"
  $stray = (Get-Content -Raw -LiteralPath $quietErr -ErrorAction SilentlyContinue) + ""
  Check "run.ps1 writes nothing of its own to stderr" ($quiet.ExitCode -eq 0 -and $stray.Trim() -eq "") "($($stray.Trim()))"

  # Jobs: queued through the API, taken by an agent (runner/agent.ps1) that runs them through
  # run.ps1 with the commands of its own configuration.
  $configFile = Join-Path $testorHome "config.json"
  # testor reads config.json now and then; on Windows a read in progress keeps it from being
  # written for a moment: try again.
  function Write-Config {
    param([Parameter(ValueFromPipeline)][string[]]$Text, [string]$Path = $configFile)
    begin { $lines = @() }
    process { $lines += $Text }
    end {
      for ($try = 1; ; $try++) {
        try { Set-Content -LiteralPath $Path -Value $lines -ErrorAction Stop; return }
        catch { if ($try -ge 20) { throw }; Start-Sleep -Milliseconds 100 }
      }
    }
  }
  $config = if (Test-Path $configFile) { Get-Content -Raw $configFile | ConvertFrom-Json -AsHashtable } else { @{} }
  $config.execution = @{ enabled = $true; leaseSeconds = 30; maxAttempts = 3 }
  $config | ConvertTo-Json -Depth 5 | Write-Config
  $env:TESTOR_PASSWORD = "smoke-test-password"
  & $bin eval "Testor.Auth.CLI.user ~s[smoke-agent], ~s[agent]" | Out-Null
  Remove-Item Env:TESTOR_PASSWORD
  Start-Sleep -Milliseconds 1500
  $env:TESTOR_AGENT_TOKEN = (& $bin eval "Testor.Auth.CLI.token ~s[smoke-agent], 1" | Select-Object -Last 1).Trim()
  $jobsDir = New-Item -ItemType Directory -Force (Join-Path $work "jobs-demo")
  $agentConfig = Join-Path $work "agent.json"
  @{ server = $base; home = $testorHome; labels = @("smoke")
     projects = @{ "jobs-demo" = @{ workspace = "$jobsDir"; commands = @{ hello = "'hello from a job'"; slow = "Start-Sleep 60" } } } } |
    ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $agentConfig
  $agentScript = Join-Path $repo "runner/agent.ps1"
  function New-Job($kind) {
    Invoke-RestMethod -Method Post -Headers $basic -ContentType "application/json" "$base/api/v1/jobs" `
      -Body (@{ project = "jobs-demo"; kind = $kind; labels = @("smoke") } | ConvertTo-Json)
  }
  function Get-Job($id) { Invoke-RestMethod -Headers $basic "$base/api/v1/jobs/$id" }

  $hello = New-Job "hello"
  pwsh -NoProfile -File $agentScript -Config $agentConfig -Once -Wait 5 | Out-Null
  # The store reads the run's record within a moment of its end; the job links it then.
  $deadline = (Get-Date).AddSeconds(10)
  do { $done = Get-Job $hello.id; if (-not $done.runId) { Start-Sleep -Milliseconds 300 } } until ($done.runId -or (Get-Date) -gt $deadline)
  # The run's end reaches the store within a moment too: wait for it to settle.
  $deadline = (Get-Date).AddSeconds(10)
  do {
    $run = if ($done.runId) { (Invoke-RestMethod -Headers $basic "$base/api/v1/runs/$($done.runId)").run }
    if ($run.status -eq "running") { Start-Sleep -Milliseconds 300 }
  } until ($run.status -ne "running" -or (Get-Date) -gt $deadline)
  $runLog = if ($done.runId) { Invoke-RestMethod -Headers $basic "$base/api/v1/runs/$($done.runId)/log" }
  Check "jobs: an agent runs a queued job" ($done.status -eq "passed" -and $done.exitCode -eq 0) "($($done | ConvertTo-Json -Compress))"
  Check "jobs: the job's run is recorded and names the job" ($run.job -eq $hello.id -and $run.status -eq "passed" -and "$runLog" -match "hello from a job") "($($run | ConvertTo-Json -Compress))"

  $refused = New-Job "deploy"
  pwsh -NoProfile -File $agentScript -Config $agentConfig -Once -Wait 5 | Out-Null
  $refused = Get-Job $refused.id
  Check "jobs: a task the agent does not list is refused" ($refused.status -eq "failed" -and $refused.error -match "not in this agent") "($($refused | ConvertTo-Json -Compress))"

  # Secrets: resolved by the agent from where agent.json says (env, file, Vault, the clouds'
  # CLIs, SOPS), given to the run's environment, and written as *** in its log.
  $tools = New-Item -ItemType Directory -Force (Join-Path $work "secret-tools")
  @{ aws = "'{""user"":""aws-user"",""password"":""aws-secret-value-1""}'"
     gcloud = "if (`$args -contains '--project=smoke-project' -and `$args -contains '--secret=db') { 'gcp-secret-value-2' } else { 'wrong' }"
     az = "if (`$args -contains 'smoke-vault') { 'azure-secret-value-3' } else { 'wrong' }"
     sops = "'-----BEGIN KEY-----'; 'sops-line-one-secret'; 'sops-line-two-secret'; '-----END KEY-----'" }.GetEnumerator() |
    ForEach-Object { Set-Content -LiteralPath (Join-Path $tools "$($_.Key).ps1") -Value "$($_.Value)`nexit 0" }
  $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $probe.Start(); $vaultPort = $probe.LocalEndpoint.Port; $probe.Stop()
  $vaultListener = [Net.HttpListener]::new()
  $vaultListener.Prefixes.Add("http://localhost:$vaultPort/")
  $vaultListener.Start()
  $vault = [powershell]::Create().AddScript({
      param($listener)
      while ($listener.IsListening) {
        try { $context = $listener.GetContext() } catch { break }
        $request = $context.Request
        $body = (New-Object IO.StreamReader($request.InputStream)).ReadToEnd()
        $answer, $status =
          if ($request.Url.AbsolutePath -eq "/v1/auth/kubernetes/login" -and $body -match "sa-jwt-of-the-pod") { '{"auth":{"client_token":"vault-token-of-the-agent"}}', 200 }
          elseif ($request.Url.AbsolutePath -eq "/v1/secret/data/smoke" -and $request.Headers["X-Vault-Token"] -eq "vault-token-of-the-agent") { '{"data":{"data":{"api_key":"vault-secret-value-4"},"metadata":{"version":1}}}', 200 }
          else { '{"errors":["permission denied"]}', 403 }
        $bytes = [Text.Encoding]::UTF8.GetBytes($answer)
        $context.Response.StatusCode = $status
        $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $context.Response.Close()
      }
    }).AddArgument($vaultListener)
  $null = $vault.BeginInvoke()
  $saToken = Join-Path $work "sa-token"; Set-Content -LiteralPath $saToken -Value "sa-jwt-of-the-pod"
  $secretFile = Join-Path $work "db-password"; Set-Content -LiteralPath $secretFile -Value "file-secret-value-5"
  $env:SMOKE_SOURCE_SECRET = "env-secret-value-6"
  $secretValues = "aws-secret-value-1", "gcp-secret-value-2", "azure-secret-value-3", "sops-line-one-secret", "sops-line-two-secret", "vault-secret-value-4", "file-secret-value-5", "env-secret-value-6"
  $secretsConfig = Join-Path $work "agent-secrets.json"
  $show = '"aws=$env:S_AWS gcp=$env:S_GCP az=$env:S_AZ vault=$env:S_VAULT file=$env:S_FILE env=$env:S_ENV"; $env:S_SOPS; "secrets-shown"'
  @{ server = $base; home = $testorHome; labels = @("smoke")
     vault = @{ address = "http://localhost:$vaultPort"; kubernetesRole = "smoke"; jwtFile = $saToken }
     secretTools = @{ aws = "$tools/aws.ps1"; gcloud = "$tools/gcloud.ps1"; az = "$tools/az.ps1"; sops = "$tools/sops.ps1" }
     projects = @{
       "secret-demo" = @{ workspace = "$jobsDir"; commands = @{ show = $show }
         secrets = @{ S_AWS = "aws:smoke/app#password"; S_GCP = "gcp:projects/smoke-project/secrets/db"; S_AZ = "azure:smoke-vault/api"
                      S_VAULT = "vault:secret/data/smoke#api_key"; S_FILE = "file:$secretFile"; S_ENV = "env:SMOKE_SOURCE_SECRET"
                      S_SOPS = "sops:$work/secrets.enc.yaml#key" } }
       "secret-broken" = @{ workspace = "$jobsDir"; commands = @{ show = "'never'" }; secrets = @{ S_MISSING = "env:SMOKE_NOT_SET" } } } } |
    ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $secretsConfig
  $secretJob = Invoke-RestMethod -Method Post -Headers $basic -ContentType "application/json" "$base/api/v1/jobs" `
    -Body (@{ project = "secret-demo"; kind = "show"; labels = @("smoke") } | ConvertTo-Json)
  pwsh -NoProfile -File $agentScript -Config $secretsConfig -Once -Wait 5 | Out-Null
  $deadline = (Get-Date).AddSeconds(15)
  do {
    $secretDone = Get-Job $secretJob.id
    $secretLog = if ($secretDone.runId) { try { "$(Invoke-RestMethod -Headers $basic "$base/api/v1/runs/$($secretDone.runId)/log")" } catch { "" } }
    if ($secretLog -notmatch "secrets-shown") { Start-Sleep -Milliseconds 300 }
  } until ($secretLog -match "secrets-shown" -or (Get-Date) -gt $deadline)
  $leaked = @($secretValues | Where-Object { $secretLog.Contains($_) })
  Check "secrets: the agent resolves a job's secrets from env, file, Vault, AWS, GCP, Azure and SOPS" ($secretDone.status -eq "passed" -and $secretLog -match "aws=\*\*\* gcp=\*\*\* az=\*\*\* vault=\*\*\* file=\*\*\* env=\*\*\*") "($($secretDone | ConvertTo-Json -Compress))"
  Check "secrets: their values never reach the log, each line of a multi-line one included" ($secretLog -match "secrets-shown" -and $leaked.Count -eq 0) "(leaked: $($leaked.Count))"
  $brokenJob = Invoke-RestMethod -Method Post -Headers $basic -ContentType "application/json" "$base/api/v1/jobs" `
    -Body (@{ project = "secret-broken"; kind = "show"; labels = @("smoke") } | ConvertTo-Json)
  pwsh -NoProfile -File $agentScript -Config $secretsConfig -Once -Wait 5 | Out-Null
  $broken = Get-Job $brokenJob.id
  Check "secrets: a secret that cannot be read fails the job, naming it" ($broken.status -eq "failed" -and $broken.error -match "S_MISSING" -and -not $broken.runId) "($($broken | ConvertTo-Json -Compress))"
  $vaultListener.Stop(); $vault.Dispose()

  # Identity: testor issues a job its token (jobTokens in auth.json), which the agent writes where
  # the run reads it; clouds and Vault check it against testor's published keys.
  $authFile = Join-Path $testorHome "auth.json"
  $auth = Get-Content -Raw -LiteralPath $authFile | ConvertFrom-Json -AsHashtable
  $auth.jobTokens = @{ issuer = "https://testor.example.com"; audiences = @("smoke-audience") }
  $auth | ConvertTo-Json -Depth 8 | Write-Config -Path $authFile
  Start-Sleep -Milliseconds 2000
  $idConfig = Join-Path $work "agent-identity.json"
  $showToken = '$p = (Get-Content -Raw $env:SMOKE_TOKEN_FILE).Split(".")[1].Replace("-", "+").Replace("_", "/"); $p += "=" * ((4 - $p.Length % 4) % 4); $c = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json; "sub=$($c.sub) aud=$($c.aud) role=$env:SMOKE_ROLE"; "token=$env:TESTOR_ID_TOKEN"'
  @{ server = $base; home = $testorHome; labels = @("smoke")
     projects = @{ "id-demo" = @{ workspace = "$jobsDir"; commands = @{ show = $showToken }
                                  identity = @{ audience = "smoke-audience"; file = "SMOKE_TOKEN_FILE"; env = @{ SMOKE_ROLE = "role-of-the-job" } } } } } |
    ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $idConfig
  $idJob = Invoke-RestMethod -Method Post -Headers $basic -ContentType "application/json" "$base/api/v1/jobs" `
    -Body (@{ project = "id-demo"; kind = "show"; labels = @("smoke") } | ConvertTo-Json)
  pwsh -NoProfile -File $agentScript -Config $idConfig -Once -Wait 5 | Out-Null
  $deadline = (Get-Date).AddSeconds(15)
  do {
    $idDone = Get-Job $idJob.id
    $idLog = if ($idDone.runId) { try { "$(Invoke-RestMethod -Headers $basic "$base/api/v1/runs/$($idDone.runId)/log")" } catch { "" } }
    if ($idLog -notmatch "token=") { Start-Sleep -Milliseconds 300 }
  } until ($idLog -match "token=" -or (Get-Date) -gt $deadline)
  Check "identity: a job gets its identity token from testor, where agent.json says" ($idDone.status -eq "passed" -and $idLog -match "sub=project:id-demo:kind:show aud=smoke-audience role=role-of-the-job" -and $idLog -match "token=\*\*\*") "($idLog)"
  $discovery = Invoke-RestMethod "$base/.well-known/openid-configuration"
  $jwks = Invoke-RestMethod "$base/.well-known/jwks.json"
  Check "identity: testor publishes its issuer and the job tokens' RS256 key" ($discovery.issuer -eq "https://testor.example.com" -and @($jwks.keys | Where-Object kty -eq "RSA").Count -eq 1) "($($discovery | ConvertTo-Json -Compress))"
  Remove-Item Env:SMOKE_SOURCE_SECRET

  # Isolation: each job runs in a worktree (git) or a copy of the workspace, removed after, so
  # what one run writes is not there for the next.
  $isoGit = New-Item -ItemType Directory -Force (Join-Path $work "iso-git")
  Set-Content -LiteralPath (Join-Path $isoGit "tracked.txt") -Value "tracked"
  git -C $isoGit init --quiet
  git -C $isoGit add tracked.txt
  git -C $isoGit -c user.name=smoke -c user.email=smoke@example.invalid commit --quiet -m init
  $isoCopy = New-Item -ItemType Directory -Force (Join-Path $work "iso-copy")
  Set-Content -LiteralPath (Join-Path $isoCopy "tracked.txt") -Value "tracked"
  $isoConfig = Join-Path $work "agent-isolated.json"
  $probe = "if (Test-Path leftover.txt) { 'iso-dirty' } else { 'iso-clean' }; if (Test-Path tracked.txt) { 'iso-has-files' }; Set-Content leftover.txt 'from a job'"
  @{ server = $base; home = $testorHome; labels = @("smoke")
     projects = @{ "iso-git" = @{ workspace = "$isoGit"; git = $true; isolate = "worktree"; commands = @{ probe = $probe } }
                   "iso-copy" = @{ workspace = "$isoCopy"; isolate = "copy"; commands = @{ probe = $probe } } } } |
    ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $isoConfig
  foreach ($isoProject in "iso-git", "iso-copy") {
    $isoLogs = foreach ($attempt in 1, 2) {
      $isoJob = Invoke-RestMethod -Method Post -Headers $basic -ContentType "application/json" "$base/api/v1/jobs" `
        -Body (@{ project = $isoProject; kind = "probe"; labels = @("smoke") } | ConvertTo-Json)
      pwsh -NoProfile -File $agentScript -Config $isoConfig -Once -Wait 5 | Out-Null
      $deadline = (Get-Date).AddSeconds(15)
      do {
        $isoDone = Get-Job $isoJob.id
        $isoLog = if ($isoDone.runId) { try { "$(Invoke-RestMethod -Headers $basic "$base/api/v1/runs/$($isoDone.runId)/log")" } catch { "" } }
        if ($isoLog -notmatch "iso-") { Start-Sleep -Milliseconds 300 }
      } until ($isoLog -match "iso-" -or (Get-Date) -gt $deadline)
      "$($isoDone.status): $isoLog"
    }
    $workspaceDir = if ($isoProject -eq "iso-git") { $isoGit } else { $isoCopy }
    $leftovers = @(Get-ChildItem -LiteralPath (Join-Path $testorHome "isolated") -ErrorAction SilentlyContinue).Count
    Check "isolation ($isoProject): each job starts clean, with the workspace's files, and leaves nothing behind" (
      @($isoLogs | Where-Object { $_ -match "(?s)^passed: .*iso-clean.*iso-has-files" }).Count -eq 2 -and
      -not (Test-Path -LiteralPath (Join-Path $workspaceDir "leftover.txt")) -and $leftovers -eq 0) "($($isoLogs -join ' | '); left: $leftovers)"
  }

  # Release gates: a job's run records the commit it checked out; the gate passes on it from
  # the run's signed result.
  $config = Get-Content -Raw -LiteralPath $configFile | ConvertFrom-Json -AsHashtable
  $config.gates = @{ "iso-release" = @{ project = "iso-git"; kinds = @("probe") } }
  $config | ConvertTo-Json -Depth 6 | Write-Config
  $isoHead = "$(git -C $isoGit rev-parse HEAD)".Trim()
  $deadline = (Get-Date).AddSeconds(15)
  do {
    $gate = Invoke-RestMethod -Headers $basic "$base/api/v1/gates/iso-release?commit=$isoHead"
    if (-not $gate.pass) { Start-Sleep -Milliseconds 500 }
  } until ($gate.pass -or (Get-Date) -gt $deadline)
  Check "gates: a job's run records its commit, and the gate passes on its signed result" ($gate.pass -and $gate.checks[0].runId) "($($gate | ConvertTo-Json -Depth 4 -Compress))"
  $gatedRun = if ($gate.checks[0].runId) { (Invoke-RestMethod -Headers $basic "$base/api/v1/runs/$($gate.checks[0].runId)").run }
  Check "dora: a job's run records when its commit was made (lead time)" ($null -ne $gatedRun.source.committedAt) "($($gatedRun.source | ConvertTo-Json -Compress))"
  $other = Invoke-RestMethod -Headers $basic "$base/api/v1/gates/iso-release?commit=abcdef0"
  Check "gates: another commit does not pass" (-not $other.pass -and $other.checks[0].reason -match "no finished run") "($($other | ConvertTo-Json -Depth 4 -Compress))"

  $slowJob = New-Job "slow"
  $slowAgent = Start-Process pwsh -PassThru @hidden -ArgumentList "-NoProfile", "-File", $agentScript, "-Config", $agentConfig, "-Once", "-Wait", "5"
  $deadline = (Get-Date).AddSeconds(30)
  do { Start-Sleep -Milliseconds 500; $slowRun = @((Invoke-RestMethod -Headers $basic "$base/api/v1/runs?status=running").data | Where-Object job -eq $slowJob.id) } until ($slowRun.Count -or (Get-Date) -gt $deadline)
  $null = Invoke-RestMethod -Method Post -Headers $basic -ContentType "application/json" "$base/api/v1/jobs/$($slowJob.id)/cancel" -Body "{}"
  $agentEnded = $slowAgent.WaitForExit(40000)
  $cancelled = Get-Job $slowJob.id
  Check "jobs: cancelling a running job ends its run and the job" ($slowRun.Count -eq 1 -and $agentEnded -and $cancelled.status -eq "cancelled") "($($cancelled | ConvertTo-Json -Compress))"

  # An agent on "another machine": a home of its own, its runs sent to testor over HTTP. An
  # agent user of its own too: testor pins each agent user's signing key.
  $env:TESTOR_PASSWORD = "smoke-test-password"
  & $bin eval "Testor.Auth.CLI.user ~s[far-agent], ~s[agent]" | Out-Null
  Remove-Item Env:TESTOR_PASSWORD
  Start-Sleep -Milliseconds 1500
  $env:TESTOR_AGENT_TOKEN = (& $bin eval "Testor.Auth.CLI.token ~s[far-agent], 1" | Select-Object -Last 1).Trim()
  $farHome = New-Item -ItemType Directory -Force (Join-Path $work "far-home")
  Copy-Item (Join-Path (Join-Path $repo "runner") "run.ps1") $farHome
  $farDir = New-Item -ItemType Directory -Force (Join-Path $work "far-app")
  $farConfig = Join-Path $work "far-agent.json"
  $png = "[IO.File]::WriteAllBytes((Join-Path `$env:SCREENSHOT_DIR 'far.png'), [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=='))"
  @{ server = $base; home = "$farHome"; upload = $true; labels = @("smoke")
     projects = @{ "far-app" = @{ workspace = "$farDir"; commands = @{ hello = "' $([char]0x2713) tests/far.test.ts (1 test) 2ms'; 'hello from afar'; $png"; slow = "Start-Sleep 60" } } } } |
    ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $farConfig
  function New-FarJob($kind) {
    Invoke-RestMethod -Method Post -Headers $basic -ContentType "application/json" "$base/api/v1/jobs" `
      -Body (@{ project = "far-app"; kind = $kind; labels = @("smoke") } | ConvertTo-Json)
  }
  $far = New-FarJob "hello"
  pwsh -NoProfile -File $agentScript -Config $farConfig -Once -Wait 5 | Out-Null
  $deadline = (Get-Date).AddSeconds(15)
  do {
    $farJob = Get-Job $far.id
    # The job names its run as soon as the agent opens it; the store has it within a moment.
    $farRun = if ($farJob.runId) { try { Invoke-RestMethod -Headers $basic "$base/api/v1/runs/$($farJob.runId)" } catch { $null } }
    $settled = $farRun.run.attested -and $farRun.run.agentAttested -and $farRun.run.status -ne "running"
    if (-not $settled) { Start-Sleep -Milliseconds 500 }
  } until ($settled -or (Get-Date) -gt $deadline)
  $farLog = if ($farJob.runId) { Invoke-RestMethod -Headers $basic "$base/api/v1/runs/$($farJob.runId)/log" }
  Check "remote: a job run on another machine is sent to testor" ($farJob.status -eq "passed" -and $farRun.run.remote -eq "far-agent" -and $farRun.run.status -eq "passed") "($($farRun.run | ConvertTo-Json -Compress))"
  $agentEnvelope = Invoke-RestMethod -Headers $basic "$base/api/v1/runs/$($farJob.runId)/attestation?by=agent"
  $agents = @((Invoke-RestMethod -Headers $basic "$base/api/v1/agents").data)
  Check "remote: the agent signed its run, and testor checked it against what it received" ($farRun.run.agentAttested -and $agentEnvelope.payloadType -eq "application/vnd.in-toto+json" -and @($agents.agent) -contains "far-agent") "($($farRun.run.agentAttested); $(@($agents.agent) -join ','))"
  Check "remote: its log, specs and screenshot arrive, and it is signed" ("$farLog" -match "hello from afar" -and $farRun.run.summary.specs -eq 1 -and @($farRun.screenshots).Count -eq 1 -and $farRun.run.attested) "($($farRun | ConvertTo-Json -Depth 4 -Compress))"
  Check "remote: the agent keeps no copy once sent" (@(Get-ChildItem -LiteralPath (Join-Path $farHome "runs") -Filter "*.json" -ErrorAction SilentlyContinue).Count -eq 0)

  $farSlow = New-FarJob "slow"
  $farAgent = Start-Process pwsh -PassThru @hidden -ArgumentList "-NoProfile", "-File", $agentScript, "-Config", $farConfig, "-Once", "-Wait", "5"
  $deadline = (Get-Date).AddSeconds(30)
  do { Start-Sleep -Milliseconds 500; $farRunning = @((Invoke-RestMethod -Headers $basic "$base/api/v1/runs?status=running").data | Where-Object job -eq $farSlow.id) } until ($farRunning.Count -or (Get-Date) -gt $deadline)
  $null = Invoke-RestMethod -Method Post -Headers $basic -ContentType "application/json" "$base/api/v1/jobs/$($farSlow.id)/cancel" -Body "{}"
  $farEnded = $farAgent.WaitForExit(60000)
  $farCancelled = Get-Job $farSlow.id
  $deadline = (Get-Date).AddSeconds(10)
  do {
    $farCancelledRun = if ($farCancelled.runId) { try { (Invoke-RestMethod -Headers $basic "$base/api/v1/runs/$($farCancelled.runId)").run } catch { $null } }
    if ($farCancelledRun.status -ne "cancelled") { Start-Sleep -Milliseconds 300 }
  } until ($farCancelledRun.status -eq "cancelled" -or (Get-Date) -gt $deadline)
  Check "remote: cancelling reaches the other machine" ($farRunning.Count -eq 1 -and $farEnded -and $farCancelled.status -eq "cancelled" -and $farCancelledRun.status -eq "cancelled") "($($farCancelled | ConvertTo-Json -Compress); run $($farCancelledRun.status))"
  Remove-Item Env:TESTOR_AGENT_TOKEN
} finally {
  Set-Location $repo
  foreach ($name in $sandboxed) { [Environment]::SetEnvironmentVariable($name, $savedEnv[$name]) }
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
