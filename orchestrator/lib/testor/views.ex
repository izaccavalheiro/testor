defmodule Testor.Views do
  @moduledoc "The JSON documents the API and the SSE snapshots send."
  alias Testor.{Config, Device, Files, RunTracker, Sessions, Stats, Store}

  @log_snapshot 262_144

  def state do
    {running, history} = Enum.split_with(Store.all(), &(&1["status"] == "running"))

    %{
      "host" => host(),
      "now" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "running" => Enum.map(running, &Store.with_live/1),
      "history" => Enum.take(history, 1000),
      "sessions" => Sessions.list(),
      "stats" => Stats.get(),
      "device" => Device.snapshot(),
      "config" => Config.retention(),
      "paths" => %{"home" => Config.data_dir(), "workspaces" => Config.workspaces()}
    }
  end

  @doc "A run, its specs, screenshots and the end of its log, with the log offset it reaches."
  def run_snapshot(id) do
    case Store.get(id) do
      nil ->
        nil

      run ->
        live = if run["status"] == "running", do: RunTracker.snapshot(id)

        {specs, log} =
          case live do
            %{specs: specs, log: text, offset: offset, truncated: truncated} ->
              {specs, %{text: text, size: offset, truncated: truncated}}

            nil ->
              {Files.log_specs(id), Files.tail(Config.log_file(id), @log_snapshot)}
          end

        shots = Files.screenshots(id, specs)

        %{
          "run" => Store.with_live(run),
          "specs" => Store.with_shot_counts(specs, shots),
          "screenshots" => shots,
          "log" => log.text,
          "logBytes" => log.size,
          "truncated" => log.truncated
        }
    end
  end

  @doc "Every screenshot, newest first, with its run."
  def screenshots_all do
    shots = Config.shots_dir()

    entries =
      case File.ls(shots) do
        {:ok, names} -> names
        _ -> []
      end

    Enum.flat_map(entries, fn name ->
      path = Path.join(shots, name)

      cond do
        File.dir?(path) ->
          run = Store.get(name)
          specs = if run, do: Files.log_specs(name), else: []

          for shot <- Files.screenshots(name, specs) do
            Map.merge(shot, %{
              "runId" => name,
              "project" => run && run["project"],
              "kind" => run && run["kind"],
              "status" => run && run["status"]
            })
          end

        Files.image_type(name) ->
          [
            %{
              "path" => name,
              "url" => "/shots/" <> URI.encode(name, &URI.char_unreserved?/1),
              "bytes" => Files.size(path),
              "takenAt" => path |> Files.mtime() |> Files.iso(),
              "spec" => nil,
              "runId" => nil,
              "project" => nil,
              "kind" => nil,
              "status" => nil
            }
          ]

        true ->
          []
      end
    end)
    |> Enum.sort_by(& &1["takenAt"], :desc)
  end

  def host do
    {:ok, name} = :inet.gethostname()
    to_string(name)
  end
end
