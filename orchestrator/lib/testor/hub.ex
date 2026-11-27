defmodule Testor.Hub do
  @moduledoc """
  The hub: one testor showing the board of others (each team's, each site's, each runner's),
  each with its latest result per project and task and a link back to it.

  `hub.json` in the secrets folder (it holds tokens: never set through the API):

      {"intervalSeconds": 15,
       "testors": [
         {"name": "windows-farm", "url": "https://testor-win.example.com", "token": "eyJ...",
          "labels": ["windows", "gpu"]},
         {"name": "lab", "url": "http://lab-runner:6767", "tokenEnv": "LAB_TESTOR_TOKEN",
          "labels": ["linux"], "allowHttp": true}]}

  A token is a read token of a user on that testor (`task testor:token SCOPE=read`), ideally one
  limited to the projects the hub shows. URLs are `https` (their certificates checked), or
  `http` on loopback, or with `allowHttp` for a private network (Tailscale, a LAN): the token
  travels in clear there. Each testor is asked for its projects every `intervalSeconds` (15,
  at least 5), at most 10 seconds for both its answers; one that does not answer shows why, and the others
  are not held up.
  """
  use GenServer
  require Logger
  alias Testor.{Config, Webhooks}

  @name ~r/^[A-Za-z0-9_.-]{1,64}$/

  def file, do: Path.join(Config.secrets_dir(), "hub.json")

  @doc "The testors of hub.json, checked; those that are not valid are left out (logged)."
  def config do
    with {:ok, text} <- File.read(file()),
         {:ok, %{"testors" => [_ | _] = testors} = raw} <- JSON.decode(Config.strip_bom(text)) do
      interval = if is_integer(raw["intervalSeconds"]), do: max(raw["intervalSeconds"], 5), else: 15
      %{interval: interval, testors: testors |> Enum.map(&check/1) |> Enum.reject(&is_nil/1)}
    else
      _ -> nil
    end
  end

  defp check(%{"name" => name, "url" => url} = raw) when is_binary(name) and is_binary(url) do
    token =
      case raw["tokenEnv"] do
        env when is_binary(env) -> System.get_env(env)
        _ -> raw["token"]
      end

    http_ok = raw["allowHttp"] == true and Testor.Auth.OIDC.url?(url)

    cond do
      not Regex.match?(@name, name) ->
        skip(name, "a name is letters, digits, _ . -")

      not (Testor.Auth.OIDC.secure_url?(url) or http_ok) ->
        skip(name, "its url is https (or http with allowHttp)")

      not (is_binary(token) and token != "") ->
        skip(name, "it has no token")

      true ->
        %{name: name, url: String.trim_trailing(url, "/"), token: token, labels: labels(raw["labels"])}
    end
  end

  defp check(raw), do: skip(inspect(raw), "a testor has a name and a url")

  defp skip(name, why) do
    Logger.warning("hub: #{name} is left out: #{why}")
    nil
  end

  defp labels(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp labels(_), do: []

  # --- the board -----------------------------------------------------------------------------

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The testors as last asked, `nil` when no hub is set up; with `label`, those that have it."
  def board(label \\ nil) do
    case GenServer.call(__MODULE__, :board) do
      nil -> nil
      testors -> Enum.filter(testors, &(label in [nil, ""] or label in &1["labels"]))
    end
  end

  @doc "Asks every testor now and waits for the answers (the timer does it every interval)."
  def refresh, do: GenServer.call(__MODULE__, :refresh, 60_000)

  @impl true
  def init(nil) do
    send(self(), :poll)
    {:ok, %{board: nil}}
  end

  @impl true
  def handle_call(:board, _from, state), do: {:reply, state.board, state}
  def handle_call(:refresh, _from, _state), do: {:reply, :ok, %{board: poll()}}

  @impl true
  def handle_info(:poll, _state) do
    board = poll()
    interval = (config() || %{interval: 60}).interval
    Process.send_after(self(), :poll, interval * 1000)
    {:noreply, %{board: board}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp poll do
    case config() do
      nil ->
        nil

      %{testors: testors} ->
        testors
        |> Task.async_stream(&ask/1, timeout: timeout() + 100, on_timeout: :kill_task, ordered: true)
        |> Enum.zip(testors)
        |> Enum.map(fn
          {{:ok, answer}, _testor} -> answer
          {{:exit, _}, testor} -> entry(testor, {:error, "it did not answer in time"})
        end)
    end
  end

  defp ask(testor) do
    with {:ok, health} <- get(testor, "/api/v1/health"),
         {:ok, %{"data" => projects}} when is_list(projects) <- get(testor, "/api/v1/projects") do
      entry(testor, {:ok, health["version"], Enum.map(projects, &project(&1, testor.url))})
    else
      {:ok, _} -> entry(testor, {:error, "its projects are not a list"})
      {:error, why} -> entry(testor, {:error, why})
    end
  end

  defp project(project, url) do
    latest = project["latest"] || %{}

    %{
      "project" => project["project"],
      "kind" => project["kind"],
      "status" => latest["status"],
      "runId" => latest["id"],
      "endedAt" => latest["endedAt"],
      "recent" => project["recent"] || [],
      "link" => if(is_binary(latest["id"]), do: "#{url}/#/run/#{URI.encode_www_form(latest["id"])}")
    }
  end

  defp entry(testor, answer) do
    base = %{
      "name" => testor.name,
      "url" => testor.url,
      "labels" => testor.labels,
      "checkedAt" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }

    case answer do
      {:ok, version, projects} ->
        Map.merge(base, %{"ok" => true, "version" => version, "projects" => projects})

      {:error, why} ->
        Map.merge(base, %{"ok" => false, "error" => why, "projects" => []})
    end
  end

  defp timeout, do: Application.get_env(:testor, :hub_timeout_ms, 10_000)

  defp get(testor, path) do
    headers = [
      {~c"authorization", String.to_charlist("Bearer " <> testor.token)},
      {~c"accept", ~c"application/json"}
    ]

    options = Keyword.merge(Webhooks.http_options(), timeout: timeout(), connect_timeout: timeout())

    case :httpc.request(:get, {String.to_charlist(testor.url <> path), headers}, options,
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _, body}} ->
        case JSON.decode(body) do
          {:ok, doc} -> {:ok, doc}
          _ -> {:error, "#{path} did not answer JSON"}
        end

      {:ok, {{_, status, _}, _, _}} ->
        {:error, "#{path} answered #{status}"}

      {:error, reason} ->
        {:error, "it cannot be reached (#{unreachable(reason)})"}
    end
  end

  @doc false
  # Why a testor did not answer, in words (the dashboard shows it).
  def unreachable({:failed_connect, info}) when is_list(info) do
    case List.keyfind(info, :inet, 0) || List.keyfind(info, :inet6, 0) do
      {_, _, reason} -> unreachable(reason)
      _ -> "the connection failed"
    end
  end

  def unreachable(:econnrefused), do: "connection refused"
  def unreachable(:timeout), do: "no answer in time"
  def unreachable(:nxdomain), do: "unknown host"
  def unreachable(:ehostunreach), do: "host unreachable"
  def unreachable(reason), do: inspect(reason)
end
