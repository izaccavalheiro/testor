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
  $config = if (Test-Path $configFile) { Get-Content -Raw $configFile | ConvertFrom-Json -AsHashtable } else { @{} }
  $config.execution = @{ enabled = $true; leaseSeconds = 30; maxAttempts = 3 }
  $config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configFile
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

  $slowJob = New-Job "slow"
  $slowAgent = Start-Process pwsh -PassThru @hidden -ArgumentList "-NoProfile", "-File", $agentScript, "-Config", $agentConfig, "-Once", "-Wait", "5"
  $deadline = (Get-Date).AddSeconds(30)
  do { Start-Sleep -Milliseconds 500; $slowRun = @((Invoke-RestMethod -Headers $basic "$base/api/v1/runs?status=running").data | Where-Object job -eq $slowJob.id) } until ($slowRun.Count -or (Get-Date) -gt $deadline)
  $null = Invoke-RestMethod -Method Post -Headers $basic -ContentType "application/json" "$base/api/v1/jobs/$($slowJob.id)/cancel" -Body "{}"
  $agentEnded = $slowAgent.WaitForExit(40000)
  $cancelled = Get-Job $slowJob.id
  Check "jobs: cancelling a running job ends its run and the job" ($slowRun.Count -eq 1 -and $agentEnded -and $cancelled.status -eq "cancelled") "($($cancelled | ConvertTo-Json -Compress))"
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
