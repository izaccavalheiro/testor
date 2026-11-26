defmodule Testor.CgroupTest do
  @moduledoc "Container limits from cgroup files: v2, v1, unlimited, missing; job timeouts; jobs per label."
  use ExUnit.Case, async: false
  alias Testor.Device.Unix

  @moduletag :tmp_dir

  defp files(dir, map) do
    for {name, text} <- map do
      path = Path.join(dir, name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, text)
    end

    dir
  end

  test "cgroup v2: quota and limit, usage, peak and OOM kills", %{tmp_dir: dir} do
    root =
      files(dir, %{
        "cgroup.controllers" => "cpu memory\n",
        "cpu.max" => "200000 100000\n",
        "memory.max" => "536870912\n",
        "memory.current" => "104857600\n",
        "memory.peak" => "209715200\n",
        "memory.events" => "low 0\nhigh 0\nmax 3\noom 1\noom_kill 1\n"
      })

    assert Unix.cgroup_limits(root) == %{"cpus" => 2.0, "memory" => 536_870_912}

    assert Unix.cgroup_usage(root) == %{
             "cgroupCurrent" => 104_857_600,
             "cgroupPeak" => 209_715_200,
             "oomKills" => 1
           }
  end

  test "cgroup v2 without limits, v1 with and without, none", %{tmp_dir: dir} do
    v2 =
      files(Path.join(dir, "v2"), %{
        "cgroup.controllers" => "",
        "cpu.max" => "max 100000\n",
        "memory.max" => "max\n"
      })

    assert Unix.cgroup_limits(v2) == nil
    assert Unix.cgroup_usage(v2) == %{}

    v1 =
      files(Path.join(dir, "v1"), %{
        "cpu/cpu.cfs_quota_us" => "150000\n",
        "cpu/cpu.cfs_period_us" => "100000\n",
        "memory/memory.limit_in_bytes" => "1073741824\n",
        "memory/memory.usage_in_bytes" => "1024\n",
        "memory/memory.max_usage_in_bytes" => "2048\n"
      })

    assert Unix.cgroup_limits(v1) == %{"cpus" => 1.5, "memory" => 1_073_741_824}
    assert Unix.cgroup_usage(v1) == %{"cgroupCurrent" => 1024, "cgroupPeak" => 2048}

    open =
      files(Path.join(dir, "open"), %{
        "cpu/cpu.cfs_quota_us" => "-1\n",
        "memory/memory.limit_in_bytes" => "9223372036854771712\n"
      })

    assert Unix.cgroup_limits(open) == nil
    assert Unix.cgroup_limits(Path.join(dir, "none")) == nil
  end

  test "a job's timeout: seconds or 90s, 45m, 2h, at most a day" do
    alias Testor.Jobs
    assert Jobs.seconds(nil) == nil
    assert Jobs.seconds(600) == 600
    assert Jobs.seconds("90s") == 90
    assert Jobs.seconds("45m") == 2700
    assert Jobs.seconds("2h") == 7200
    assert Jobs.seconds("120") == 120
    assert Jobs.seconds(0) == :error
    assert Jobs.seconds("25h") == :error
    assert Jobs.seconds("1d") == :error
    assert Jobs.seconds(1.5) == :error

    config = Path.join(Testor.Config.data_dir(), "config.json")
    File.write!(config, JSON.encode!(%{"execution" => %{"enabled" => true, "defaultTimeout" => "30m"}}))
    Jobs.reset()

    on_exit(fn ->
      Jobs.reset()
      File.rm(config)
    end)

    assert {:ok, %{"timeout" => 1800}} = Jobs.enqueue(%{"project" => "p", "kind" => "k"}, "ada")

    assert {:ok, %{"timeout" => 60, "labels" => ["mutation"]}} =
             Jobs.enqueue(
               %{"project" => "p", "kind" => "k", "timeout" => "1m", "labels" => ["mutation"]},
               "ada"
             )

    assert {:error, "timeout is" <> _} =
             Jobs.enqueue(%{"project" => "p", "kind" => "k", "timeout" => "forever"}, "ada")

    metrics = IO.iodata_to_binary(Testor.Metrics.render())
    assert metrics =~ ~s(testor_jobs{status="queued"} 2)
    assert metrics =~ ~s(testor_jobs{label="mutation",status="queued"} 1)

    File.write!(config, JSON.encode!(%{"execution" => %{"enabled" => true, "defaultTimeout" => "never"}}))
    assert {:ok, job} = Jobs.enqueue(%{"project" => "p", "kind" => "k"}, "ada")
    refute Map.has_key?(job, "timeout")
  end
end
