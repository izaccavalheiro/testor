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
#                   "commands": { "test": "cargo test" },
#                   "secrets": { "NPM_TOKEN": "vault:secret/data/ci/my-lib#npm" } } },
#     "vault": { "address": "https://vault.example.com:8200", "kubernetesRole": "testor-agent" } }
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
# A command is a string, or an object that also names what the run hands over (paths relative
# to the workspace) and what it keeps between jobs:
#   "mutation": { "command": "npx stryker run", "reports": ["reports/mutation/mutation.json"],
#                 "artifacts": ["reports/mutation"], "preserve": ["reports/stryker-incremental.json"] }
# "reports" are files testor reads (docs/mutation.md); "timeout" ("45m") ends a run that takes
# longer (a job may ask for less, never more); "memoryGuard": { "warn": 80, "stop": 92 } warns,
# then ends it, before the kernel's OOM killer takes the agent (docs/heavy-jobs.md);
# "exclusive": true marks a job nothing else may share an agent with. "preserve" paths survive an isolated
# workspace (copied from <home>/cache/<project> before the run and back after it); a job with
# "clean": true drops them first. "state" paths (also a project's) are kept by testor per project and
# branch (docs/snapshots.md): restored before the run, from the branch or else the default branch,
# and sent back after it, so Stryker's incremental file follows a branch from agent to agent.
#
# Snapshots: a project with "snapshots": true takes jobs that name a snapshot (runner/snapshot.ps1)
# instead of a ref. Its files are written into the workspace (by default
# <home>/workspaces/<project>) from a cache of contents by hash (<home>/cas), fetching only what
# the cache lacks; files the previous snapshot wrote and this one lacks are deleted, and the rest
# (dependencies, build caches) stays. Anyone with the execute scope can send a snapshot, so its
# code runs with this machine's commands: opt in only where that is meant.
#
# Every run gets TESTOR_CPUS and TESTOR_MEMORY_MB (the container's quota and limit on Linux);
# a project with "limits": "auto" also gets GOMAXPROCS, CARGO_BUILD_JOBS, DOTNET_PROCESSOR_COUNT,
# PYTEST_XDIST_AUTO_NUM_WORKERS and NODE_OPTIONS=--max-old-space-size, unless already set. A
# project with "executor": { "container": { "image": "name@sha256:...", "network": "none" } }
# runs each command in that container (Docker, or tools.container: podman): read-only root, the
# workspace mounted, no network unless "bridge", the limits as hard ones.
#
# Isolation: with a project's "isolate": "worktree" (a git workspace) each job runs in a git
# worktree of its own, at the job's ref (or the workspace's HEAD: committed files only); with
# "copy", in a copy of the workspace. Either is under <home>/isolated and removed when the run
# ends, so nothing a job writes (build output, caches, a planted file) is there for the next.
#
# Secrets: a project's "secrets" maps environment variables its commands get to where their
# values are, resolved on this machine for each job (testor never sees them) and written as
# *** in the run's log (run.ps1, TESTOR_MASK):
#
#   env:NAME              a variable of the agent's own environment (a Kubernetes secret, CI)
#   file:PATH             a file's contents (/run/secrets, a mounted secret, systemd credentials)
#   vault:PATH#FIELD      HashiCorp Vault or OpenBao (KV v1 or v2), with VAULT_TOKEN, "vault"'s
#                         tokenFile, its kubernetesRole (the pod's service account token), or
#                         its jwtRole (the job's identity token from testor, below)
#   aws:ID[#FIELD]        AWS Secrets Manager, through the aws CLI and its credentials
#   gcp:SECRET            Google Secret Manager (a name, or projects/P/secrets/S[/versions/V])
#   azure:VAULT/NAME      Azure Key Vault, through the az CLI
#   sops:FILE[#KEY]       a SOPS-encrypted file (age, PGP or a cloud KMS)
#
# The CLIs pick up the machine's workload identity (IAM roles for service accounts, GKE or Azure
# workload identity, an instance profile); "secretTools" gives their paths when not on PATH. A
# secret that cannot be read fails the job before it runs, naming the secret, never its value.
#
# Identity: with a project's "identity": {"audience": "sts.amazonaws.com", "file":
# "AWS_WEB_IDENTITY_TOKEN_FILE", "env": {"AWS_ROLE_ARN": "arn:aws:iam::1:role/ci"}}, the agent
# asks testor for the job's identity token (jobTokens in testor's auth.json), writes it to a file
# the run finds in that variable (TESTOR_ID_TOKEN_FILE by default; the token is also in
# TESTOR_ID_TOKEN, masked), keeps it fresh while the run lasts, and sets "env". Cloud SDKs trade it
# for short-lived credentials; its sub is project:<project>:kind:<kind>.
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
$tools = if ($settings.secretTools) { $settings.secretTools } else { @{} }
$upload = $settings.upload -eq $true

# The agent's own key (ECDSA P-256), made on its first start: testor pins its public half to
# this agent at the first lease, and checks the attestation of each run sent with it.
$keyFile = Join-Path $home_ "agent.key"
$ecdsa = [Security.Cryptography.ECDsa]::Create([Security.Cryptography.ECCurve+NamedCurves]::nistP256)
if (Test-Path -LiteralPath $keyFile) {
  $ecdsa.ImportFromPem((Get-Content -Raw -LiteralPath $keyFile))
} else {
  [IO.File]::WriteAllText($keyFile, $ecdsa.ExportPkcs8PrivateKeyPem())
  if (-not $IsWindows) { [IO.File]::SetUnixFileMode($keyFile, [IO.UnixFileMode]"UserRead, UserWrite") }
}
$publicKey = $ecdsa.ExportSubjectPublicKeyInfoPem()
$keyId = ([Security.Cryptography.SHA256]::HashData($ecdsa.ExportSubjectPublicKeyInfo()) | ForEach-Object { $_.ToString("x2") }) -join ""

