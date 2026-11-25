defmodule Testor.Views do
  @moduledoc "The JSON documents the API and the SSE snapshots send."
  alias Testor.{Auth, Config, Device, Files, RunTracker, Sessions, Stats, Store}

  @log_snapshot 262_144

  @doc "Liveness; versions and paths only for a caller with the read scope."
  def health(principal) do
    base = %{
      "ok" => true,
      "app" => "testor",
      "version" => to_string(Application.spec(:testor, :vsn)),
      "auth" => Auth.enabled?()
    }

    if principal != nil and "read" in principal.scopes do
      Map.merge(base, %{
        "home" => Config.data_dir(),
        "elixir" => System.version(),
        "otp" => System.otp_release(),
        "uptimeMs" => :erlang.statistics(:wall_clock) |> elem(0),
        "os_pid" => System.pid()
      })
    else
      base
    end
  end

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

  @doc "A run, its specs, screenshots, artifacts and the end of its log, with the log offset it reaches."
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
          "run" =>
            run
            |> Store.with_live()
            |> Map.put("attested", Testor.Attestation.exists?(id))
            |> Map.put("archived", Testor.Archive.archived?(id))
            |> Map.put("agentAttested", File.regular?(Testor.Remote.agent_file(id))),
          "specs" => Store.with_shot_counts(specs, shots),
          "screenshots" => shots,
          "artifacts" => Files.artifacts(id),
          "log" => log.text,
          "logBytes" => log.size,
          "truncated" => log.truncated
        }
    end
  end

  @doc "Every screenshot, newest first, with its run."
  def screenshots_all do
    shots = Config.shots_dir()

    Enum.flat_map(Files.ls(shots), fn name ->
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
              "url" => Auth.file_prefix(name) <> "/shots/" <> URI.encode(name, &URI.char_unreserved?/1),
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

  @doc "Every run that kept artifacts, newest first: the run and its artifacts."
  def artifacts_all do
    Config.artifacts_dir()
    |> Files.ls()
    |> Enum.filter(&File.dir?(Path.join(Config.artifacts_dir(), &1)))
    |> Enum.sort(:desc)
    |> Enum.flat_map(fn id ->
      case Files.artifacts(id) do
        [] ->
          []

        list ->
          run = Store.get(id) || %{}

          [
            %{
              "runId" => id,
              "project" => run["project"],
              "kind" => run["kind"],
              "status" => run["status"],
              "startedAt" => run["startedAt"],
              "artifacts" => list
            }
          ]
      end
    end)
  end

  def host do
    {:ok, name} = :inet.gethostname()
    to_string(name)
  end
end
