#Requires -Version 7
# testor's client (docs/handoff.md): hands a test run off to an agent, with the terminal as if it
# ran here: the run's stdout on stdout, its stderr on stderr, its exit code as this one's.
#
#   pwsh testor.ps1 run [--project p] [--kind test] [--labels linux,gpu] [--files a b] [--names x y]
#                       [--affected | --affected=then-all] [--fail-fast] [--no-cache] [--digest] [--quiet]
#                       [--workspace w] [--root dir] [--snapshot-only] [-- <argv>]
#   pwsh testor.ps1 watch [--project p] [--kind watch] [--labels ...]
#
# run sends the working tree as a snapshot (only what testor lacks: runner/snapshot.ps1), queues
# the job, follows its output, and exits with its exit code; Ctrl+C cancels it, which ends the
# remote process tree. A result testor already holds for the same tree and command comes back at
# once (the result cache), replayed. --files and --names scope the run (the agent's agent.json
# says how its command takes them); --affected runs what the change since the branch's last
# snapshot affects, then-all the rest after; --digest prints the failures after the output, and
# --quiet --digest only them. -- <argv> sends a command (exec mode: an agent that accepts yours).
# --snapshot-only sends the tree and prints its snapshot's id, for an MCP client (docs/mcp.md).
#
# watch keeps a session open on an agent whose watch command reruns on each change: every save
# here (after 150 ms of quiet) sends a snapshot, and the reruns' output streams back. Ctrl+C ends it.
#
# Configuration: TESTOR_URL, and a token (a user's with the execute scope) in TESTOR_TOKEN or in
# the file TESTOR_TOKEN_FILE names (mode 0600 outside Windows); .testor/client.json in the
# repository may give "server", "project", "kind", "labels". The project is otherwise the
# repository's folder name, and the workspace a name of this worktree, so two worktrees run at once.
$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { }

function Fail([string]$message) { [Console]::Error.WriteLine("testor: $message"); exit 2 }

$command = if ($args.Count) { "$($args[0])" } else { "" }
if ($command -notin @("run", "watch")) { Fail "usage: testor run [options] [-- <argv>] | testor watch [options]" }
$opts = @{ labels = @(); files = @(); names = @() }
$argv = $null
$list = $null
for ($i = 1; $i -lt $args.Count; $i++) {
  $a = "$($args[$i])"
  if ($a -eq "--") { $argv = @($args[($i + 1)..($args.Count - 1)] | Where-Object { $null -ne $_ } | ForEach-Object { "$_" }); break }
  switch -Regex ($a) {
    "^--project$" { $opts.project = "$($args[++$i])"; $list = $null; continue }
    "^--kind$" { $opts.kind = "$($args[++$i])"; $list = $null; continue }
    "^--workspace$" { $opts.workspace = "$($args[++$i])"; $list = $null; continue }
    "^--root$" { $opts.root = "$($args[++$i])"; $list = $null; continue }
    "^--labels$" { $opts.labels = @("$($args[++$i])" -split "," | Where-Object { $_ }); $list = $null; continue }
    "^--files$" { $list = "files"; continue }
    "^--names$" { $list = "names"; continue }
    "^--affected$" { $opts.affected = $true; $list = $null; continue }
    "^--affected=then-all$" { $opts.affected = "then-all"; $list = $null; continue }
    "^--fail-fast$" { $opts.failFast = $true; $list = $null; continue }
    "^--no-cache$" { $opts.noCache = $true; $list = $null; continue }
    "^--digest$" { $opts.digest = $true; $list = $null; continue }
    "^--quiet$" { $opts.quiet = $true; $list = $null; continue }
    "^--snapshot-only$" { $opts.snapshotOnly = $true; $list = $null; continue }
    "^--" { Fail "unknown option $a" }
    default { if ($list) { $opts[$list] += $a } else { Fail "unexpected $a (files after --files, names after --names)" } }
  }
}

