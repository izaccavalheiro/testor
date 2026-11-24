# Device sampler for the test orchestrator (Testor.Device). Long-lived: reads one
# command per line on stdin and answers each with one line of JSON on stdout.
#
#   static                      the machine: OS, model, CPU, memory modules, GPUs, disks
#   sample light                CPU (total and per core), memory, disk and network throughput
#   sample full [pid,pid,...]   light, plus GPU, volumes, battery, the top processes and the
#                               CPU/memory of each listed pid's process tree (the test runs)
#
# Rates come from raw performance counters and the previous sample (formatted counters sample
# for a second on every query). Counter classes are not localized, unlike Get-Counter paths.
# The JSON is ASCII (\uXXXX escapes), whatever the console code page.
$ErrorActionPreference = "SilentlyContinue"
$cores = [Environment]::ProcessorCount
$prev = @{}
$seen = @{}

# Fraction of the elapsed time a 100-ns timer counter advanced; $null on the first sample.
function Ratio([string]$key, [double]$value, [double]$time) {
  $seen[$key] = $true
  $p = $prev[$key]
  $prev[$key] = @($value, $time)
  if ($null -eq $p -or $time -le $p[1] -or $value -lt $p[0]) { return $null }
  return ($value - $p[0]) / ($time - $p[1])
}

# Per-second rate of a cumulative counter.
function Rate([string]$key, [double]$value, [double]$time) {
  $r = Ratio $key $value $time
  if ($null -eq $r) { return $null }
  return [math]::Round($r * 1e7)
}

function Pct($fraction) {
  if ($null -eq $fraction) { return $null }
  return [math]::Round([math]::Max(0, [math]::Min(100, 100 * $fraction)), 1)
}

function Iso($date) { if ($date) { $date.ToUniversalTime().ToString("o") } }

function Emit($object) {
  $json = $object | ConvertTo-Json -Compress -Depth 6
  $json = [regex]::Replace($json, "[^\x00-\x7F]", { param($m) "\u{0:x4}" -f [int][char]$m.Value })
  [Console]::Out.WriteLine($json)
  [Console]::Out.Flush()
}

function Get-Static {
  $os = Get-CimInstance Win32_OperatingSystem
  $cs = Get-CimInstance Win32_ComputerSystem
  $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
  $bios = Get-CimInstance Win32_BIOS
  [ordered]@{
    type = "static"
    host = $env:COMPUTERNAME
    os = [ordered]@{
      name = $os.Caption; version = $os.Version; build = $os.BuildNumber; architecture = $os.OSArchitecture
      installedAt = Iso $os.InstallDate; bootedAt = Iso $os.LastBootUpTime; locale = (Get-Culture).Name
      timezone = (Get-TimeZone).Id; powershell = $PSVersionTable.PSVersion.ToString()
    }
    machine = [ordered]@{ manufacturer = $cs.Manufacturer; model = $cs.Model; bios = $bios.SMBIOSBIOSVersion }
    cpu = [ordered]@{
      name = $cpu.Name.Trim(); cores = $cpu.NumberOfCores; threads = $cpu.NumberOfLogicalProcessors
      maxMHz = $cpu.MaxClockSpeed; l2KB = $cpu.L2CacheSize; l3KB = $cpu.L3CacheSize
    }
    memory = [ordered]@{
      total = [double]$os.TotalVisibleMemorySize * 1024
      installed = [double]$cs.TotalPhysicalMemory
      modules = @(Get-CimInstance Win32_PhysicalMemory | ForEach-Object {
          [ordered]@{ capacity = [double]$_.Capacity; speedMHz = $_.Speed; manufacturer = "$($_.Manufacturer)".Trim(); part = "$($_.PartNumber)".Trim(); slot = $_.DeviceLocator }
        })
    }
    gpus = @(Get-CimInstance Win32_VideoController | ForEach-Object {
        [ordered]@{
          name = $_.Name; driver = $_.DriverVersion; driverDate = Iso $_.DriverDate; adapterRAM = [double]$_.AdapterRAM
          resolution = $(if ($_.CurrentHorizontalResolution) { "$($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution)" })
          refreshHz = $_.CurrentRefreshRate
        }
      })
    disks = @(Get-PhysicalDisk | ForEach-Object {
        [ordered]@{ name = $_.FriendlyName; media = "$($_.MediaType)"; bus = "$($_.BusType)"; size = [double]$_.Size; health = "$($_.HealthStatus)" }
      })
  }
}

