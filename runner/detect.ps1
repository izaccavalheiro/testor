#Requires -Version 7
# Proposes agent.json project entries for a folder (docs/zero-config.md): its commands per task,
# with their selections, reports, artifacts, caches and state, read from the project's files.
#
#   pwsh detect.ps1 <folder>          (or: pwsh agent.ps1 -Detect <folder>)
#
# It only reads files: it runs nothing from the project (no npm, no scripts), writes nothing and
# applies nothing. Commands are the owner's decision: review the proposal, then copy what you
# want into agent.json. It prints JSON on stdout ({"projects": {...}}), and what it found on
# stderr. A folder with no project files of its own is looked into one level down (monorepos).
param([Parameter(Mandatory, Position = 0)][string]$Path)
$ErrorActionPreference = "Stop"

function Test-File([string]$root, [string]$pattern) { [bool](Get-ChildItem -LiteralPath $root -Filter $pattern -Force -File -ErrorAction SilentlyContinue | Select-Object -First 1) }
function Read-Json([string]$file) { try { Get-Content -Raw -LiteralPath $file | ConvertFrom-Json -AsHashtable } catch { $null } }
function Read-Text([string]$file) { if (Test-Path -LiteralPath $file) { Get-Content -Raw -LiteralPath $file } else { "" } }