# The in-toto statement of a run sent to testor, in a DSSE envelope signed with the agent's
# key: the log and the files sent, each with its SHA-256, and the run's record.
function New-Attestation($job, $state, $record, $files) {
  $logFile = Join-Path (Join-Path $home_ "logs") "$($state.runId).log"
  $subjects = @()
  if (Test-Path -LiteralPath $logFile) { $subjects += [ordered]@{ name = "log"; digest = @{ sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $logFile).Hash.ToLower() } } }
  foreach ($file in $files) { $subjects += [ordered]@{ name = $file.name; digest = @{ sha256 = $file.sha256 } } }
  $run = [ordered]@{ id = $state.runId; job = $job.id }
  foreach ($key in "project", "kind", "command", "status", "exitCode", "startedAt", "endedAt", "durationMs") { $run[$key] = $record[$key] }
  $statement = [ordered]@{
    _type = "https://in-toto.io/Statement/v1"
    subject = $subjects
    predicateType = "https://github.com/izaccavalheiro/testor/blob/main/docs/attestation.md#agent-run-v1"
    predicate = [ordered]@{ run = $run; host = [Environment]::MachineName.ToLower(); signedAt = (Get-Date).ToUniversalTime().ToString("o") }
  }
  $type = "application/vnd.in-toto+json"
  $payload = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $statement -Depth 8 -Compress))
  # DSSE's pre-authentication encoding of the payload, as testor checks it.
  $pae = [byte[]]([Text.Encoding]::UTF8.GetBytes("DSSEv1 $($type.Length) $type $($payload.Length) ") + $payload)
  $signature = $ecdsa.SignData($pae, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.DSASignatureFormat]::Rfc3279DerSequence)
  @{ payloadType = $type; payload = [Convert]::ToBase64String($payload); signatures = @(@{ keyid = $keyId; sig = [Convert]::ToBase64String($signature) }) }
}

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
  $sent = @()
  foreach ($area in "screenshots", "artifacts", "reports") {
    $dir = Join-Path (Join-Path $home_ $area) $state.runId
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    foreach ($file in @(Get-ChildItem -LiteralPath $dir -Recurse -File -Force | Where-Object { -not $_.LinkType })) {
      $rel = ([IO.Path]::GetRelativePath($dir, $file.FullName) -replace "\\", "/") -split "/" | ForEach-Object { [Uri]::EscapeDataString($_) }
      try {
        $null = Invoke-RestMethod -Method Put -Uri "$base/api/v1/agent/jobs/$($job.id)/files/$area/$($rel -join '/')" `
          -Headers @{ Authorization = "Bearer $token" } -ContentType "application/octet-stream" -InFile $file.FullName `
          -SkipCertificateCheck:$skipCert -TimeoutSec 300
        $plain = ([IO.Path]::GetRelativePath($dir, $file.FullName) -replace "\\", "/")
        $sent += @{ name = "$area/$plain"; sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLower() }
      } catch { Log "$($job.id) $area/$($rel -join '/') not sent: $($_.Exception.Message)" }
    }
  }
  # Signed by this agent, before the final record: testor checks it against what it received.
  try { $null = Call "/agent/jobs/$($job.id)/attestation" (New-Attestation $job $state $record $sent) "Put" }
  catch { Log "$($job.id) attestation refused: $($_.Exception.Message)" }
  $null = Call "/agent/jobs/$($job.id)/run" $record "Put"
  # testor has it all: the copy here is not needed any more.
  Remove-Item -LiteralPath $runFile, (Join-Path (Join-Path $home_ "logs") "$($state.runId).log") -ErrorAction SilentlyContinue
  foreach ($area in "screenshots", "artifacts", "reports", "cancel") {
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
  $entry = if ($project.commands) { $project.commands[$job.kind] } else { $null }
  $command = if ($entry -is [Collections.IDictionary]) { $entry.command } else { $entry }
  if (-not $command -or $command -isnot [string]) { return @{ error = "task $($job.kind) of $($job.project) is not in this agent's configuration" } }
  $lists = @{}
  foreach ($key in "reports", "artifacts", "preserve", "state") {
    $lists[$key] = @(if ($entry -is [Collections.IDictionary] -and $entry[$key]) { $entry[$key] } elseif ($key -eq "state" -and $project.state) { $project.state } else { @() })
    foreach ($path in $lists[$key]) {
      if ($path -isnot [string] -or [IO.Path]::IsPathRooted($path) -or ($path -split "[\\/]") -contains "..") {
        return @{ error = "$key of $($job.project) $($job.kind) are paths inside the workspace" }
      }
    }
  }
  foreach ($path in $lists.state) {
    if ((State-Name $path) -notmatch "^[A-Za-z0-9_.-]{1,100}$") { return @{ error = "state of $($job.project) $($job.kind): $path makes no state name (letters, digits, _ . - and /)" } }
  }
  # With a repository, the workspace (by default <home>/workspaces/<project>) is cloned when
  # missing, and refs can be checked out. A snapshot is written into it, made when missing.
  $snapshot = [bool]$job.snapshot
  if ($snapshot -and $project.snapshots -ne $true) { return @{ error = "this agent takes no snapshots of $($job.project) (snapshots: true)" } }
  $repository = $project.repository
  $workspace = if ($project.workspace) { Expand $project.workspace } elseif ($repository -or $snapshot) { Join-Path (Join-Path $home_ "workspaces") $job.project } else { $null }
  $git = ($project.git -eq $true -or [bool]$repository) -and -not $snapshot
  $clone = $repository -and $workspace -and -not $snapshot -and -not (Test-Path -LiteralPath $workspace)
  if (-not $workspace -or (-not $clone -and -not $snapshot -and -not (Test-Path -LiteralPath $workspace))) { return @{ error = "workspace of $($job.project) not found: $workspace" } }
  if ($job.ref -and -not $git) { return @{ error = "this agent does not check out refs for $($job.project) (git: true)" } }
  $isolate = $project.isolate
  if ($isolate -notin @($null, $false, "worktree", "copy")) { return @{ error = "isolate of $($job.project) is worktree, copy or false" } }
  if ($isolate -eq "worktree" -and -not $git) { return @{ error = "isolate: worktree needs a git workspace for $($job.project) (git: true, and a ref, not a snapshot)" } }
  # Limits, all from this file: the command's timeout (a job may ask for a shorter one), its
  # memory guard, and the project's container executor.
  $timeout = if ($entry -is [Collections.IDictionary]) { Get-Seconds $entry.timeout } else { 0 }
  if ($null -eq $timeout) { return @{ error = "timeout of $($job.project) $($job.kind) is seconds or 90s, 45m, 2h" } }
  $asked = Get-Seconds $job.timeout
  if ($asked -gt 0 -and ($timeout -eq 0 -or $asked -lt $timeout)) { $timeout = $asked }
  $guard = if ($entry -is [Collections.IDictionary] -and $entry.memoryGuard) { $entry.memoryGuard } else { $project.memoryGuard }
  if ($guard -and -not ($guard.warn -is [int] -and $guard.stop -is [int] -and 0 -lt $guard.warn -and $guard.warn -le $guard.stop -and $guard.stop -le 100)) {
    return @{ error = "memoryGuard of $($job.project) is { warn, stop }: percentages, warn <= stop" }
  }
  $container = $null
  if ($project.executor) {
    $container = $project.executor.container
    if (-not $container -or "$($container.image)" -notmatch "^[\w./:-]+@sha256:[0-9a-f]{64}$") { return @{ error = "executor of $($job.project): container.image is pinned by digest (name@sha256:...)" } }
    if ($container.network -notin @($null, "none", "bridge")) { return @{ error = "executor of $($job.project): container.network is none or bridge" } }
  }
  @{ command = $command; workspace = $workspace; git = $git; clone = if ($clone) { $repository } else { $null }; isolate = $isolate
     reports = $lists.reports; artifacts = $lists.artifacts; preserve = $lists.preserve; state = $lists.state
     timeout = $timeout; guard = if ($guard) { "$($guard.warn),$($guard.stop)" } else { "" }; limits = $project.limits -eq "auto"
     container = $container; exclusive = ($entry -is [Collections.IDictionary] -and $entry.exclusive -eq $true) }
}

