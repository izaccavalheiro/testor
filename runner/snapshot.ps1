#Requires -Version 7
# Sends a working tree to testor as a content-addressed snapshot (docs/snapshots.md), and
# optionally queues a job that runs it: only the contents testor lacks are uploaded, so a
# one-line change sends one file. Windows, Linux, macOS.
#
#   pwsh snapshot.ps1 -Server https://testor.example.com -Project my-app
#   pwsh snapshot.ps1 -Server ... -Project my-app -Kind test -Labels linux   # and queue a job
#
# The tree is what git sees: tracked and untracked files, uncommitted changes included, minus
# what .gitignore excludes (git ls-files -co --exclude-standard). Symbolic links are followed
# inside the tree and refused when they point out of it. Hashes are cached in the git folder
# (testor-snapshot.json), by size and write time, so an unchanged file is not read again.
#
# The token (a user's, with the execute scope) comes from TESTOR_TOKEN or -TokenFile. Prints the
# snapshot's id (sha256:<hex>), then the job's id with -Kind; with -Json, one JSON object instead.
param(
  [Parameter(Mandatory)][string]$Server,
  [Parameter(Mandatory)][ValidatePattern("^[A-Za-z0-9_.-]{1,100}$")][string]$Project,
  [string]$Path = ".",
  [string]$TokenFile,
  [string]$Kind,
  [string[]]$Labels = @(),
  [switch]$Json,
  [switch]$SkipCertificateCheck
)
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { }

$base = $Server.TrimEnd("/")
$token = if ($env:TESTOR_TOKEN) { $env:TESTOR_TOKEN } elseif ($TokenFile) { (Get-Content -Raw -LiteralPath $TokenFile).Trim() } else { throw "no token: set TESTOR_TOKEN or -TokenFile" }
$headers = @{ Authorization = "Bearer $token" }
$root = (git -C $Path rev-parse --show-toplevel).Trim()
$gitDir = [IO.Path]::GetFullPath((git -C $root rev-parse --git-dir).Trim(), $root)
$sep = [IO.Path]::DirectorySeparatorChar
$rootFull = [IO.Path]::GetFullPath($root).TrimEnd($sep) + $sep

# The files, as git lists them; on Windows, the executable bit as the index holds it.
$listed = (git -C $root -c core.quotepath=off ls-files -z --cached --others --exclude-standard) -join "" -split "`0" |
  Where-Object { $_ } | Sort-Object -Unique
$indexModes = @{}
if ($IsWindows) {
  foreach ($line in ((git -C $root ls-files -s -z) -join "" -split "`0")) {
    if ($line -match "^(\d+) [0-9a-f]+ \d+`t(.+)$") { $indexModes[$Matches[2]] = $Matches[1] }
  }
}

$cacheFile = Join-Path $gitDir "testor-snapshot.json"
$cache = @{}
if (Test-Path -LiteralPath $cacheFile) { try { $cache = Get-Content -Raw -LiteralPath $cacheFile | ConvertFrom-Json -AsHashtable } catch { } }
$fresh = @{}
$files = [Collections.Generic.List[object]]::new()
$paths = @{}
foreach ($rel in $listed) {
  $full = Join-Path $root $rel
  $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
  # Deleted but still tracked, or a submodule's folder: not a file of the tree.
  if (-not $item -or ($item.PSIsContainer -and -not $item.LinkType)) { continue }
  if ($item.LinkType) {
    $target = [IO.Path]::GetFullPath($item.ResolveLinkTarget($true).FullName)
    if (-not $target.StartsWith($rootFull) -or -not (Test-Path -LiteralPath $target -PathType Leaf)) {
      throw "$rel is a link out of the tree (or to a folder): a snapshot holds files of the tree only"
    }
    $item = Get-Item -LiteralPath $target
  }
  $ticks = $item.LastWriteTimeUtc.Ticks
  $known = $cache[$rel]
  $sha = if ($known -and $known.size -eq $item.Length -and $known.ticks -eq $ticks) { $known.sha256 }
         else { (Get-FileHash -Algorithm SHA256 -LiteralPath $item.FullName).Hash.ToLower() }
  $fresh[$rel] = @{ size = $item.Length; ticks = $ticks; sha256 = $sha }
  $executable = if ($IsWindows) { $indexModes[$rel] -eq "100755" } else { [bool]($item.UnixFileMode -band [IO.UnixFileMode]::UserExecute) }
  $files.Add([ordered]@{ path = $rel; sha256 = $sha; mode = $(if ($executable) { "755" } else { "644" }); size = $item.Length })
  $paths[$sha] = $item.FullName
}
ConvertTo-Json -InputObject $fresh -Compress | Set-Content -LiteralPath $cacheFile

$manifest = [ordered]@{ files = $files }
$branch = (git -C $root rev-parse --abbrev-ref HEAD 2>$null)
if ($branch -and $branch -ne "HEAD") { $manifest.branch = "$branch".Trim() }
$commit = (git -C $root rev-parse HEAD 2>$null)
if ($commit) { $manifest.commit = "$commit".Trim() }
$body = ConvertTo-Json -InputObject $manifest -Depth 4 -Compress
$offer = { Invoke-RestMethod -Method Post -Uri "$base/api/v1/projects/$Project/snapshots" -Headers $headers -ContentType "application/json" `
  -Body ([Text.Encoding]::UTF8.GetBytes($body)) -SkipCertificateCheck:$SkipCertificateCheck -TimeoutSec 300 }
$answer = & $offer
$uploaded = @($answer.missing).Count
if ($uploaded) {
  $answer.missing | ForEach-Object -ThrottleLimit 8 -Parallel {
    $null = Invoke-RestMethod -Method Put -Uri "$($using:base)/api/v1/blobs/sha256:$_" -Headers $using:headers `
      -ContentType "application/octet-stream" -InFile ($using:paths)[$_] -SkipCertificateCheck:$using:SkipCertificateCheck -TimeoutSec 600
  }
  $answer = & $offer
  if (@($answer.missing).Count) { throw "testor still lacks $(@($answer.missing).Count) contents" }
}

$result = [ordered]@{ id = $answer.id; files = $files.Count; uploaded = $uploaded }
if ($Kind) {
  $job = [ordered]@{ project = $Project; kind = $Kind; snapshot = $answer.id }
  if ($Labels.Count) { $job.labels = $Labels }
  $queued = Invoke-RestMethod -Method Post -Uri "$base/api/v1/jobs" -Headers $headers -ContentType "application/json" `
    -Body (ConvertTo-Json -InputObject $job -Compress) -SkipCertificateCheck:$SkipCertificateCheck -TimeoutSec 60
  $result.job = $queued.id
}
if ($Json) { ConvertTo-Json -InputObject $result -Compress }
else {
  $result.id
  if ($result.job) { $result.job }
  [Console]::Error.WriteLine("snapshot: $($files.Count) files, $uploaded uploaded")
}
