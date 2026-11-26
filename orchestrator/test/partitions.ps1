# Runs the ExUnit suite in partitions at once, each a VM of its own (folders and a port of its
# own, see test_helper.exs), and merges their coverage: mix test.coverage applies the 100% gate.
# Most tests are synchronous (they share the running server), so partitions are where the
# parallelism is.
#
#   pwsh test/partitions.ps1              # TESTOR_TEST_PARTITIONS, else 4
#   pwsh test/partitions.ps1 -Partitions 2
param([int]$Partitions = $(if ($env:TESTOR_TEST_PARTITIONS) { [int]$env:TESTOR_TEST_PARTITIONS } else { 4 }))
$ErrorActionPreference = "Stop"
Set-Location (Split-Path -Parent $PSScriptRoot)
# Through PowerShell: on Windows mix is a script (mix.ps1), which Start-Process cannot start.
$pwsh = (Get-Process -Id $PID).Path
$out = Join-Path ([IO.Path]::GetTempPath()) "testor-partitions-$PID"
$null = New-Item -ItemType Directory -Force $out
Get-ChildItem cover -Filter *.coverdata -ErrorAction SilentlyContinue | Remove-Item

# One build of the test environment before the partitions start: each mix test would compile it
# into the same _build/test at once, and a partition that loses the race fails (Windows CI:
# "could not write to file .../consolidated/Elixir.Inspect.beam").
$mixEnv = $env:MIX_ENV
$env:MIX_ENV = "test"
mix compile
$code = $LASTEXITCODE
$env:MIX_ENV = $mixEnv
if ($code) { throw "mix compile failed" }

$started = Get-Date
$runs = foreach ($i in 1..$Partitions) {
  # A child process takes the environment as it is when it starts.
  $env:MIX_TEST_PARTITION = "$i"
  $command = "mix test --partitions $Partitions --cover --export-coverage partition-$i; exit `$LASTEXITCODE"
  $p = Start-Process -FilePath $pwsh -PassThru -NoNewWindow -ArgumentList "-NoProfile", "-Command", $command `
    -RedirectStandardOutput (Join-Path $out "$i.out") -RedirectStandardError (Join-Path $out "$i.err")
  # Windows keeps the exit code only for a process whose handle was opened while it ran.
  $null = $p.Handle
  @{ Index = $i; Process = $p }
}
Remove-Item Env:MIX_TEST_PARTITION
foreach ($run in $runs) { $run.Process.WaitForExit() }

$failed = $false
foreach ($run in $runs) {
  $text = (Get-Content -Raw (Join-Path $out "$($run.Index).out")) + (Get-Content -Raw (Join-Path $out "$($run.Index).err"))
  $code = $run.Process.ExitCode
  "== partition $($run.Index) of $Partitions (exit $code)"
  # Its failures in full; otherwise its result line.
  if ($code -ne 0) { $text; $failed = $true }
  else { ($text -split "`n") | Where-Object { $_ -match "Finished in|Result:|tests?, " } }
}
"== all partitions in $([math]::Round(((Get-Date) - $started).TotalSeconds)) s"
Remove-Item -Recurse -Force $out -ErrorAction SilentlyContinue
if ($failed) { throw "a partition failed" }

"== mix test.coverage"
mix test.coverage
if ($LASTEXITCODE) { throw "coverage below the gate" }