# --- snapshots and state --------------------------------------------------------------------

# The name testor keeps a state path under: reports/stryker-incremental.json is
# reports--stryker-incremental.json.
function State-Name([string]$path) { "$path" -replace "[\\/]", "--" }

# Writes snapshot $job.snapshot into $workspace: contents from the cache by hash, fetched when
# missing (eight at a time, each checked against its hash); a file left as the last snapshot
# wrote it is not touched. What it did: @{ files; fetched; written; deleted }.
function Sync-Snapshot($job, [string]$workspace) {
  $auth = @{ Authorization = "Bearer $token" }
  $manifest = Invoke-RestMethod -Uri "$base/api/v1/agent/projects/$($job.project)/snapshots/$($job.snapshot)" -Headers $auth `
    -SkipCertificateCheck:$skipCert -TimeoutSec 120
  $cache = Join-Path (Join-Path $home_ "cas") "sha256"
  $null = New-Item -ItemType Directory -Force $cache, $workspace
  $sep = [IO.Path]::DirectorySeparatorChar
  $root = [IO.Path]::GetFullPath($workspace).TrimEnd($sep) + $sep
  # What the last snapshot wrote here (kept beside the cache: the tree may hold any name).
  $written = Join-Path (Join-Path $home_ "cas") "$($job.project).written.json"
  $before = @{}
  if (Test-Path -LiteralPath $written) { try { $before = Get-Content -Raw -LiteralPath $written | ConvertFrom-Json -AsHashtable } catch { } }
  $files = @($manifest.files)
  $missing = @($files | ForEach-Object { $_.sha256 } | Sort-Object -Unique | Where-Object { -not (Test-Path -LiteralPath (Join-Path $cache $_)) })
  $missing | ForEach-Object -ThrottleLimit 8 -Parallel {
    $hex = $_
    $file = Join-Path $using:cache $hex
    $part = "$file.$([guid]::NewGuid().ToString('N')).part"
    # A redirect to the bucket drops the Authorization header (PowerShell's default).
    Invoke-WebRequest -Uri "$($using:base)/api/v1/agent/blobs/sha256:$hex" -Headers $using:auth -OutFile $part `
      -SkipCertificateCheck:$using:skipCert -TimeoutSec 600
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $part).Hash.ToLower() -ne $hex) {
      Remove-Item -LiteralPath $part -Force
      throw "content $hex does not match its hash"
    }
    Move-Item -Force -LiteralPath $part -Destination $file
  }
  $after = @{}
  $folders = [Collections.Generic.HashSet[string]]::new()
  $count = 0
  foreach ($file in $files) {
    $path = "$($file.path)"
    if ([IO.Path]::IsPathRooted($path) -or $path -match "[\\:]" -or ($path -split "/") -contains ".." -or ($path -split "/") -contains "") {
      throw "snapshot path $path is not inside the workspace"
    }
    $target = [IO.Path]::GetFullPath([IO.Path]::Combine($workspace, $path))
    if (-not $target.StartsWith($root)) { throw "snapshot path $path is not inside the workspace" }
    $item = Get-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
    $was = $before[$path]
    if ($item -and -not $item.LinkType -and -not $item.PSIsContainer -and $was -and $was.sha256 -eq $file.sha256 -and
        $was.size -eq $item.Length -and $was.ticks -eq $item.LastWriteTimeUtc.Ticks) {
      $after[$path] = $was
      continue
    }
    # The folders down to it are folders, never links a run left (which would send the file
    # elsewhere) nor files.
    $dir = $root
    foreach ($segment in @($path -split "/" | Select-Object -SkipLast 1)) {
      $dir = Join-Path $dir $segment
      if (-not $folders.Add($dir)) { continue }
      $there = Get-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
      if ($there -and ($there.LinkType -or -not $there.PSIsContainer)) { $there.Delete() }
      if (-not $there -or $there.LinkType -or -not $there.PSIsContainer) { $null = New-Item -ItemType Directory -Path $dir }
    }
    if ($item) { if ($item.PSIsContainer -and -not $item.LinkType) { Remove-Item -LiteralPath $target -Recurse -Force } else { $item.Delete() } }
    $source = Join-Path $cache $file.sha256
    # Copied, not linked: a run that writes into a file must not change the cache.
    Copy-Item -LiteralPath $source -Destination $target -Force
    (Get-Item -LiteralPath $source).LastWriteTimeUtc = [DateTime]::UtcNow
    if (-not $IsWindows) {
      [IO.File]::SetUnixFileMode($target, [IO.UnixFileMode]$(if ($file.mode -eq "755") { "UserRead, UserWrite, UserExecute, GroupRead, GroupExecute, OtherRead, OtherExecute" } else { "UserRead, UserWrite, GroupRead, OtherRead" }))
    }
    $item = Get-Item -LiteralPath $target -Force
    $after[$path] = @{ sha256 = $file.sha256; size = $item.Length; ticks = $item.LastWriteTimeUtc.Ticks }
    $count++
  }
  # Files the last snapshot wrote and this one lacks; what runs made (dependencies, caches) stays.
  $deleted = 0
  foreach ($path in @($before.Keys)) {
    if ($after.ContainsKey($path)) { continue }
    $gone = [IO.Path]::GetFullPath([IO.Path]::Combine($workspace, $path))
    if ($gone.StartsWith($root) -and (Test-Path -LiteralPath $gone -PathType Leaf)) { Remove-Item -LiteralPath $gone -Force; $deleted++ }
  }
  ConvertTo-Json -InputObject $after -Depth 3 -Compress | Set-Content -LiteralPath $written
  @{ files = $files.Count; fetched = $missing.Count; written = $count; deleted = $deleted }
}

