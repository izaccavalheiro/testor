defmodule Testor.Config do
  @moduledoc "Paths of the data folder and the retention policy (defaults, overridden by config.json)."

  @defaults %{
    "screenshots" => %{"maxAgeDays" => 7, "maxTotalMB" => 1024},
    "runs" => %{"maxRuns" => 500, "maxAgeDays" => 30},
    "cleanupIntervalMinutes" => 30
  }

  def data_dir, do: Application.fetch_env!(:testor, :data_dir)

  @doc "The folder that holds one snapshot folder per project."
  def workspaces, do: Application.get_env(:testor, :workspaces, Path.dirname(data_dir()))

  @doc "The workspace folder's name, as it appears in remote command lines (`$HOME\\test-run\\x`)."
  def workspaces_name, do: Path.basename(workspaces())
  def runs_dir, do: Path.join(data_dir(), "runs")
  def logs_dir, do: Path.join(data_dir(), "logs")
  def shots_dir, do: Path.join(data_dir(), "screenshots")
  def run_file(id), do: Path.join(runs_dir(), id <> ".json")
  def log_file(id), do: Path.join(logs_dir(), id <> ".log")

  @doc "The retention policy; config.json in the data folder overrides any key of the defaults."
  def retention do
    user =
      with {:ok, text} <- File.read(Path.join(data_dir(), "config.json")),
           {:ok, map} when is_map(map) <- JSON.decode(strip_bom(text)) do
        map
      else
        _ -> %{}
      end

    Map.new(@defaults, fn
      {key, value} when is_map(value) -> {key, Map.merge(value, Map.get(user, key, %{}))}
      {key, value} -> {key, Map.get(user, key, value)}
    end)
  end

  def strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  def strip_bom(text), do: text
end
