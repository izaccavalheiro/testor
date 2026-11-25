#Requires -Version 7
# testor's agent: takes jobs from a testor (POST /api/v1/jobs queued them) and runs them on
# this machine through run.ps1, so they are recorded like any other run. Windows, Linux, macOS.
#
#   pwsh agent.ps1 -Config agent.json          # takes jobs until stopped
#   pwsh agent.ps1 -Config agent.json -Once    # waits for one job, runs it, exits
#
# agent.json:
#
#   { "server": "http://127.0.0.1:6767",
#     "tokenFile": "agent.token",              # or $env:TESTOR_AGENT_TOKEN: a Bearer token of a
#                                              # user with the agent role (task testor:token)
#     "labels": ["windows", "gpu"],            # jobs that ask for labels need all of them
#     "home": "~/test-run/.testor",            # the testor home holding run.ps1 (this default)
#     "upload": false,                         # true on another machine than testor's: see below
#     "projects": {
#       "my-app": { "workspace": "~/test-run/my-app", "git": false,
#                   "commands": { "test": "npm test", "lint": "npm run lint" } },
#       "my-lib": { "repository": "https://github.com/me/my-lib.git",   # cloned when missing
#                   "commands": { "test": "cargo test" } } } }
#
# A job names only a project and a task (kind): the command is the one this file gives, and a
# job for anything else is refused. That is the boundary: testor, or anyone with the execute
# scope, can only choose among the commands the owner of this machine wrote here. With
# "git": true, a job's ref (branch, tag or commit) is checked out in the workspace first
# (git fetch, then a detached checkout).
#
# On another machine than testor's, set "upload": true and give the agent a home of its own (a
# folder with run.ps1 in it): run.ps1 records the run there, and the agent sends it to testor
# as it happens (the record, the log in chunks, then screenshots, artifacts and the final
# record), then deletes its copy. testor treats it like a run of its own.
#
# While a job runs the agent renews its lease every 10 s; testor asks it to cancel through the
# heartbeat's answer. It runs as the account that starts it: give it the test account
# (docs/security.md, "Running tests in a separate account").
param(
  [string]$Config = (Join-Path $PSScriptRoot "agent.json"),
  [switch]$Once,
  [int]$Wait = 20
)
$ErrorActionPreference = "Stop"