# Contents of the cache not used for two weeks go when the agent starts.
function Clear-Cas {
  $cache = Join-Path (Join-Path $home_ "cas") "sha256"
  if (-not (Test-Path -LiteralPath $cache)) { return }
  $old = (Get-Date).ToUniversalTime().AddDays(-14)
  Get-ChildItem -LiteralPath $cache -File | Where-Object { $_.LastWriteTimeUtc -lt $old -or $_.Name -like "*.part" } |
    Remove-Item -Force -ErrorAction SilentlyContinue
}

# The command's state paths from testor, for the branch (else the default branch's).
function Restore-State($job, $plan, [string]$runDir, [string]$branch) {
  $query = if ($branch) { "?branch=$([Uri]::EscapeDataString($branch))" } else { "" }
  foreach ($path in $plan.state) {
    try {
      $answer = Invoke-WebRequest -Uri "$base/api/v1/agent/projects/$($job.project)/state/$(State-Name $path)$query" `
        -Headers @{ Authorization = "Bearer $token" } -SkipHttpErrorCheck -SkipCertificateCheck:$skipCert -TimeoutSec 120
      if ($answer.StatusCode -ne 200) { continue }
      $to = Join-Path $runDir $path
      $null = New-Item -ItemType Directory -Force (Split-Path -Parent $to)
      [IO.File]::WriteAllBytes($to, [byte[]]$answer.Content)
      Log "$($job.id) state $path restored (from $($answer.Headers['X-Testor-State-Branch']))"
    } catch { Log "$($job.id) state $path not restored: $($_.Exception.Message)" }
  }
}

# The command's state paths back to testor once the run has ended.
function Save-State($job, $plan, [string]$runDir, [string]$branch) {
  $query = "?job=$($job.id)" + $(if ($branch) { "&branch=$([Uri]::EscapeDataString($branch))" } else { "" })
  foreach ($path in $plan.state) {
    $from = Join-Path $runDir $path
    if (-not (Test-Path -LiteralPath $from -PathType Leaf)) { continue }
    try {
      $null = Invoke-RestMethod -Method Put -Uri "$base/api/v1/agent/projects/$($job.project)/state/$(State-Name $path)$query" `
        -Headers @{ Authorization = "Bearer $token" } -ContentType "application/octet-stream" -InFile $from `
        -SkipCertificateCheck:$skipCert -TimeoutSec 120
    } catch { Log "$($job.id) state $path not saved: $($_.Exception.Message)" }
  }
}

# "45m", "90s", "2h" or a number of seconds: seconds (0 for none), or $null when it is neither.
function Get-Seconds($value) {
  if ($null -eq $value -or "$value" -eq "") { return 0 }
  if ($value -is [int] -or $value -is [long]) { return [math]::Max([long]$value, 0) }
  if ("$value" -match "^(\d+)(s|m|h)?$") { return [long]$Matches[1] * @{ "" = 1; s = 1; m = 60; h = 3600 }["$($Matches[2])"] }
  $null
}

# The CPUs and memory this agent may use: .NET reads the cgroup's quota and limit on Linux.
function Get-Limits {
  @{ cpus = [Environment]::ProcessorCount; memoryMb = [long]([GC]::GetGCMemoryInfo().TotalAvailableMemoryBytes / 1MB) }
}

function Tool([string]$name) { if ($tools[$name]) { Expand $tools[$name] } else { $name } }

# A CLI's output, or an error naming it: its stderr stays out of the way, as it may echo input.
function Invoke-Tool([string]$name, [string[]]$arguments) {
  $global:LASTEXITCODE = 0
  $output = & (Tool $name) @arguments 2>$null
  if ($LASTEXITCODE) { throw "$name exited with $LASTEXITCODE" }
  ($output -join "`n")
}

# The field of a JSON document (a secret holding several values), or the document itself.
function Select-Field([string]$document, [string]$field, [string]$name) {
  if (-not $field) { return $document }
  try { $object = $document | ConvertFrom-Json -AsHashtable } catch { throw "$name is not JSON, so it has no field $field" }
  if ($object -isnot [Collections.IDictionary] -or -not $object.ContainsKey($field)) { throw "$name has no field $field" }
  "$($object[$field])"
}

# The job's identity token from testor for `audience`: @{ token; expires_in }.
function Request-IdToken($job, [string]$audience) { Call "/agent/jobs/$($job.id)/token" @{ audience = $audience } }

$script:vaultToken = $null
$script:currentJob = $null
function Get-VaultToken($vault, [string]$address) {
  if ($script:vaultToken) { return $script:vaultToken }
  $script:vaultToken =
    if ($env:VAULT_TOKEN) { $env:VAULT_TOKEN }
    elseif ($vault.tokenFile) { (Get-Content -Raw -LiteralPath (Expand $vault.tokenFile)).Trim() }
    elseif ($vault.jwtRole) {
      # Vault's JWT auth, trusting testor as an issuer: the role's bound claims (project, kind)
      # decide what this job may read.
      $audience = if ($vault.jwtAudience) { $vault.jwtAudience } else { "vault" }
      $mount = if ($vault.authPath) { $vault.authPath } else { "jwt" }
      $jwt = (Request-IdToken $script:currentJob $audience).token
      $login = Invoke-RestMethod -Method Post -Uri "$address/v1/auth/$mount/login" -Headers (Get-VaultHeaders $vault $null) `
        -ContentType "application/json" -Body (@{ role = $vault.jwtRole; jwt = $jwt } | ConvertTo-Json)
      $login.auth.client_token
    }
    elseif ($vault.kubernetesRole) {
      $jwtFile = if ($vault.jwtFile) { Expand $vault.jwtFile } else { "/var/run/secrets/kubernetes.io/serviceaccount/token" }
      $mount = if ($vault.authPath) { $vault.authPath } else { "kubernetes" }
      $login = Invoke-RestMethod -Method Post -Uri "$address/v1/auth/$mount/login" -Headers (Get-VaultHeaders $vault $null) `
        -ContentType "application/json" -Body (@{ role = $vault.kubernetesRole; jwt = (Get-Content -Raw -LiteralPath $jwtFile).Trim() } | ConvertTo-Json)
      $login.auth.client_token
    } else { throw "vault: no token (VAULT_TOKEN, vault.tokenFile, vault.kubernetesRole or vault.jwtRole)" }
  $script:vaultToken
}

function Get-VaultHeaders($vault, $token) {
  $headers = @{}
  if ($token) { $headers["X-Vault-Token"] = $token }
  $namespace = if ($vault.namespace) { $vault.namespace } else { $env:VAULT_NAMESPACE }
  if ($namespace) { $headers["X-Vault-Namespace"] = $namespace }
  $headers
}

function Get-VaultSecret([string]$reference) {
  $path, $field = $reference -split "#", 2
  if (-not $field) { throw "a vault reference names a field: vault:<path>#<field>" }
  $vault = if ($settings.vault) { $settings.vault } else { @{} }
  $address = "$(if ($vault.address) { $vault.address } else { $env:VAULT_ADDR })".TrimEnd("/")
  if (-not $address) { throw "vault: no address (vault.address or VAULT_ADDR)" }
  $answer = Invoke-RestMethod -Uri "$address/v1/$($path.TrimStart('/'))" -Headers (Get-VaultHeaders $vault (Get-VaultToken $vault $address))
  # KV version 2 nests the values under data.data (with data.metadata); version 1 does not.
  $data = if ($null -ne $answer.data.data -and $null -ne $answer.data.metadata) { $answer.data.data } else { $answer.data }
  if ($null -eq $data -or $data.PSObject.Properties.Name -notcontains $field) { throw "vault: $path has no field $field" }
  "$($data.$field)"
}

# The value of one secret of agent.json, from where its reference says.
function Get-Secret([string]$reference) {
  $source, $rest = "$reference" -split ":", 2
  if (-not $rest) { throw "'$reference' is not <source>:<reference>" }
  switch ($source) {
    "env" { [Environment]::GetEnvironmentVariable($rest) }
    "file" { (Get-Content -Raw -LiteralPath (Expand $rest)) -replace "\r?\n\z", "" }
    "vault" { Get-VaultSecret $rest }
    "aws" {
      $id, $field = $rest -split "#", 2
      Select-Field (Invoke-Tool "aws" @("secretsmanager", "get-secret-value", "--secret-id", $id, "--query", "SecretString", "--output", "text")) $field "aws:$id"
    }
    "gcp" {
      if ($rest -match "^projects/([^/]+)/secrets/([^/]+)(?:/versions/([^/]+))?$") {
        $version = if ($Matches[3]) { $Matches[3] } else { "latest" }
        Invoke-Tool "gcloud" @("secrets", "versions", "access", $version, "--secret=$($Matches[2])", "--project=$($Matches[1])")
      } else { Invoke-Tool "gcloud" @("secrets", "versions", "access", "latest", "--secret=$rest") }
    }
    "azure" {
      $vaultName, $name = $rest -split "/", 2
      if (-not $name) { throw "an azure reference is azure:<vault>/<name>" }
      Invoke-Tool "az" @("keyvault", "secret", "show", "--vault-name", $vaultName, "--name", $name, "--query", "value", "--output", "tsv")
    }
    "sops" {
      $file, $key = $rest -split "#", 2
      $arguments = @("--decrypt") + $(if ($key) { @("--extract", "[`"$key`"]") } else { @() }) + @((Expand $file))
      Invoke-Tool "sops" $arguments
    }
    default { throw "unknown source $source (env, file, vault, aws, gcp, azure, sops)" }
  }
}

# Every secret of a job's project, or why one cannot be had: @{ vars = @{NAME = value} } or @{ error }.
function Resolve-Secrets($job) {
  $declared = $projects[$job.project].secrets
  $values = @{}
  if (-not $declared) { return @{ vars = $values } }
  $script:vaultToken = $null
  $script:currentJob = $job
  foreach ($name in @($declared.Keys | Sort-Object)) {
    if ($name -notmatch "^[A-Za-z_][A-Za-z0-9_]*$" -or $name -like "TESTOR_*") {
      return @{ error = "secret $name`: not a name a job's environment can hold (and not TESTOR_*)" }
    }
    try { $value = Get-Secret $declared[$name] } catch { return @{ error = "secret $name could not be read: $($_.Exception.Message)" } }
    if ([string]::IsNullOrEmpty($value)) { return @{ error = "secret $name is empty or missing ($(("$($declared[$name])" -split ':', 2)[0]))" } }
    $values[$name] = $value
  }
  @{ vars = $values }
}

# Isolated workspaces live under <home>/isolated; one left behind (the agent was stopped) goes
# at the next start.
$isolatedRoot = Join-Path $home_ "isolated"
function Remove-Isolated([string]$workspace, [string]$dir) {
  if (Test-Path -LiteralPath (Join-Path $dir ".git")) { git -C $workspace worktree remove --force $dir 2>$null }
  if (Test-Path -LiteralPath $dir) {
    try { Remove-Item -Recurse -Force -LiteralPath $dir } catch { Log "could not remove $dir`: $($_.Exception.Message)" }
  }
  if (Test-Path -LiteralPath (Join-Path $workspace ".git")) { git -C $workspace worktree prune 2>$null }
}
if (Test-Path -LiteralPath $isolatedRoot) {
  foreach ($left in @(Get-ChildItem -LiteralPath $isolatedRoot -Directory)) {
    try { Remove-Item -Recurse -Force -LiteralPath $left.FullName } catch { Log "could not remove $($left.FullName)" }
  }
  foreach ($project in $projects.Values) {
    $ws = if ($project.workspace) { Expand $project.workspace } else { $null }
    if ($ws -and (Test-Path -LiteralPath (Join-Path $ws ".git"))) { git -C $ws worktree prune 2>$null }
  }
}

function Invoke-Job($job) {
  $plan = Resolve-Job $job
  if (-not $plan.error) {
    $secrets = Resolve-Secrets $job
    if ($secrets.error) { $plan = @{ error = $secrets.error } }
  }
  $identity = $projects[$job.project].identity
  $idToken = $null
  if (-not $plan.error -and $identity) {
    try {
      $idToken = Request-IdToken $job $identity.audience
      $idTokenAt = Get-Date
    } catch { $plan = @{ error = "no identity token for $($identity.audience): $($_.Exception.Message)" } }
  }
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
  if ($job.snapshot) {
    try {
      $synced = Sync-Snapshot $job $plan.workspace
      Log "$($job.id) snapshot $($job.snapshot): $($synced.files) files, $($synced.fetched) fetched, $($synced.written) written, $($synced.deleted) deleted"
    } catch {
      $null = Call "/agent/jobs/$($job.id)/finish" @{ error = "snapshot $($job.snapshot) could not be written: $($_.Exception.Message)" }
      return
    }
  }
  if ($job.ref) {
    # The ref matched testor's pattern (no leading dash); -- ends git's options anyway.
    git -C $plan.workspace fetch --quiet --all --tags
    # An isolated job checks its ref out in its own worktree, below.
    if ($plan.isolate -ne "worktree") { git -C $plan.workspace checkout --quiet --detach $job.ref -- }
    if ($LASTEXITCODE) {
      $null = Call "/agent/jobs/$($job.id)/finish" @{ error = "git checkout $($job.ref) failed" }
      return
    }
  }

  $runDir = $plan.workspace
  if ($plan.isolate) {
    $runDir = Join-Path $isolatedRoot $job.id
    $null = New-Item -ItemType Directory -Force $isolatedRoot
    $made = try {
      if ($plan.isolate -eq "worktree") {
        git -C $plan.workspace worktree add --quiet --detach $runDir $(if ($job.ref) { $job.ref } else { "HEAD" })
        -not $LASTEXITCODE
      } else {
        Copy-Item -Recurse -Force -LiteralPath $plan.workspace -Destination $runDir
        $true
      }
    } catch { $false }
    if (-not $made) {
      Remove-Isolated $plan.workspace $runDir
      $null = Call "/agent/jobs/$($job.id)/finish" @{ error = "the isolated workspace ($($plan.isolate)) of $($job.project) could not be made" }
      return
    }
  }

  # Encoded: Start-Process passes arguments without escaping their double quotes, which would
  # break any command holding one.
  $limits = Get-Limits
  $quote = { param($text) "'" + ($text -replace "'", "''") + "'" }
  # Preserved caches: dropped for a clean job, else brought into an isolated workspace.
  $cache = Join-Path (Join-Path $home_ "cache") $job.project
  foreach ($path in $plan.preserve) {
    if ($job.clean) {
      Remove-Item -LiteralPath (Join-Path $cache $path), (Join-Path $runDir $path) -Recurse -Force -ErrorAction SilentlyContinue
    } elseif ($plan.isolate -and (Test-Path -LiteralPath (Join-Path $cache $path))) {
      $null = New-Item -ItemType Directory -Force (Split-Path (Join-Path $runDir $path))
      Copy-Item -LiteralPath (Join-Path $cache $path) -Destination (Join-Path $runDir $path) -Recurse -Force
    }
  }
  $list = { param($paths) if ($paths.Count) { "@(" + (($paths | ForEach-Object { & $quote $_ }) -join ", ") + ")" } else { "@()" } }
  $body = $plan.command
  if ($plan.container) {
    # In a container: a read-only root, the workspace mounted, /tmp a tmpfs, no network unless
    # allowed, the limits as hard ones; no token, key or variable of the agent inside, only
    # the job's secrets and the limits by name. Never privileged, nothing else mounted.
    $c = $plan.container
    $engine = Tool $(if ($tools.container) { "container" } else { "docker" })
    $runtime = @("run", "--rm", "--read-only", "--tmpfs", "/tmp", "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
      "--network", $(if ($c.network) { $c.network } else { "none" }), "--cpus", "$($limits.cpus)", "--memory", "$($limits.memoryMb)m",
      "-v", "$($runDir):/work", "-w", "/work", "-e", "TESTOR_CPUS", "-e", "TESTOR_MEMORY_MB")
    foreach ($name in $secrets.vars.Keys) { $runtime += @("-e", $name) }
    $shell = if ($c.shell) { @($c.shell) } else { @("sh", "-c") }
    $body = "& $(& $quote $engine) " + (($runtime + @($c.image) + $shell + @($plan.command) | ForEach-Object { & $quote "$_" }) -join " ")
  }
  $script = "Set-Location -LiteralPath $(& $quote $runDir); & $(& $quote $runPs1) -Project $(& $quote $job.project) -Kind $(& $quote $job.kind) -Artifacts $(& $list $plan.artifacts) -Reports $(& $list $plan.reports) -TimeoutSeconds $([long]$plan.timeout) -MemoryGuard $(& $quote $plan.guard) -Body { $body }"
  $out = Join-Path ([IO.Path]::GetTempPath()) "testor-agent-$($job.id)"
  $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
  $env:TESTOR_JOB_ID = $job.id
  $env:TESTOR_ACTOR = "agent:$([Environment]::MachineName.ToLower()) for $($job.requestedBy)"
  # The run gets the secrets in its environment, and run.ps1 writes their values as ***.
  $maskBefore = $env:TESTOR_MASK
  if ($idToken) {
    $tokenFile = "$out.jwt"
    [IO.File]::WriteAllText($tokenFile, $idToken.token)
    if (-not $IsWindows) { [IO.File]::SetUnixFileMode($tokenFile, [IO.UnixFileMode]"UserRead, UserWrite") }
    $secrets.vars["TESTOR_ID_TOKEN"] = $idToken.token
  }
  # Not secret: where the token is, and the identity's settings (a role to assume...); the job's
  # trace, which the run's spans join (and test tools that propagate W3C trace context).
  $plain = @{}
  if ($job.traceparent) { $plain["TRACEPARENT"] = $job.traceparent }
  # What the run may use, for flags such as --maxWorkers or Stryker's --concurrency; with
  # "limits": "auto", also the variables tools read themselves, unless they are set already.
  $plain["TESTOR_CPUS"] = "$($limits.cpus)"
  $plain["TESTOR_MEMORY_MB"] = "$($limits.memoryMb)"
  if ($plan.limits) {
    $auto = @{
      GOMAXPROCS = "$($limits.cpus)"; CARGO_BUILD_JOBS = "$($limits.cpus)"; DOTNET_PROCESSOR_COUNT = "$($limits.cpus)"
      PYTEST_XDIST_AUTO_NUM_WORKERS = "$($limits.cpus)"; NODE_OPTIONS = "--max-old-space-size=$([long]($limits.memoryMb * 0.75 / [math]::Max($limits.cpus, 1)))"
    }
    foreach ($name in $auto.Keys) { if (-not [Environment]::GetEnvironmentVariable($name)) { $plain[$name] = $auto[$name] } }
  }
  # What was tested: the commit checked out (release gates look runs up by it), its ref, and
  # whether the tree had changes; for a snapshot, what its sender said.
  if ($job.snapshot) {
    if ($job.commit) { $plain["TESTOR_COMMIT"] = "$($job.commit)" }
    if ($job.branch) { $plain["TESTOR_BRANCH"] = "$($job.branch)" }
  }
  if ($plan.git) {
    $head = git -C $runDir rev-parse HEAD 2>$null
    if (-not $LASTEXITCODE -and $head) {
      $plain["TESTOR_COMMIT"] = "$head".Trim()
      $plain["TESTOR_BRANCH"] = if ($job.ref) { $job.ref } else { "$(git -C $runDir rev-parse --abbrev-ref HEAD 2>$null)".Trim() }
      $plain["TESTOR_DIRTY"] = if (git -C $runDir status --porcelain 2>$null) { "true" } else { "false" }
      $plain["TESTOR_COMMITTED_AT"] = "$(git -C $runDir log -1 --format=%cI 2>$null)".Trim()
    }
  }
  if ($idToken) {
    $plain[$(if ($identity.file) { $identity.file } else { "TESTOR_ID_TOKEN_FILE" })] = $tokenFile
    if ($identity.env) { foreach ($name in $identity.env.Keys) { $plain[$name] = "$($identity.env[$name])" } }
  }
  $branch = if ($plain["TESTOR_BRANCH"] -and $plain["TESTOR_BRANCH"] -ne "HEAD") { $plain["TESTOR_BRANCH"] } else { $null }
  if ($plan.state.Count) { Restore-State $job $plan $runDir $branch }
  foreach ($name in $plain.Keys) { [Environment]::SetEnvironmentVariable($name, $plain[$name]) }
  foreach ($name in $secrets.vars.Keys) { [Environment]::SetEnvironmentVariable($name, $secrets.vars[$name]) }
  if ($secrets.vars.Count) { $env:TESTOR_MASK = (@($maskBefore) + @($secrets.vars.Keys) | Where-Object { $_ }) -join "," }
  try {
    $process = Start-Process pwsh -PassThru -NoNewWindow -RedirectStandardOutput "$out.out" -RedirectStandardError "$out.err" `
      -ArgumentList "-NoProfile", "-NonInteractive", "-EncodedCommand", $encoded
    # Windows keeps the exit code only for a process whose handle was opened while it ran.
    $null = $process.Handle
  } finally {
    Remove-Item Env:TESTOR_JOB_ID, Env:TESTOR_ACTOR -ErrorAction SilentlyContinue
    foreach ($name in @($secrets.vars.Keys) + @($plain.Keys)) { [Environment]::SetEnvironmentVariable($name, $null) }
    $env:TESTOR_MASK = $maskBefore
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
      # The identity token is renewed at half its life, in the file the run reads.
      if ($idToken -and ((Get-Date) - $idTokenAt).TotalSeconds -ge $idToken.expires_in / 2) {
        try {
          $fresh = Request-IdToken $job $identity.audience
          [IO.File]::WriteAllText($tokenFile, $fresh.token)
          $idToken = $fresh; $idTokenAt = Get-Date
        } catch { Log "$($job.id) could not renew its identity token: $($_.Exception.Message)" }
      }
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
  Remove-Item "$out.out", "$out.err", "$out.jwt" -ErrorAction SilentlyContinue
  if ($plan.state.Count -and -not $lost) { Save-State $job $plan $runDir $branch }
  if ($plan.isolate) {
    foreach ($path in $plan.preserve) {
      $from = Join-Path $runDir $path
      if (Test-Path -LiteralPath $from) {
        $to = Join-Path $cache $path
        Remove-Item -LiteralPath $to -Recurse -Force -ErrorAction SilentlyContinue
        $null = New-Item -ItemType Directory -Force (Split-Path $to)
        Copy-Item -LiteralPath $from -Destination $to -Recurse -Force
      }
    }
    Remove-Isolated $plan.workspace $runDir
  }
  if ($upload -and -not $lost) {
    try { Complete-Run $job $state ($null -ne $cancelledAt) } catch { Log "$($job.id) could not send the run: $($_.Exception.Message)" }
  }
  try {
    $done = Call "/agent/jobs/$($job.id)/finish" @{ exitCode = $process.ExitCode }
    Log "$($job.id) $($done.status) (exit $($process.ExitCode))"
  } catch { Log "$($job.id) ended (exit $($process.ExitCode)) but could not report it: $($_.Exception.Message)" }
}

Clear-Cas
Log "taking jobs from $base (labels: $($labels -join ', '); projects: $(@($projects.Keys) -join ', '))"
do {
  try {
    $job = Call "/agent/lease" @{ labels = $labels; wait = $Wait; key = $publicKey; instance = [Environment]::MachineName.ToLower() }
    if ($job) { Invoke-Job $job }
  } catch {
    Log "testor did not answer: $($_.Exception.Message)"
    if ($Once) { exit 1 }
    Start-Sleep -Seconds 5
  }
} until ($Once)