function Get-Sample([bool]$full, [int[]]$runPids) {
  $seen.Clear()
  $out = [ordered]@{ type = "sample"; full = $full; at = (Get-Date).ToUniversalTime().ToString("o") }

  # CPU: PercentProcessorTime is an inverse timer (time not idle).
  $perCore = @()
  foreach ($p in Get-CimInstance Win32_PerfRawData_PerfOS_Processor -Property Name, PercentProcessorTime, Timestamp_Sys100NS) {
    $r = Ratio "cpu:$($p.Name)" $p.PercentProcessorTime $p.Timestamp_Sys100NS
    $pct = $(if ($null -ne $r) { Pct (1 - $r) } else { $null })
    if ($p.Name -eq "_Total") { $out.cpu = $pct } else { $perCore += , @([int]$p.Name, $pct) }
  }
  $out.cores = @($perCore | Sort-Object { $_[0] } | ForEach-Object { $_[1] })

  $sys = Get-CimInstance Win32_PerfRawData_PerfOS_System -Property Processes, Threads, ProcessorQueueLength
  $out.processes = $sys.Processes; $out.threads = $sys.Threads; $out.queue = $sys.ProcessorQueueLength

  $mem = Get-CimInstance Win32_PerfRawData_PerfOS_Memory -Property AvailableBytes, CommittedBytes, CommitLimit, CacheBytes, PagesPersec, Timestamp_Sys100NS
  $out.memory = [ordered]@{
    available = [double]$mem.AvailableBytes; committed = [double]$mem.CommittedBytes; commitLimit = [double]$mem.CommitLimit
    cache = [double]$mem.CacheBytes; pagesPerSec = Rate "mem:pages" $mem.PagesPersec $mem.Timestamp_Sys100NS
  }

  $disk = Get-CimInstance Win32_PerfRawData_PerfDisk_PhysicalDisk -Filter "Name='_Total'" -Property DiskReadBytesPersec, DiskWriteBytesPersec, PercentIdleTime, Timestamp_Sys100NS
  $idle = Ratio "disk:idle" $disk.PercentIdleTime $disk.Timestamp_Sys100NS
  $out.disk = [ordered]@{
    read = Rate "disk:read" $disk.DiskReadBytesPersec $disk.Timestamp_Sys100NS
    write = Rate "disk:write" $disk.DiskWriteBytesPersec $disk.Timestamp_Sys100NS
    active = $(if ($null -ne $idle) { Pct (1 - $idle) } else { $null })
  }

  $nics = @()
  foreach ($n in Get-CimInstance Win32_PerfRawData_Tcpip_NetworkInterface -Property Name, BytesReceivedPersec, BytesSentPersec, CurrentBandwidth, Timestamp_Sys100NS) {
    $nics += [ordered]@{
      name = $n.Name; bandwidth = [double]$n.CurrentBandwidth
      rx = Rate "net:rx:$($n.Name)" $n.BytesReceivedPersec $n.Timestamp_Sys100NS
      tx = Rate "net:tx:$($n.Name)" $n.BytesSentPersec $n.Timestamp_Sys100NS
    }
  }
  $out.network = $nics

  if ($full) {
    # GPU: busy time per engine instance, summed per engine type; the busiest type is the
    # utilization Task Manager shows.
    $engines = @{}
    foreach ($e in Get-CimInstance Win32_PerfRawData_GPUPerformanceCounters_GPUEngine -Property Name, RunningTime, Timestamp_Sys100NS) {
      $r = Ratio "gpu:$($e.Name)" $e.RunningTime $e.Timestamp_Sys100NS
      if ($null -ne $r -and $e.Name -match "engtype_(.+)$") { $engines[$matches[1]] = [double]$engines[$matches[1]] + $r }
    }
    $gpuMem = @(Get-CimInstance Win32_PerfRawData_GPUPerformanceCounters_GPUAdapterMemory -Property DedicatedUsage, SharedUsage)
    $out.gpu = [ordered]@{
      util = $(if ($engines.Count) { Pct (($engines.Values | Measure-Object -Maximum).Maximum) } else { $null })
      engines = [ordered]@{}
      dedicated = [double](($gpuMem | Measure-Object DedicatedUsage -Sum).Sum)
      shared = [double](($gpuMem | Measure-Object SharedUsage -Sum).Sum)
    }
    foreach ($k in $engines.Keys | Sort-Object) { $out.gpu.engines[$k] = Pct $engines[$k] }

    $out.volumes = @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
        [ordered]@{ drive = $_.DeviceID; label = $_.VolumeName; fs = $_.FileSystem; size = [double]$_.Size; free = [double]$_.FreeSpace }
      })

    $battery = Get-CimInstance Win32_Battery | Select-Object -First 1
    if ($battery) {
      $out.battery = [ordered]@{
        charge = $battery.EstimatedChargeRemaining; status = $battery.BatteryStatus
        minutes = $(if ($battery.EstimatedRunTime -lt 71582788) { $battery.EstimatedRunTime } else { $null })
      }
    }

    # Processes, from performance data: readable for every process, protected ones included.
    $procs = @{}
    $children = @{}
    $handles = 0
    foreach ($p in Get-CimInstance Win32_PerfRawData_PerfProc_Process -Property Name, IDProcess, CreatingProcessID, PercentProcessorTime, Timestamp_Sys100NS, WorkingSetPrivate, WorkingSet, ThreadCount, HandleCount) {
      if ($p.Name -eq "_Total" -or $p.IDProcess -eq 0) { continue }
      $r = Ratio "proc:$($p.IDProcess):$($p.Name)" $p.PercentProcessorTime $p.Timestamp_Sys100NS
      $procs[[int]$p.IDProcess] = [ordered]@{
        pid = [int]$p.IDProcess; parent = [int]$p.CreatingProcessID; name = $p.Name -replace "#\d+$", ""
        cpu = $(if ($null -ne $r) { [math]::Round(100 * $r / $cores, 1) } else { 0 })
        mem = [double]$p.WorkingSetPrivate; ws = [double]$p.WorkingSet; threads = $p.ThreadCount; handles = $p.HandleCount; run = $null
      }
      $handles += $p.HandleCount
      $children[[int]$p.CreatingProcessID] += , [int]$p.IDProcess
    }
    $out.handles = $handles

    # Each run's process tree: its PowerShell and everything under it.
    $runs = [ordered]@{}
    foreach ($runPid in $runPids) {
      if (-not $procs.ContainsKey($runPid)) { continue }
      $tree = @(); $queue = [Collections.Generic.Queue[int]]::new(); $queue.Enqueue($runPid)
      while ($queue.Count) {
        $id = $queue.Dequeue()
        if (-not $procs.ContainsKey($id) -or $tree -contains $id) { continue }
        $tree += $id; $procs[$id].run = $runPid
        foreach ($c in @($children[$id])) { if ($c -and $c -ne $id) { $queue.Enqueue($c) } }
      }
      $runs["$runPid"] = [ordered]@{
        processes = $tree.Count
        cpu = [math]::Round((($tree | ForEach-Object { $procs[$_].cpu }) | Measure-Object -Sum).Sum, 1)
        mem = [double]((($tree | ForEach-Object { $procs[$_].mem }) | Measure-Object -Sum).Sum)
        top = @($tree | ForEach-Object { $procs[$_] } | Sort-Object { $_.cpu } -Descending | Select-Object -First 5 | ForEach-Object { $_.name })
      }
    }
    $out.runs = $runs

    $all = $procs.Values
    $top = @($all | Sort-Object { $_.cpu } -Descending | Select-Object -First 15) + @($all | Sort-Object { $_.mem } -Descending | Select-Object -First 15)
    $out.top = @($top | Sort-Object { $_.pid } -Unique | Sort-Object { $_.cpu } -Descending)
  }

  # Forget counters of instances that are gone (processes, GPU engines come and go).
  # A light sample reads no GPU or process counters: keep their baselines for the next full one.
  foreach ($k in @($prev.Keys)) {
    if (-not $seen.ContainsKey($k) -and ($full -or $k -notmatch "^(gpu|proc):")) { $prev.Remove($k) }
  }
  $out
}

while ($null -ne ($line = [Console]::In.ReadLine())) {
  $words = $line.Trim() -split "\s+"
  $watch = [Diagnostics.Stopwatch]::StartNew()
  try {
    $result = switch ($words[0]) {
      "static" { Get-Static }
      "sample" {
        $pids = @()
        if ($words.Count -gt 2 -and $words[2]) { $pids = @($words[2] -split "," | Where-Object { $_ } | ForEach-Object { [int]$_ }) }
        Get-Sample ($words[1] -eq "full") $pids
      }
      "exit" { exit 0 }
      default { [ordered]@{ type = "error"; error = "unknown command: $line" } }
    }
  } catch {
    $result = [ordered]@{ type = "error"; error = "$_" }
  }
  $result.ms = $watch.ElapsedMilliseconds
  Emit $result
}