function Log([string]$message) { "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] agent: $message" }
function Expand([string]$path) { if ($path -like "~*") { Join-Path $HOME $path.Substring(1).TrimStart("/", "\") } else { $path } }

$settings = Get-Content -Raw -LiteralPath $Config | ConvertFrom-Json -AsHashtable
$base = "$($settings.server)".TrimEnd("/")
$token = if ($env:TESTOR_AGENT_TOKEN) { $env:TESTOR_AGENT_TOKEN }
         elseif ($settings.tokenFile) { (Get-Content -Raw -LiteralPath ([IO.Path]::Combine((Split-Path -Parent (Resolve-Path $Config)), (Expand $settings.tokenFile)))).Trim() }
         else { throw "no token: set TESTOR_AGENT_TOKEN or tokenFile in $Config" }
$home_ = if ($settings.home) { Expand $settings.home } else { Join-Path (Join-Path $HOME "test-run") ".testor" }
$runPs1 = Join-Path $home_ "run.ps1"
if (-not (Test-Path -LiteralPath $runPs1)) { throw "no run.ps1 in $home_ (set home in $Config)" }
$labels = @($settings.labels | Where-Object { $_ })
$projects = if ($settings.projects) { $settings.projects } else { @{} }
$skipCert = $settings.skipCertificateCheck -eq $true
$upload = $settings.upload -eq $true

# --- a run on this machine, sent to testor ("upload": true) ----------------------------------
# run.ps1 writes the run into this agent's home; what it writes is sent as it changes: the
# record, the log in chunks at offsets, then the screenshots, artifacts and final record.

function Send-Log($job, $state) {
  $path = Join-Path (Join-Path $home_ "logs") "$($state.runId).log"
  if (-not (Test-Path -LiteralPath $path)) { return }
  # run.ps1 is still writing it: read without locking it.
  $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
  try {
    while ($stream.Length -gt $state.sent) {
      $buffer = [byte[]]::new([math]::Min(1MB, $stream.Length - $state.sent))
      $stream.Position = $state.sent
      $read = $stream.Read($buffer, 0, $buffer.Length)
      if ($read -le 0) { break }
      if ($read -lt $buffer.Length) { [Array]::Resize([ref]$buffer, $read) }
      $answer = Invoke-WebRequest -Method Post -Uri "$base/api/v1/agent/jobs/$($job.id)/log?offset=$($state.sent)" `
        -Headers @{ Authorization = "Bearer $token" } -ContentType "application/octet-stream" -Body $buffer `
        -SkipHttpErrorCheck -SkipCertificateCheck:$skipCert -TimeoutSec 60
      if ($answer.StatusCode -eq 200) { $state.sent += $read }
      # testor has a different length (a chunk sent twice, or lost): go on from there.
      elseif ($answer.StatusCode -eq 409 -and $answer.Headers["X-Log-Size"]) { $state.sent = [long]"$($answer.Headers['X-Log-Size'])" }
      else { throw "the log was refused ($($answer.StatusCode))" }
    }
  } finally { $stream.Dispose() }
}

function Sync-Run($job, $state) {
  $runs = Join-Path $home_ "runs"
  if (-not $state.runId) {
    foreach ($file in @(Get-ChildItem -LiteralPath $runs -Filter "*.json" -ErrorAction SilentlyContinue)) {
      $record = try { Get-Content -Raw -LiteralPath $file.FullName | ConvertFrom-Json } catch { $null }
      if ($record.job -eq $job.id) { $state.runId = $record.id; break }
    }
    if (-not $state.runId) { return }
  }
  $text = try { Get-Content -Raw -LiteralPath (Join-Path $runs "$($state.runId).json") } catch { $null }
  if ($text -and $text -ne $state.record) {
    $record = $text | ConvertFrom-Json -AsHashtable
    # The final record goes last, after the log and the files. A run that ended before it was
    # first sent (a quick one) is opened with its record as it was while it ran.
    if ($record.status -ne "running" -and -not $state.record) {
      $opening = $record.Clone()
      $opening.status = "running"
      foreach ($key in "endedAt", "durationMs", "exitCode", "error") { $opening.Remove($key) }
      $null = Call "/agent/jobs/$($job.id)/run" $opening "Put"
      $state.record = "(opened)"
    }
    if ($record.status -eq "running") { $null = Call "/agent/jobs/$($job.id)/run" $record "Put"; $state.record = $text }
  }
  Send-Log $job $state
}

function Complete-Run($job, $state, [bool]$cancelled) {
  Sync-Run $job $state
  if (-not $state.runId) { return }
  $runFile = Join-Path (Join-Path $home_ "runs") "$($state.runId).json"
  $record = Get-Content -Raw -LiteralPath $runFile | ConvertFrom-Json -AsHashtable
  if ($record.status -eq "running") {
    # Its PowerShell was ended (a cancel, or killed) before it could write its end.
    $record.status = if ($cancelled) { "cancelled" } else { "aborted" }
    $record.endedAt = (Get-Date).ToUniversalTime().ToString("o")
  }
  Send-Log $job $state
  foreach ($area in "screenshots", "artifacts") {
    $dir = Join-Path (Join-Path $home_ $area) $state.runId
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    foreach ($file in @(Get-ChildItem -LiteralPath $dir -Recurse -File -Force | Where-Object { -not $_.LinkType })) {
      $rel = ([IO.Path]::GetRelativePath($dir, $file.FullName) -replace "\\", "/") -split "/" | ForEach-Object { [Uri]::EscapeDataString($_) }
      try {
        $null = Invoke-RestMethod -Method Put -Uri "$base/api/v1/agent/jobs/$($job.id)/files/$area/$($rel -join '/')" `
          -Headers @{ Authorization = "Bearer $token" } -ContentType "application/octet-stream" -InFile $file.FullName `
          -SkipCertificateCheck:$skipCert -TimeoutSec 300
      } catch { Log "$($job.id) $area/$($rel -join '/') not sent: $($_.Exception.Message)" }
    }
  }
  $null = Call "/agent/jobs/$($job.id)/run" $record "Put"
  # testor has it all: the copy here is not needed any more.
  Remove-Item -LiteralPath $runFile, (Join-Path (Join-Path $home_ "logs") "$($state.runId).log") -ErrorAction SilentlyContinue
  foreach ($area in "screenshots", "artifacts", "cancel") {
    Remove-Item -LiteralPath (Join-Path (Join-Path $home_ $area) $state.runId) -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Call([string]$path, $body, [string]$method = "Post") {
  $request = @{
    Method = $method; Uri = "$base/api/v1$path"; ContentType = "application/json"
    Headers = @{ Authorization = "Bearer $token" }; Body = ($body | ConvertTo-Json -Depth 5 -Compress)
    TimeoutSec = $Wait + 15; SkipCertificateCheck = $skipCert
  }
  Invoke-RestMethod @request
}

# The command this machine allows for a job, or why there is none.
function Resolve-Job($job) {
  $project = $projects[$job.project]
  if (-not $project) { return @{ error = "project $($job.project) is not in this agent's configuration" } }
  $command = if ($project.commands) { $project.commands[$job.kind] } else { $null }
  if (-not $command) { return @{ error = "task $($job.kind) of $($job.project) is not in this agent's configuration" } }
  # With a repository, the workspace (by default <home>/workspaces/<project>) is cloned when
  # missing, and refs can be checked out.
  $repository = $project.repository
  $workspace = if ($project.workspace) { Expand $project.workspace } elseif ($repository) { Join-Path (Join-Path $home_ "workspaces") $job.project } else { $null }
  $git = $project.git -eq $true -or [bool]$repository
  $clone = $repository -and $workspace -and -not (Test-Path -LiteralPath $workspace)
  if (-not $workspace -or (-not $clone -and -not (Test-Path -LiteralPath $workspace))) { return @{ error = "workspace of $($job.project) not found: $workspace" } }
  if ($job.ref -and -not $git) { return @{ error = "this agent does not check out refs for $($job.project) (git: true)" } }
  @{ command = $command; workspace = $workspace; git = $git; clone = if ($clone) { $repository } else { $null } }
}

function Invoke-Job($job) {
  $plan = Resolve-Job $job
  if ($plan.error) {
    Log "$($job.id) refused: $($plan.error)"
    $null = Call "/agent/jobs/$($job.id)/finish" @{ error = $plan.error }
    return
  }
  if ($plan.clone) {
    $null = New-Item -ItemType Directory -Force (Split-Path -Parent $plan.workspace)
    git clone --quiet -- $plan.clone $plan.workspace
    if ($LASTEXITCODE) {
      $null = Call "/agent/jobs/$($job.id)/finish" @{ error = "git clone of $($job.project) failed" }
      return
    }
  }
  if ($job.ref) {
    # The ref matched testor's pattern (no leading dash); -- ends git's options anyway.
    git -C $plan.workspace fetch --quiet --all --tags
    git -C $plan.workspace checkout --quiet --detach $job.ref --
    if ($LASTEXITCODE) {
      $null = Call "/agent/jobs/$($job.id)/finish" @{ error = "git checkout $($job.ref) failed" }
      return
    }
  }

  $quote = { param($text) "'" + ($text -replace "'", "''") + "'" }
  $script = "Set-Location -LiteralPath $(& $quote $plan.workspace); & $(& $quote $runPs1) -Project $(& $quote $job.project) -Kind $(& $quote $job.kind) -Body { $($plan.command) }"
  $out = Join-Path ([IO.Path]::GetTempPath()) "testor-agent-$($job.id)"
  $env:TESTOR_JOB_ID = $job.id
  $env:TESTOR_ACTOR = "agent:$([Environment]::MachineName.ToLower()) for $($job.requestedBy)"
  try {
    $process = Start-Process pwsh -PassThru -NoNewWindow -RedirectStandardOutput "$out.out" -RedirectStandardError "$out.err" `
      -ArgumentList "-NoProfile", "-NonInteractive", "-Command", $script
    # Windows keeps the exit code only for a process whose handle was opened while it ran.
    $null = $process.Handle
  } finally {
    Remove-Item Env:TESTOR_JOB_ID, Env:TESTOR_ACTOR -ErrorAction SilentlyContinue
  }
  Log "$($job.id) running $($job.project) $($job.kind) (pid $($process.Id))"

  $cancelledAt = $null
  $lost = $false
  $state = @{ runId = $null; sent = [long]0; record = $null }
  $beatAt = Get-Date
  # Uploading, the run is sent every second; the lease is renewed every 10 s either way.
  while (-not $process.WaitForExit($(if ($upload) { 1000 } else { 10000 }))) {
    if ($upload) {
      try { Sync-Run $job $state } catch { Log "$($job.id) could not send the run yet: $($_.Exception.Message)" }
    }
    if (-not $upload -or ((Get-Date) - $beatAt).TotalSeconds -ge 10) {
      $beatAt = Get-Date
      try {
        $beat = Call "/agent/jobs/$($job.id)/heartbeat" @{}
        if ($beat.cancel -and -not $cancelledAt) {
          $cancelledAt = Get-Date
          Log "$($job.id) cancel asked"
          # On this machine run.ps1 ends its own tree when asked (cancel\<run id>).
          if ($upload -and $state.runId) {
            $null = New-Item -ItemType Directory -Force (Join-Path $home_ "cancel")
            Set-Content -LiteralPath (Join-Path (Join-Path $home_ "cancel") $state.runId) -Value ""
          }
        }
      } catch {
        # The lease is gone (expired, or the job ended): another agent may run it now.
        Log "$($job.id) lost its lease ($($_.Exception.Message)); stopping the run"
        $cancelledAt = (Get-Date).AddSeconds(-60)
        $lost = $true
      }
    }
    # testor cancels the run itself (cancel\<run id>); if it is still there 10 s later, end it here.
    if ($cancelledAt -and ((Get-Date) - $cancelledAt).TotalSeconds -ge 10) {
      try { $process.Kill($true) } catch { }
    }
  }
  $process.WaitForExit()
  Remove-Item "$out.out", "$out.err" -ErrorAction SilentlyContinue
  if ($upload -and -not $lost) {
    try { Complete-Run $job $state ($null -ne $cancelledAt) } catch { Log "$($job.id) could not send the run: $($_.Exception.Message)" }
  }
  try {
    $done = Call "/agent/jobs/$($job.id)/finish" @{ exitCode = $process.ExitCode }
    Log "$($job.id) $($done.status) (exit $($process.ExitCode))"
  } catch { Log "$($job.id) ended (exit $($process.ExitCode)) but could not report it: $($_.Exception.Message)" }
}

Log "taking jobs from $base (labels: $($labels -join ', '); projects: $(@($projects.Keys) -join ', '))"
do {
  try {
    $job = Call "/agent/lease" @{ labels = $labels; wait = $Wait }
    if ($job) { Invoke-Job $job }
  } catch {
    Log "testor did not answer: $($_.Exception.Message)"
    if ($Once) { exit 1 }
    Start-Sleep -Seconds 5
  }
} until ($Once)
