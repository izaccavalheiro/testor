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
#     "projects": {
#       "my-app": { "workspace": "~/test-run/my-app", "git": false,
#                   "commands": { "test": "npm test", "lint": "npm run lint" } } } }
#
# A job names only a project and a task (kind): the command is the one this file gives, and a
# job for anything else is refused. That is the boundary: testor, or anyone with the execute
# scope, can only choose among the commands the owner of this machine wrote here. With
# "git": true, a job's ref (branch, tag or commit) is checked out in the workspace first
# (git fetch, then a detached checkout).
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

function Call([string]$path, $body) {
  $request = @{
    Method = "Post"; Uri = "$base/api/v1$path"; ContentType = "application/json"
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
  $workspace = Expand $project.workspace
  if (-not $workspace -or -not (Test-Path -LiteralPath $workspace)) { return @{ error = "workspace of $($job.project) not found: $workspace" } }
  if ($job.ref -and $project.git -ne $true) { return @{ error = "this agent does not check out refs for $($job.project) (git: true)" } }
  @{ command = $command; workspace = $workspace; git = $project.git -eq $true }
}

function Invoke-Job($job) {
  $plan = Resolve-Job $job
  if ($plan.error) {
    Log "$($job.id) refused: $($plan.error)"
    $null = Call "/agent/jobs/$($job.id)/finish" @{ error = $plan.error }
    return
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
  while (-not $process.WaitForExit(10000)) {
    try {
      $beat = Call "/agent/jobs/$($job.id)/heartbeat" @{}
      if ($beat.cancel -and -not $cancelledAt) { $cancelledAt = Get-Date; Log "$($job.id) cancel asked" }
    } catch {
      # The lease is gone (expired, or the job ended): another agent may run it now.
      Log "$($job.id) lost its lease ($($_.Exception.Message)); stopping the run"
      $cancelledAt = (Get-Date).AddSeconds(-60)
    }
    # testor cancels the run itself (cancel\<run id>); if it is still there 10 s later, end it here.
    if ($cancelledAt -and ((Get-Date) - $cancelledAt).TotalSeconds -ge 10) {
      try { $process.Kill($true) } catch { }
    }
  }
  $process.WaitForExit()
  Remove-Item "$out.out", "$out.err" -ErrorAction SilentlyContinue
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