# One folder's proposal, or $null when it holds no project this knows.
function Find-Project([string]$root) {
  $commands = [ordered]@{}
  $labels = [Collections.Generic.List[string]]::new(); $labels.Add("linux")
  $found = [Collections.Generic.List[string]]::new()
  $fullRunOn = [Collections.Generic.List[string]]::new()

  # --- Node.js -------------------------------------------------------------------------------
  $pkgFile = Join-Path $root "package.json"
  if (Test-Path -LiteralPath $pkgFile) {
    $pkg = Read-Json $pkgFile
    $deps = @{}
    foreach ($key in "dependencies", "devDependencies") { if ($pkg -and $pkg[$key]) { foreach ($d in $pkg[$key].Keys) { $deps[$d] = $true } } }
    $scripts = if ($pkg -and $pkg.scripts) { $pkg.scripts } else { @{} }
    $pm = if (Test-File $root "pnpm-lock.yaml") { "pnpm" } elseif (Test-File $root "yarn.lock") { "yarn" } elseif ((Test-File $root "bun.lockb") -or (Test-File $root "bun.lock")) { "bun" } else { "npm" }
    $x = @{ npm = @("npx"); pnpm = @("pnpm", "exec"); yarn = @("yarn"); bun = @("bunx") }[$pm]
    $found.Add("node ($pm)")
    # Dependencies stay in the workspace between jobs: install runs when the lockfile changes.
    $commands["install"] = [ordered]@{ command = @{ npm = "npm ci"; pnpm = "pnpm install --frozen-lockfile"; yarn = "yarn install --immutable"; bun = "bun install --frozen-lockfile" }[$pm]; timeout = "20m" }
    if ($deps.vitest -or (Test-File $root "vitest.config.*")) {
      $found.Add("vitest")
      $commands["test"] = [ordered]@{
        argv = $x + @("vitest", "run", "--reporter=default", "--reporter=junit", "--outputFile.junit=reports/junit.xml")
        select = [ordered]@{ files = "append"; names = @("-t", "{}") }
        affected = [ordered]@{ argv = $x + @("vitest", "related", "--run"); files = "append" }
        reports = @("reports/junit.xml"); timeout = "30m"
      }
      $commands["watch"] = [ordered]@{ argv = $x + @("vitest"); rerun = "native" }
    } elseif ($deps.jest -or (Test-File $root "jest.config.*")) {
      $found.Add("jest")
      $commands["test"] = [ordered]@{
        argv = $x + @("jest", "--ci")
        select = [ordered]@{ files = "append"; names = @("-t", "{}") }
        affected = [ordered]@{ argv = $x + @("jest", "--ci", "--findRelatedTests"); files = "append" }
        timeout = "30m"
      }
      $commands["watch"] = [ordered]@{ argv = $x + @("jest", "--watchAll"); rerun = "native" }
    } elseif ($scripts.test) {
      $found.Add("npm test")
      $commands["test"] = [ordered]@{ command = "$pm test"; timeout = "30m" }
    }
    if ($deps["@playwright/test"] -or (Test-File $root "playwright.config.*")) {
      $found.Add("playwright")
      $commands["e2e"] = [ordered]@{
        argv = $x + @("playwright", "test")
        select = [ordered]@{ files = "append"; names = @("-g", "{}") }
        artifacts = @("playwright-report", "test-results"); timeout = "45m"
      }
      $labels.Add("browser")
    }
    if ($deps["@stryker-mutator/core"] -or (Test-File $root "stryker.conf.*") -or (Test-File $root "stryker.config.*")) {
      $found.Add("stryker")
      $commands["mutation"] = [ordered]@{
        command = "$($x -join ' ') stryker run --incremental"
        reports = @("reports/mutation/mutation.json"); artifacts = @("reports/mutation")
        state = @("reports/stryker-incremental.json"); timeout = "2h"; memoryGuard = [ordered]@{ warn = 85; stop = 95 }
      }
      $labels.Add("mutation")
    }
    if ($scripts.lint) { $commands["lint"] = [ordered]@{ command = "$pm run lint"; timeout = "15m" } }
    if ($scripts.typecheck) { $commands["typecheck"] = [ordered]@{ command = "$pm run typecheck"; timeout = "15m" } }
  }

  # --- Python --------------------------------------------------------------------------------
  $pyproject = Read-Text (Join-Path $root "pyproject.toml")
  $python = $pyproject -or (Test-File $root "setup.cfg") -or (Test-File $root "requirements*.txt") -or (Test-File $root "pytest.ini") -or (Test-File $root "tox.ini")
  if ($python) {
    $requirements = $pyproject + (Get-ChildItem -LiteralPath $root -Filter "requirements*.txt" -File -ErrorAction SilentlyContinue | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName }) -join "`n"
    $found.Add("python (pytest)")
    $commands["test"] = [ordered]@{
      argv = @("python", "-m", "pytest", "--junitxml=reports/junit.xml")
      select = [ordered]@{ files = "append"; names = @("-k", "{}") }
      reports = @("reports/junit.xml"); timeout = "30m"
    }
    if ($requirements -match "pytest-testmon") { $commands.test.affected = [ordered]@{ argv = @("python", "-m", "pytest", "--testmon"); files = "append" }; $found.Add("testmon") }
    if ($requirements -match "pytest-cov") {
      $commands["coverage"] = [ordered]@{ argv = @("python", "-m", "pytest", "--cov", "--cov-report=xml:reports/coverage.xml"); reports = @("reports/coverage.xml"); timeout = "45m" }
    }
    if ($requirements -match "pytest-watch|\bptw\b") { $commands["watch"] = [ordered]@{ argv = @("ptw"); rerun = "native" } }
    else { $commands["watch"] = [ordered]@{ argv = @("python", "-m", "pytest"); rerun = "restart"; select = [ordered]@{ files = "append" } } }
    $fullRunOn.Add("conftest.py")
  }

  # --- Go ------------------------------------------------------------------------------------
  if (Test-Path -LiteralPath (Join-Path $root "go.mod")) {
    $found.Add("go")
    $commands["test"] = [ordered]@{ argv = @("go", "test", "./..."); select = [ordered]@{ names = @("-run", "{}") }; timeout = "30m" }
    $commands["race"] = [ordered]@{ argv = @("go", "test", "-race", "./..."); timeout = "45m" }
  }

  # --- Rust ----------------------------------------------------------------------------------
  if (Test-Path -LiteralPath (Join-Path $root "Cargo.toml")) {
    $nextest = Test-Path -LiteralPath (Join-Path (Join-Path $root ".config") "nextest.toml")
    $found.Add($(if ($nextest) { "rust (nextest)" } else { "rust" }))
    $commands["test"] = if ($nextest) {
      [ordered]@{ argv = @("cargo", "nextest", "run", "--profile", "ci"); select = [ordered]@{ names = @("-E", "test({})") }; preserve = @("target"); timeout = "45m" }
    } else {
      [ordered]@{ argv = @("cargo", "test"); select = [ordered]@{ names = "append" }; preserve = @("target"); timeout = "45m" }
    }
  }

  # --- .NET ----------------------------------------------------------------------------------
  if ((Test-File $root "*.sln") -or (Test-File $root "*.slnx") -or (Test-File $root "*.csproj")) {
    $found.Add(".net")
    $commands["test"] = [ordered]@{
      argv = @("dotnet", "test", "--logger", "trx;LogFileName=test.trx", "--results-directory", "reports")
      select = [ordered]@{ names = @("--filter", "{}") }
      reports = @("reports/test.trx"); timeout = "30m"
    }
    if (Test-File $root "stryker-config.json") {
      $found.Add("stryker.net")
      $commands["mutation"] = [ordered]@{ command = "dotnet stryker --since"; reports = @("StrykerOutput/reports/mutation-report.json"); timeout = "2h" }
      $labels.Add("mutation")
    }
  }

  if (-not $commands.Count) { return $null }
  $entry = [ordered]@{ snapshots = $true; limits = "auto"; labels = @($labels | Select-Object -Unique); commands = $commands }
  if ($fullRunOn.Count) { $entry.fullRunOn = @($fullRunOn) }
  @{ entry = $entry; found = $found }
}

$root = (Resolve-Path -LiteralPath $Path).Path
$projects = [ordered]@{}
$top = Find-Project $root
if ($top) {
  $projects[(Split-Path -Leaf $root)] = $top.entry
  [Console]::Error.WriteLine("detect: $(Split-Path -Leaf $root): $($top.found -join ', ')")
} else {
  foreach ($dir in Get-ChildItem -LiteralPath $root -Directory | Where-Object { $_.Name -notmatch "^(\.|node_modules|vendor|target|dist|build)" } | Sort-Object Name) {
    $sub = Find-Project $dir.FullName
    if (-not $sub) { continue }
    $sub.entry.workspace = "./$($dir.Name)"
    $projects[$dir.Name] = $sub.entry
    [Console]::Error.WriteLine("detect: $($dir.Name): $($sub.found -join ', ')")
  }
}
if (-not $projects.Count) { [Console]::Error.WriteLine("detect: no project found in $root"); exit 1 }
[Console]::Error.WriteLine("detect: a proposal to review, not applied: copy what you want into agent.json")
ConvertTo-Json -InputObject ([ordered]@{ projects = $projects }) -Depth 10