$root = (git -C $(if ($opts.root) { $opts.root } else { "." }) rev-parse --show-toplevel 2>$null)
if (-not $root) { Fail "not in a git repository" }
$root = "$root".Trim()
$client = @{}
$clientFile = Join-Path (Join-Path $root ".testor") "client.json"
if (Test-Path -LiteralPath $clientFile) { $client = Get-Content -Raw -LiteralPath $clientFile | ConvertFrom-Json -AsHashtable }
$server = if ($env:TESTOR_URL) { $env:TESTOR_URL } elseif ($client.server) { $client.server } else { Fail "no server: set TESTOR_URL" }
$base = "$server".TrimEnd("/")
$token = if ($env:TESTOR_TOKEN) { $env:TESTOR_TOKEN } elseif ($env:TESTOR_TOKEN_FILE) {
  if (-not $IsWindows -and ((Get-Item -LiteralPath $env:TESTOR_TOKEN_FILE).UnixFileMode -band [IO.UnixFileMode]"GroupRead, OtherRead, GroupWrite, OtherWrite")) {
    Fail "$($env:TESTOR_TOKEN_FILE) is readable by others: chmod 600 it"
  }
  (Get-Content -Raw -LiteralPath $env:TESTOR_TOKEN_FILE).Trim()
} else { Fail "no token: set TESTOR_TOKEN or TESTOR_TOKEN_FILE" }
$headers = @{ Authorization = "Bearer $token" }
$project = if ($opts.project) { $opts.project } elseif ($client.project) { $client.project } else { Split-Path -Leaf $root }
$kind = if ($opts.kind) { $opts.kind } elseif ($client.kind) { $client.kind } elseif ($command -eq "watch") { "watch" } else { "test" }
$labels = if ($opts.labels.Count) { $opts.labels } elseif ($client.labels) { @($client.labels) } else { @() }
# This worktree's name: jobs of two worktrees of one project run side by side.
$workspace = if ($opts.workspace) { $opts.workspace } else {
  "wt-" + (([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($root)) | ForEach-Object { $_.ToString("x2") }) -join "").Substring(0, 12)
}
$skipCert = $env:TESTOR_INSECURE -eq "1"

function Api([string]$method, [string]$path, $body) {
  $request = @{ Method = $method; Uri = "$base/api/v1$path"; Headers = $headers; SkipCertificateCheck = $skipCert; TimeoutSec = 60 }
  if ($null -ne $body) { $request.ContentType = "application/json"; $request.Body = (ConvertTo-Json -InputObject $body -Depth 6 -Compress) }
  Invoke-RestMethod @request
}

