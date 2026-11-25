defmodule Testor.Webhooks do
  @moduledoc """
  Webhooks: when a run ends, testor POSTs it to the endpoints in `webhooks.json` in the
  secrets folder (`TESTOR_SECRETS_DIR`, else the testor home), so CI, chat or a deploy pipeline
  hears of it without polling:

      {"endpoints": [
        {"url": "https://ci.example.com/hooks/testor", "secret": "<32+ random characters>",
         "events": ["run.finished"], "projects": ["my-app"]}
      ]}

  `events` (default every event) and `projects` (default every project) filter. The body:

      {"event": "run.finished", "id": "<delivery id>", "sentAt": "...",
       "run": {<the run, as /api/v1/runs/:id gives it>},
       "links": {"run": "/api/v1/runs/<id>", "attestation": "/api/v1/runs/<id>/attestation"}}

  Each request carries `X-Testor-Event`, `X-Testor-Delivery`, `X-Testor-Timestamp` (Unix
  seconds) and `X-Testor-Signature: sha256=<hex>`, the HMAC-SHA256 of `<timestamp>.<body>` keyed
  with the endpoint's secret: a receiver recomputes it, compares in constant time, and refuses
  timestamps older than a few minutes (replays). A delivery that does not get a 2xx answer in
  10 s is tried again after 1 s, 10 s and 60 s; HTTPS certificates are checked against the
  operating system's trusted roots.

  Endpoints are configured by whoever can write the secrets folder, never through the API, so
  the API cannot be used to make testor send requests elsewhere.
  """
  require Logger
  alias Testor.{Config, Query, Store}

  @backoff [1_000, 10_000, 60_000]
  @timeout 10_000

  def file, do: Path.join(Config.secrets_dir(), "webhooks.json")

  @doc "The endpoints, `[]` when there is no valid file."
  def endpoints do
    with {:ok, text} <- File.read(file()),
         {:ok, %{"endpoints" => list}} when is_list(list) <- JSON.decode(Config.strip_bom(text)) do
      for %{"url" => "http" <> _ = url, "secret" => secret} = endpoint <- list,
          is_binary(secret) and byte_size(secret) >= 16 do
        %{
          url: url,
          secret: secret,
          events: endpoint["events"],
          projects: endpoint["projects"]
        }
      end
    else
      {:error, :enoent} ->
        []

      _ ->
        Logger.error("webhooks: #{file()} is not valid: no webhook is sent")
        []
    end
  end

  @doc "Sends `event` about run `id` to every endpoint that wants it, each in a task of its own."
  def notify(event, id) do
    case Store.get(id) do
      nil ->
        :ok

      run ->
        for endpoint <- endpoints(), wants?(endpoint, event, run["project"]) do
          Task.Supervisor.start_child(Testor.TaskSupervisor, fn -> deliver(endpoint, event, run) end)
        end

        :ok
    end
  end

  defp wants?(endpoint, event, project) do
    (endpoint.events == nil or event in endpoint.events) and
      (endpoint.projects == nil or project in endpoint.projects)
  end

  @doc "The body of `event` about `run`."
  def payload(event, run) do
    id = run["id"]

    %{
      "event" => event,
      "id" => Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
      "sentAt" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "run" => Query.compact(run),
      "links" => %{
        "run" => "/api/v1/runs/#{id}",
        "attestation" => "/api/v1/runs/#{id}/attestation"
      }
    }
  end

  @doc "`sha256=<hex>`: the HMAC-SHA256 of `<timestamp>.<body>` with `secret`."
  def signature(secret, timestamp, body) do
    "sha256=" <> (:crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{body}") |> Base.encode16(case: :lower))
  end

  @doc "Delivers one event, trying again on failure: `:ok` or `{:error, reason}` after the last try."
  def deliver(endpoint, event, run) do
    payload = payload(event, run)
    body = JSON.encode!(payload)
    backoff = Application.get_env(:testor, :webhook_backoff_ms, @backoff)
    attempt(endpoint, event, payload["id"], body, backoff)
  end

  defp attempt(endpoint, event, delivery, body, backoff) do
    timestamp = System.os_time(:second)

    headers = [
      {~c"user-agent", ~c"testor/#{Application.spec(:testor, :vsn)}"},
      {~c"x-testor-event", String.to_charlist(event)},
      {~c"x-testor-delivery", String.to_charlist(delivery)},
      {~c"x-testor-timestamp", ~c"#{timestamp}"},
      {~c"x-testor-signature", String.to_charlist(signature(endpoint.secret, timestamp, body))}
    ]

    request = {String.to_charlist(endpoint.url), headers, ~c"application/json", body}

    case :httpc.request(:post, request, http_options(), body_format: :binary) do
      {:ok, {{_, status, _}, _, _}} when status in 200..299 ->
        :ok

      other ->
        reason = failure(other)

        case backoff do
          [wait | rest] ->
            Logger.warning("webhooks: #{endpoint.url}: #{reason}; trying again in #{wait} ms")
            Process.sleep(wait)
            attempt(endpoint, event, delivery, body, rest)

          [] ->
            Logger.error("webhooks: #{endpoint.url}: #{reason}; giving up on #{event} #{delivery}")
            {:error, reason}
        end
    end
  end

  defp failure({:ok, {{_, status, _}, _, _}}), do: "answered #{status}"
  defp failure({:error, reason}), do: "failed (#{inspect(reason)})"

  @doc "HTTP options: a timeout, and for HTTPS the certificate checked against the system's roots."
  def http_options do
    [
      timeout: @timeout,
      connect_timeout: @timeout,
      autoredirect: false,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 4,
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]
  end
end
