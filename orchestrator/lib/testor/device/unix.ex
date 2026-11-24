defmodule Testor.Device.Unix do
  @moduledoc """
  Device stats on Linux and macOS, in the shape priv/sysinfo.ps1 gives on Windows (see
  docs/api.md). Linux reads /proc and /sys (plus nvidia-smi and lsblk when present); macOS
  asks sysctl, vm_stat, ps, netstat, iostat, df and pmset. Rates come from the previous
  sample, kept in the `baseline` map this module threads through.

  What a platform cannot tell is nil: macOS has no per-core load or split disk read/write
  without root, and GPU load is known only for NVIDIA GPUs on Linux.
  """
  alias Testor.OS

  # --- static ------------------------------------------------------------------------------

  def static do
    case OS.family() do
      :macos -> macos_static()
      _ -> linux_static()
    end
    |> Map.merge(%{"type" => "static", "host" => host(), "platform" => to_string(OS.family())})
  end

  defp linux_static do
    meminfo = meminfo()
    cpuinfo = read("/proc/cpuinfo")
    threads = :erlang.system_info(:logical_processors) || 1

    cores =
      cpuinfo
      |> String.split("\n\n", trim: true)
      |> Enum.map(fn block -> {field(block, "physical id"), field(block, "core id")} end)
      |> Enum.uniq()
      |> length()

    %{
      "os" => %{
        "name" => os_release()["PRETTY_NAME"] || "Linux",
        "version" => String.trim(read("/proc/sys/kernel/osrelease")),
        "build" => nil,
        "architecture" => cmd("uname", ["-m"]),
        "installedAt" => nil,
        "bootedAt" => booted_at(),
        "locale" => System.get_env("LANG"),
        "timezone" => timezone(),
        "powershell" => pwsh_version()
      },
      "machine" => %{
        "manufacturer" => dmi("sys_vendor"),
        "model" => dmi("product_name"),
        "bios" => dmi("bios_version")
      },
      "cpu" => %{
        "name" => field(cpuinfo, "model name") || field(cpuinfo, "Model") || cmd("uname", ["-p"]),
        "cores" => if(cores > 1, do: cores, else: threads),
        "threads" => threads,
        "maxMHz" =>
          int(read("/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq")) |> then(&(&1 && div(&1, 1000))),
        "l2KB" => cache_kb(2),
        "l3KB" => cache_kb(3)
      },
      "memory" => %{"total" => meminfo["MemTotal"], "installed" => meminfo["MemTotal"], "modules" => []},
      "gpus" => linux_gpus(),
      "disks" => linux_disks()
    }
  end

  defp macos_static do
    total = int(sysctl("hw.memsize"))
    threads = int(sysctl("hw.logicalcpu")) || :erlang.system_info(:logical_processors)

    %{
      "os" => %{
        "name" => "#{cmd("sw_vers", ["-productName"])} #{cmd("sw_vers", ["-productVersion"])}",
        "version" => cmd("sw_vers", ["-productVersion"]),
        "build" => cmd("sw_vers", ["-buildVersion"]),
        "architecture" => cmd("uname", ["-m"]),
        "installedAt" => nil,
        "bootedAt" => macos_boot(),
        "locale" => System.get_env("LANG"),
        "timezone" => timezone(),
        "powershell" => pwsh_version()
      },
      "machine" => %{"manufacturer" => "Apple", "model" => sysctl("hw.model"), "bios" => nil},
      "cpu" => %{
        "name" => sysctl("machdep.cpu.brand_string"),
        "cores" => int(sysctl("hw.physicalcpu")),
        "threads" => threads,
        "maxMHz" => int(sysctl("hw.cpufrequency_max")) |> then(&(&1 && div(&1, 1_000_000))),
        "l2KB" => int(sysctl("hw.l2cachesize")) |> then(&(&1 && div(&1, 1024))),
        "l3KB" => int(sysctl("hw.l3cachesize")) |> then(&(&1 && div(&1, 1024)))
      },
      "memory" => %{"total" => total, "installed" => total, "modules" => []},
      "gpus" => macos_gpus(),
      "disks" => []
    }
  end

  # --- samples -----------------------------------------------------------------------------

  @doc "A sample and the baseline for the next one."
  def sample(full, run_pids, baseline) do
    now = System.monotonic_time(:millisecond)
    elapsed = if baseline[:at], do: max(now - baseline[:at], 1) / 1000, else: nil

    {sample, baseline} =
      case OS.family() do
        :macos -> macos_sample(full, elapsed, baseline)
        _ -> linux_sample(full, elapsed, baseline)
      end

    {procs, baseline} =
      if full, do: processes(elapsed, baseline), else: {nil, baseline}

    sample =
      if procs do
        Map.merge(sample, %{
          "top" => top(procs),
          "runs" => runs(procs, run_pids),
          "handles" => nil,
          "volumes" => volumes(),
          "battery" => battery()
        })
      else
        sample
      end

    sample =
      Map.merge(sample, %{
        "type" => "sample",
        "full" => full,
        "at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

    {sample, Map.put(baseline, :at, now)}
  end

  defp linux_sample(full, elapsed, baseline) do
    stat = read("/proc/stat")

    cpus =
      for line <- String.split(stat, "\n"), String.starts_with?(line, "cpu") do
        [name | values] = String.split(line)
        values = values |> Enum.take(8) |> Enum.map(&String.to_integer/1)
        idle = Enum.at(values, 3, 0) + Enum.at(values, 4, 0)
        {name, Enum.sum(values), idle}
      end

    pct = fn {name, total, idle} ->
      case baseline[{:cpu, name}] do
        {t0, i0} when total > t0 -> Float.round(100 * (1 - (idle - i0) / (total - t0)), 1)
        _ -> nil
      end
    end

    baseline =
      Enum.reduce(cpus, baseline, fn {name, total, idle}, b -> Map.put(b, {:cpu, name}, {total, idle}) end)

    {all, cores} = Enum.split_with(cpus, fn {name, _, _} -> name == "cpu" end)
    meminfo = meminfo()
    vmstat = kv(read("/proc/vmstat"), " ")
    swaps = (int(vmstat["pswpin"]) || 0) + (int(vmstat["pswpout"]) || 0)
    {pages, baseline} = rate(baseline, :swaps, swaps, elapsed)

    {disk, baseline} = linux_disk(elapsed, baseline)
    {network, baseline} = linux_network(elapsed, baseline)
    [_, _, _, threads | _] = read("/proc/loadavg") |> String.split() |> Kernel.++([nil, nil, nil, nil])

    sample = %{
      "cpu" => all |> List.first() |> then(&(&1 && pct.(&1))),
      "cores" => Enum.map(cores, pct),
      "processes" => proc_count(),
      "threads" => threads && threads |> String.split("/") |> List.last() |> int(),
      "queue" => int(field(stat, "procs_running", " ")),
      "memory" => %{
        "available" => meminfo["MemAvailable"],
        "committed" => meminfo["Committed_AS"],
        "commitLimit" => meminfo["CommitLimit"],
        "cache" => meminfo["Cached"],
        "pagesPerSec" => pages
      },
      "disk" => disk,
      "network" => network
    }

    sample = if full, do: Map.put(sample, "gpu", nvidia_load()), else: sample
    {sample, baseline}
  end

  defp linux_disk(elapsed, baseline) do
    whole = ~r/^(sd[a-z]+|nvme\d+n\d+|vd[a-z]+|xvd[a-z]+|hd[a-z]+|mmcblk\d+)$/

    {read_b, write_b, ticks} =
      read("/proc/diskstats")
      |> String.split("\n", trim: true)
      |> Enum.map(&String.split/1)
      |> Enum.filter(fn f -> length(f) >= 13 and Regex.match?(whole, Enum.at(f, 2)) end)
      |> Enum.reduce({0, 0, 0}, fn f, {r, w, t} ->
        {r + String.to_integer(Enum.at(f, 5)) * 512, w + String.to_integer(Enum.at(f, 9)) * 512,
         max(t, String.to_integer(Enum.at(f, 12)))}
      end)

    {r, baseline} = rate(baseline, :disk_read, read_b, elapsed)
    {w, baseline} = rate(baseline, :disk_write, write_b, elapsed)
    {t, baseline} = rate(baseline, :disk_ticks, ticks, elapsed)
    {%{"read" => r, "write" => w, "active" => t && min(100.0, Float.round(t / 10, 1))}, baseline}
  end

  defp linux_network(elapsed, baseline) do
    read("/proc/net/dev")
    |> String.split("\n", trim: true)
    |> Enum.drop(2)
    |> Enum.flat_map(fn line ->
      case String.split(line, ":", parts: 2) do
        [name, rest] ->
          name = String.trim(name)
          f = String.split(rest)

          if name == "lo" or length(f) < 9,
            do: [],
            else: [{name, String.to_integer(Enum.at(f, 0)), String.to_integer(Enum.at(f, 8))}]

        _ ->
          []
      end
    end)
    |> Enum.map_reduce(baseline, fn {name, rx, tx}, b ->
      {rx_rate, b} = rate(b, {:rx, name}, rx, elapsed)
      {tx_rate, b} = rate(b, {:tx, name}, tx, elapsed)
      speed = int(read("/sys/class/net/#{name}/speed"))

      {%{
         "name" => name,
         "rx" => rx_rate,
         "tx" => tx_rate,
         "bandwidth" => if(speed && speed > 0, do: speed * 1_000_000, else: 0)
       }, b}
    end)
  end

  defp macos_sample(_full, elapsed, baseline) do
    threads = :erlang.system_info(:logical_processors) || 1
    total = int(sysctl("hw.memsize"))
    {vm, page} = vm_stat()

    available =
      Enum.sum(
        for k <- ["Pages free", "Pages inactive", "Pages speculative", "Pages purgeable"], do: vm[k] || 0
      ) * page

    swaps = (vm["Swapins"] || 0) + (vm["Swapouts"] || 0)
    {pages, baseline} = rate(baseline, :swaps, swaps, elapsed)
    ps = ps_list()
    cpu = ps |> Enum.map(& &1.cpu) |> Enum.sum() |> then(&Float.round(min(100.0, &1 / threads), 1))
    {io, baseline} = rate(baseline, :disk_io, iostat_bytes(), elapsed)
    {network, baseline} = macos_network(elapsed, baseline)

    sample = %{
      "cpu" => cpu,
      "cores" => [],
      "processes" => length(ps),
      "threads" => nil,
      "queue" => nil,
      "memory" => %{
        "available" => available,
        "committed" => total && total - available,
        "commitLimit" => total,
        "cache" => (vm["File-backed pages"] || 0) * page,
        "pagesPerSec" => pages
      },
      "disk" => %{"read" => nil, "write" => nil, "io" => io, "active" => nil},
      "network" => network
    }

    {sample, baseline}
  end

  defp macos_network(elapsed, baseline) do
    cmd("netstat", ["-ibn"])
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> Enum.map(&String.split/1)
    |> Enum.filter(fn f ->
      length(f) >= 10 and String.starts_with?(Enum.at(f, 2), "<Link#") and String.starts_with?(hd(f), "en")
    end)
    |> Enum.uniq_by(&hd/1)
    |> Enum.map_reduce(baseline, fn f, b ->
      name = hd(f)
      {rx, b} = rate(b, {:rx, name}, int(Enum.at(f, -5)) || 0, elapsed)
      {tx, b} = rate(b, {:tx, name}, int(Enum.at(f, -2)) || 0, elapsed)
      {%{"name" => name, "rx" => rx, "tx" => tx, "bandwidth" => 0}, b}
    end)
  end

  # --- processes ---------------------------------------------------------------------------

  defp processes(elapsed, baseline) do
    case OS.family() do
      :macos ->
        threads = :erlang.system_info(:logical_processors) || 1
        list = for p <- ps_list(), do: %{p | cpu: Float.round(p.cpu / threads, 1)}
        {list, baseline}

      _ ->
        linux_processes(elapsed, baseline)
    end
  end

  defp linux_processes(elapsed, baseline) do
    threads = :erlang.system_info(:logical_processors) || 1
    page = baseline[:page_size] || (int(cmd("getconf", ["PAGESIZE"])) || 4096)
    hz = 100

    procs =
      for name <- ls("/proc"),
          Regex.match?(~r/^\d+$/, name),
          stat <- [read("/proc/#{name}/stat")],
          stat != "" do
        # pid (comm) state ppid ...: comm may hold spaces and parentheses.
        close = :binary.matches(stat, ")") |> List.last() |> elem(0)
        open = :binary.match(stat, "(") |> elem(0)
        comm = binary_part(stat, open + 1, close - open - 1)
        f = stat |> binary_part(close + 2, byte_size(stat) - close - 2) |> String.split()

        %{
          pid: String.to_integer(name),
          parent: int(Enum.at(f, 1)) || 0,
          name: comm,
          ticks: (int(Enum.at(f, 11)) || 0) + (int(Enum.at(f, 12)) || 0),
          threads: int(Enum.at(f, 17)),
          mem: (int(Enum.at(f, 21)) || 0) * page
        }
      end

    previous = baseline[:procs] || %{}

    list =
      for p <- procs do
        cpu =
          case {previous[p.pid], elapsed} do
            {t0, e} when is_integer(t0) and is_number(e) and p.ticks >= t0 ->
              Float.round(100 * (p.ticks - t0) / hz / e / threads, 1)

            _ ->
              0.0
          end

        %{pid: p.pid, parent: p.parent, name: p.name, cpu: cpu, mem: p.mem, threads: p.threads}
      end

    {list, Map.merge(baseline, %{procs: Map.new(procs, &{&1.pid, &1.ticks}), page_size: page})}
  end

  defp ps_list do
    cmd("ps", ["-A", "-o", "pid=,ppid=,%cpu=,rss=,comm="])
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(String.trim(line), ~r/\s+/, parts: 5) do
        [pid, ppid, cpu, rss, comm] ->
          [
            %{
              pid: int(pid),
              parent: int(ppid),
              name: Path.basename(comm),
              cpu: float(cpu),
              mem: (int(rss) || 0) * 1024,
              threads: nil
            }
          ]

        _ ->
          []
      end
    end)
  end

  defp top(procs) do
    by_cpu = procs |> Enum.sort_by(& &1.cpu, :desc) |> Enum.take(15)
    by_mem = procs |> Enum.sort_by(& &1.mem, :desc) |> Enum.take(15)

    (by_cpu ++ by_mem)
    |> Enum.uniq_by(& &1.pid)
    |> Enum.sort_by(& &1.cpu, :desc)
    |> Enum.map(&public/1)
  end

  defp public(p) do
    %{
      "pid" => p.pid,
      "parent" => p.parent,
      "name" => p.name,
      "cpu" => p.cpu,
      "mem" => p.mem,
      "ws" => p.mem,
      "threads" => p.threads,
      "handles" => nil,
      "run" => Map.get(p, :run)
    }
  end

  # Each run's process tree: its PowerShell and everything under it.
  defp runs(procs, run_pids) do
    children = Enum.group_by(procs, & &1.parent)
    by_pid = Map.new(procs, &{&1.pid, &1})

    for pid <- run_pids, Map.has_key?(by_pid, pid), into: %{} do
      tree = tree(children, [pid], [pid]) |> Enum.map(&by_pid[&1]) |> Enum.reject(&is_nil/1)

      {to_string(pid),
       %{
         "processes" => length(tree),
         "cpu" => tree |> Enum.map(& &1.cpu) |> Enum.sum() |> Float.round(1),
         "mem" => tree |> Enum.map(& &1.mem) |> Enum.sum(),
         "top" => tree |> Enum.sort_by(& &1.cpu, :desc) |> Enum.take(5) |> Enum.map(& &1.name)
       }}
    end
  end

  defp tree(_children, [], found), do: found

  defp tree(children, [pid | rest], found) do
    kids = children |> Map.get(pid, []) |> Enum.map(& &1.pid) |> Enum.reject(&(&1 in found))
    tree(children, rest ++ kids, found ++ kids)
  end

  # --- volumes, battery, GPU ---------------------------------------------------------------

  defp volumes do
    OS.df()
    |> Enum.filter(fn v ->
      String.starts_with?(v["fs"], "/dev/") and not String.starts_with?(v["fs"], "/dev/loop")
    end)
    |> Enum.reject(fn v ->
      String.starts_with?(v["drive"], "/System/Volumes/") and v["drive"] != "/System/Volumes/Data"
    end)
    |> Enum.uniq_by(& &1["fs"])
  end

  defp battery do
    case OS.family() do
      :macos ->
        out = cmd("pmset", ["-g", "batt"])

        case Regex.run(~r/(\d+)%;\s*([^;]+);\s*(?:(\d+):(\d+) remaining)?/, out) do
          [_, pct, status | time] ->
            minutes =
              case time do
                [h, m] -> String.to_integer(h) * 60 + String.to_integer(m)
                _ -> nil
              end

            %{"charge" => String.to_integer(pct), "status" => String.trim(status), "minutes" => minutes}

          _ ->
            nil
        end

      _ ->
        case Path.wildcard("/sys/class/power_supply/BAT*") do
          [dir | _] ->
            %{
              "charge" => int(read(Path.join(dir, "capacity"))),
              "status" => read(Path.join(dir, "status")) |> String.trim() |> String.downcase(),
              "minutes" => nil
            }

          [] ->
            nil
        end
    end
  end

  defp nvidia_load do
    case nvidia(["utilization.gpu", "memory.used"]) do
      [[util, used] | _] ->
        %{
          "util" => float(util),
          "engines" => %{},
          "dedicated" => (int(used) || 0) * 1_048_576,
          "shared" => nil
        }

      _ ->
        %{"util" => nil, "engines" => %{}, "dedicated" => nil, "shared" => nil}
    end
  end

  defp nvidia(fields) do
    if System.find_executable("nvidia-smi") do
      cmd("nvidia-smi", ["--query-gpu=#{Enum.join(fields, ",")}", "--format=csv,noheader,nounits"])
      |> String.split("\n", trim: true)
      |> Enum.map(fn line -> line |> String.split(",") |> Enum.map(&String.trim/1) end)
    else
      []
    end
  end

  defp linux_gpus do
    case nvidia(["name", "driver_version", "memory.total"]) do
      [] ->
        if System.find_executable("lspci") do
          cmd("lspci", [])
          |> String.split("\n", trim: true)
          |> Enum.filter(&Regex.match?(~r/VGA|3D controller|Display controller/, &1))
          |> Enum.map(fn line ->
            %{"name" => line |> String.split(": ", parts: 2) |> List.last(), "driver" => nil}
          end)
        else
          []
        end

      rows ->
        for [name, driver, mem] <- rows,
            do: %{"name" => name, "driver" => driver, "adapterRAM" => (int(mem) || 0) * 1_048_576}
    end
  end

  defp macos_gpus do
    with out when out != "" <- cmd("system_profiler", ["SPDisplaysDataType", "-json"]),
         {:ok, %{"SPDisplaysDataType" => list}} <- JSON.decode(out) do
      for gpu <- list,
          do: %{
            "name" => gpu["sppci_model"] || gpu["_name"],
            "driver" => gpu["spdisplays_vendor"],
            "vram" => gpu["spdisplays_vram"]
          }
    else
      _ -> []
    end
  end

  defp linux_disks do
    if System.find_executable("lsblk") do
      cmd("lsblk", ["-dbno", "NAME,SIZE,ROTA,TRAN,MODEL"])
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case String.split(line, ~r/\s+/, parts: 5) do
          [name, size, rota, tran | model] ->
            if String.starts_with?(name, ["loop", "ram", "zram"]) do
              []
            else
              [
                %{
                  "name" => Enum.join(model, " ") |> String.trim() |> then(&if(&1 == "", do: name, else: &1)),
                  "media" => if(rota == "1", do: "HDD", else: "SSD"),
                  "bus" => tran,
                  "size" => int(size),
                  "health" => nil
                }
              ]
            end

          _ ->
            []
        end
      end)
    else
      []
    end
  end

  # --- helpers -----------------------------------------------------------------------------

  defp rate(baseline, key, value, elapsed) do
    result =
      case {baseline[key], elapsed} do
        {prev, e} when is_number(prev) and is_number(e) and value >= prev -> round((value - prev) / e)
        _ -> nil
      end

    {result, Map.put(baseline, key, value)}
  end

  defp iostat_bytes do
    # iostat -Id: cumulative KB/t, transfers and MB per disk since boot.
    lines = cmd("iostat", ["-Id"]) |> String.split("\n", trim: true)

    case lines do
      [_disks, _header, values | _] ->
        values
        |> String.split()
        |> Enum.chunk_every(3)
        |> Enum.map(fn chunk -> chunk |> List.last() |> float() end)
        |> Enum.sum()
        |> Kernel.*(1_048_576)
        |> round()

      _ ->
        0
    end
  end

  defp vm_stat do
    out = cmd("vm_stat", [])

    page =
      case Regex.run(~r/page size of (\d+) bytes/, out) do
        [_, p] -> String.to_integer(p)
        _ -> 4096
      end

    values =
      for line <- String.split(out, "\n"), [k, v] <- [String.split(line, ":", parts: 2)], into: %{} do
        {String.trim(k), int(v |> String.trim() |> String.trim_trailing("."))}
      end

    {values, page}
  end

  defp macos_boot do
    case Regex.run(~r/sec = (\d+)/, sysctl("kern.boottime") || "") do
      [_, s] -> s |> String.to_integer() |> DateTime.from_unix!() |> DateTime.to_iso8601()
      _ -> nil
    end
  end

  defp booted_at do
    case read("/proc/uptime") |> String.split() do
      [up | _] -> DateTime.utc_now() |> DateTime.add(-round(float(up)), :second) |> DateTime.to_iso8601()
      _ -> nil
    end
  end

  defp meminfo do
    for line <- String.split(read("/proc/meminfo"), "\n"),
        [k, v] <- [String.split(line, ":", parts: 2)],
        into: %{} do
      {k, (v |> String.trim() |> String.split() |> List.first() |> int() || 0) * 1024}
    end
  end

  defp os_release do
    for line <- String.split(read("/etc/os-release"), "\n"),
        [k, v] <- [String.split(line, "=", parts: 2)],
        into: %{} do
      {k, String.trim(v, "\"")}
    end
  end

  defp timezone do
    cond do
      (tz = String.trim(read("/etc/timezone"))) != "" ->
        tz

      match?({:ok, _}, File.read_link("/etc/localtime")) ->
        {:ok, link} = File.read_link("/etc/localtime")
        link |> String.split("zoneinfo/") |> List.last()

      true ->
        System.get_env("TZ")
    end
  end

  defp pwsh_version do
    if System.find_executable("pwsh"),
      do: cmd("pwsh", ["-NoProfile", "-Command", "$PSVersionTable.PSVersion.ToString()"]),
      else: nil
  end

  defp proc_count, do: ls("/proc") |> Enum.count(&Regex.match?(~r/^\d+$/, &1))

  defp cache_kb(level) do
    Path.wildcard("/sys/devices/system/cpu/cpu0/cache/index*")
    |> Enum.find(fn dir ->
      String.trim(read(Path.join(dir, "level"))) == "#{level}" and
        String.trim(read(Path.join(dir, "type"))) != "Instruction"
    end)
    |> case do
      nil -> nil
      dir -> read(Path.join(dir, "size")) |> String.trim() |> String.trim_trailing("K") |> int()
    end
  end

  defp dmi(name),
    do: read("/sys/devices/virtual/dmi/id/#{name}") |> String.trim() |> then(&if(&1 == "", do: nil, else: &1))

  defp field(text, key, sep \\ ":") do
    text
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case String.split(line, sep, parts: 2) do
        [k, v] -> if String.trim(k) == key, do: String.trim(v)
        _ -> nil
      end
    end)
  end

  defp kv(text, sep) do
    for line <- String.split(text, "\n"),
        [k, v] <- [String.split(line, sep, parts: 2)],
        into: %{},
        do: {k, String.trim(v)}
  end

  defp sysctl(name) do
    case cmd("sysctl", ["-n", name]) do
      "" -> nil
      value -> value
    end
  end

  defp host do
    {:ok, name} = :inet.gethostname()
    to_string(name)
  end

  defp read(path) do
    case File.read(path) do
      {:ok, text} -> text
      _ -> ""
    end
  end

  defp ls(path) do
    case File.ls(path) do
      {:ok, names} -> names
      _ -> []
    end
  end

  defp cmd(command, args) do
    if System.find_executable(command) do
      case System.cmd(command, args, stderr_to_stdout: false) do
        {out, 0} -> String.trim(out)
        _ -> ""
      end
    else
      ""
    end
  rescue
    _ -> ""
  end

  defp int(nil), do: nil

  defp int(text) when is_binary(text) do
    case Integer.parse(String.trim(text)) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp int(n) when is_integer(n), do: n

  defp float(nil), do: 0.0

  defp float(text) do
    case Float.parse(String.trim(text)) do
      {f, _} -> f
      :error -> 0.0
    end
  end
end