function Get-Snapshot {
  $env:TESTOR_TOKEN = $token
  $json = & pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot "snapshot.ps1") -Server $base -Project $project -Path $root -Json `
    -SkipCertificateCheck:$skipCert
  if ($LASTEXITCODE) { Fail "the snapshot could not be sent" }
  ($json | Select-Object -Last 1 | ConvertFrom-Json).id
}

# Follows run $id from byte $state.offset: each complete line to the stream it came from, as
# its marks say (o or e per line); a line whose mark has not come yet waits for it, unless the
# run has ended. $true once the run has ended and all of it is out.
$stdout = [Console]::OpenStandardOutput()
$stderr = [Console]::OpenStandardError()
function Read-Run([string]$id, $state) {
  $run = (Api Get "/runs/$id" $null).run
  $ended = $run.status -ne "running"
  $chunk = Invoke-WebRequest -Uri "$base/api/v1/runs/$id/log?offset=$($state.offset)" -Headers $headers -SkipCertificateCheck:$skipCert -TimeoutSec 60
  $bytes = [byte[]]$chunk.Content
  if ($bytes.Length) { $state.offset += $bytes.Length; $state.pending.AddRange($bytes) }
  $marks = (Invoke-WebRequest -Uri "$base/api/v1/runs/$id/streams?offset=$($state.marksAt)" -Headers $headers -SkipCertificateCheck:$skipCert -TimeoutSec 60).Content
  if ($marks -is [byte[]]) { $marks = [Text.Encoding]::ASCII.GetString($marks) }
  if ($marks) { $state.marks += $marks; $state.marksAt += $marks.Length }
  while ($true) {
    $nl = $state.pending.IndexOf([byte]10)
    if ($nl -lt 0) { break }
    if ($state.line -ge $state.marks.Length -and -not $ended) { break }
    $mark = if ($state.line -lt $state.marks.Length) { $state.marks[$state.line] } else { "o" }
    $line = $state.pending.GetRange(0, $nl + 1).ToArray()
    $state.pending.RemoveRange(0, $nl + 1)
    $state.line++
    if (-not $opts.quiet) { $(if ($mark -eq "e") { $stderr } else { $stdout }).Write($line, 0, $line.Length) }
  }
  if ($ended -and $bytes.Length -eq 0) {
    if ($state.pending.Count -and -not $opts.quiet) { $rest = $state.pending.ToArray(); $stdout.Write($rest, 0, $rest.Length) }
    $state.pending.Clear()
    $stdout.Flush(); $stderr.Flush()
    return $true
  }
  $stdout.Flush(); $stderr.Flush()
  $false
}

function New-Follow { @{ offset = [long]0; pending = [Collections.Generic.List[byte]]::new(); marks = ""; marksAt = [long]0; line = 0 } }

$snapshot = Get-Snapshot
# For an MCP client: the snapshot's id, for offload_change, open_session or run_mutation_check.
if ($opts.snapshotOnly) { $snapshot; exit 0 }
$jobId = $null
$over = @("passed", "failed", "cancelled", "expired")

if ($command -eq "run") {
  $request = [ordered]@{ project = $project; kind = $kind; snapshot = $snapshot; workspace = $workspace }
  if ($labels.Count) { $request.labels = $labels }
  $select = [ordered]@{}
  if ($opts.files.Count) { $select.files = @($opts.files | ForEach-Object { [IO.Path]::GetRelativePath($root, [IO.Path]::GetFullPath($_)) -replace "\\", "/" }) }
  if ($opts.names.Count) { $select.names = $opts.names }
  if ($opts.affected) { $select.affected = $opts.affected }
  if ($select.Count) { $request.select = $select }
  if ($opts.failFast) { $request.failFast = $true }
  if ($opts.noCache) { $request.cache = $false }
  if ($argv) { $request.argv = $argv }
  $job = Api Post "/jobs" $request
  $jobId = $job.id
  $finished = $false
  try {
    $followed = @{}
    $overAt = $null
    while ($true) {
      $job = Api Get "/jobs/$jobId" $null
      # Each run of the job in turn (then-all makes two), oldest first, followed to its end; a
      # cached job's run is the one that gave its result.
      $runs = if ($job.cached) { @($job.runId | Where-Object { $_ }) } else { @((Api Get "/runs?job=$jobId" $null).data | ForEach-Object { $_.id } | Sort-Object) }
      $next = @($runs | Where-Object { -not $followed[$_] })[0]
      if ($next) {
        $state = New-Follow
        while (-not (Read-Run $next $state)) { Start-Sleep -Milliseconds 250 }
        $followed[$next] = $true
        continue
      }
      # Over: its runs' records may reach testor a moment after the job's end.
      if ($job.status -in $over) {
        if (-not $overAt) { $overAt = Get-Date }
        $waited = ((Get-Date) - $overAt).TotalSeconds
        if ($job.cached -or ($followed.Count -and $waited -ge 1.5) -or $waited -ge 15) { break }
      }
      Start-Sleep -Milliseconds 250
    }
    $finished = $true
    if ($job.cached -and -not $opts.quiet) { [Console]::Error.WriteLine("testor: cached result of $($job.cached.job)") }
    if (-not $job.runId -and $job.error) { [Console]::Error.WriteLine("testor: $($job.error)") }
    if ($opts.digest -and $job.runId) {
      $digest = Invoke-WebRequest -Uri "$base/api/v1/runs/$($job.runId)/digest?format=text" -Headers $headers -SkipCertificateCheck:$skipCert
      [Console]::Out.Write([string]$digest.Content)
    }
    $code = if ($null -ne $job.exitCode) { [int]$job.exitCode } elseif ($job.status -eq "passed") { 0 } else { 1 }
    exit $code
  } finally {
    # Ctrl+C: the job is cancelled, which ends the remote process tree.
    if (-not $finished -and $jobId) { try { $null = Api Post "/jobs/$jobId/cancel" @{} } catch { } }
  }
}

# watch: a session, fed a snapshot after each burst of saves.
$session = Api Post "/watches" ([ordered]@{ project = $project; kind = $kind; snapshot = $snapshot; workspace = $workspace; labels = $labels })
$jobId = $session.id
$watcher = [IO.FileSystemWatcher]::new($root)
$watcher.IncludeSubdirectories = $true
$watcher.NotifyFilter = [IO.NotifyFilters]"FileName, DirectoryName, LastWrite, Size"
$last = $snapshot
$dirtyAt = $null
$beatAt = Get-Date
$followed = @{}
$state = $null
$runId = $null
try {
  [Console]::Error.WriteLine("testor: watching $root ($jobId); Ctrl+C ends the session")
  while ($true) {
    $change = $watcher.WaitForChanged([IO.WatcherChangeTypes]::All, 200)
    if (-not $change.TimedOut -and "$($change.Name)" -notmatch "(^|[\\/])\.git([\\/]|$)") { $dirtyAt = Get-Date }
    if ($dirtyAt -and ((Get-Date) - $dirtyAt).TotalMilliseconds -ge 150) {
      $dirtyAt = $null
      $id = Get-Snapshot
      if ($id -ne $last) { $null = Api Post "/watches/$jobId/changes" @{ snapshot = $id }; $last = $id; $beatAt = Get-Date }
    }
    if (((Get-Date) - $beatAt).TotalSeconds -ge 30) { $null = Api Post "/watches/$jobId/heartbeat" @{}; $beatAt = Get-Date }
    $job = Api Get "/jobs/$jobId" $null
    $latest = @((Api Get "/runs?job=$jobId" $null).data | ForEach-Object { $_.id } | Sort-Object -Descending)[0]
    if ($latest -and $latest -ne $runId) { $runId = $latest; $state = New-Follow }
    if ($runId -and -not $followed[$runId] -and (Read-Run $runId $state)) { $followed[$runId] = $true }
    if ($job.status -in $over) { break }
  }
} finally {
  try { $null = Api Delete "/watches/$jobId" $null } catch { }
  $watcher.Dispose()
}
