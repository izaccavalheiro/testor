defmodule Testor.Web.ApiV1 do
  @moduledoc """
  The versioned API, `/api/v1`: stable paths and shapes for scripts, CI and other programs,
  described by `GET /api/v1/openapi.json` (OpenAPI 3.1). Collections answer
  `{"data": [...]}` (with `"next"` where they page), errors `{"error": {"code", "message"}}`,
  except the token endpoint, which answers errors as OAuth 2.0 does (RFC 6749, 5.2).

  The dashboard keeps its own routes (`/api/*`, `/events`); both read the same data.
  """
  use Plug.Router
  import Testor.Web.Reply
  alias Testor.{Auth, Device, Janitor, Jobs, Maintenance, Query, Remote, Sessions, Stats, Views}
  alias Testor.Web.{Actions, OpenAPI, SSE}

  plug(:match)
  plug(:dispatch)

  get "/health" do
    json(conn, 200, Views.health(conn.assigns[:principal]))
  end

  get "/openapi.json" do
    json(conn, 200, OpenAPI.spec())
  end

  # --- authentication ------------------------------------------------------------------------

  # The OAuth 2.0 client credentials grant (RFC 6749, 4.4) with the user's Basic credentials.
  post "/auth/token" do
    settings = Auth.settings()

    with true <- settings.enabled || {:off, conn},
         {:ok, params, conn} <- body_params(conn),
         true <- params["grant_type"] in [nil, "client_credentials"] || {:grant, conn} do
      case Auth.issue_token(conn.assigns.principal, params, settings) do
        {:ok, token} ->
          conn |> put_resp_header("pragma", "no-cache") |> json(200, token)

        {:error, :invalid_client} ->
          conn
          |> put_resp_header("www-authenticate", ~s(Basic realm="testor", charset="UTF-8"))
          |> oauth_error(
            401,
            "invalid_client",
            "a token is obtained with Basic credentials, not with a token"
          )

        {:error, :invalid_scope} ->
          oauth_error(conn, 400, "invalid_scope", "scope must be a non-empty subset of the user's scopes")

        {:error, :invalid_request} ->
          oauth_error(conn, 400, "invalid_request", "expires_in must be a number of seconds, 60 or more")
      end
    else
      {:off, conn} ->
        oauth_error(conn, 400, "invalid_request", "authentication is off: there are no tokens")

      {:grant, conn} ->
        oauth_error(conn, 400, "unsupported_grant_type", "only client_credentials is supported")

      {:error, conn} ->
        conn
    end
  end

  get "/auth/me" do
    principal = conn.assigns.principal

    json(conn, 200, %{
      "authEnabled" => principal.via != :none,
      "user" => principal.sub,
      "via" => to_string(principal.via),
      "scopes" => principal.scopes,
      # The projects this principal may see; null for every project.
      "projects" => Testor.Access.projects(principal),
      # A role per project, when the user has one: {"web*": "operator"}.
      "projectRoles" =>
        case Testor.Access.project_roles(principal) do
          nil -> nil
          roles -> Map.new(roles, &{&1.pattern, &1.role})
        end,
      "expiresAt" => principal[:exp]
    })
  end

  # --- runs ----------------------------------------------------------------------------------

  get "/runs" do
    conn = fetch_query_params(conn)

    case run_filters(conn.query_params) do
      {:ok, opts} ->
        principal = conn.assigns.principal
        {runs, next} = Query.runs(Map.put(opts, :allow, &Testor.Access.allowed?(principal, &1)))
        json(conn, 200, %{"data" => runs, "next" => next})

      {:error, message} ->
        error(conn, 400, "bad_request", message)
    end
  end

  get "/runs/:id" do
    with_id(conn, id, fn conn ->
      case Views.run_snapshot(id) do
        nil ->
          error(conn, 404, "not_found", "no such run")

        snapshot ->
          snapshot = snapshot |> Map.drop(["log", "truncated"]) |> Map.update!("run", &Query.compact/1)
          json(conn, 200, snapshot)
      end
    end)
  end

  # ?by=agent: the attestation the agent that ran it signed (runs from other machines).
  get "/runs/:id/report.junit.xml" do
    export(conn, id, "application/xml", &Testor.Reports.Export.junit/2)
  end

  get "/runs/:id/report.ctrf.json" do
    export(conn, id, "application/json", &(&1 |> Testor.Reports.Export.ctrf(&2) |> JSON.encode!()))
  end

  get "/runs/:id/attestation" do
    with_id(conn, id, fn conn ->
      conn = fetch_query_params(conn)
      Testor.Storage.local(id)

      file =
        if conn.query_params["by"] == "agent", do: Remote.agent_file(id), else: Testor.Attestation.file(id)

      case Testor.Files.read_json(file) do
        {:ok, envelope} ->
          json(conn, 200, envelope)

        :error ->
          error(
            conn,
            404,
            "not_found",
            "no attestation: the run is unknown, still running, or not signed yet"
          )
      end
    end)
  end

  # The spec files that fail, take and retry most (Testor.Query.hotspots/3).
  get "/projects/:project/hotspots" do
    conn = fetch_query_params(conn)
    limit = int(conn.query_params["limit"], 200, 1, 1000)
    json(conn, 200, %{"data" => Query.hotspots(project, conn.query_params["kind"], limit)})
  end

  get "/projects/:project/flaky" do
    conn = fetch_query_params(conn)
    json(conn, 200, %{"data" => Query.flaky(project, conn.query_params["kind"])})
  end

  # The latest result as an SVG badge (Testor.Badge); public for config.json's publicBadges.
  get "/projects/:project/badge.svg" do
    conn = fetch_query_params(conn)

    conn
    |> put_resp_content_type("image/svg+xml")
    # Badges are fetched through caching proxies (GitHub's camo): always ask again.
    |> put_resp_header("cache-control", "no-cache, max-age=0")
    |> put_resp_header("content-security-policy", "default-src 'none'; style-src 'unsafe-inline'")
    |> send_resp(200, Testor.Badge.svg(project, conn.query_params["kind"], conn.query_params["metric"]))
  end

  # DORA's four metrics of the runs of the task that delivers the project (Testor.Dora).
  get "/projects/:project/dora" do
    conn = fetch_query_params(conn)
    kind = conn.query_params["kind"] || "deploy"
    days = int(conn.query_params["days"], 30, 1, 365)
    json(conn, 200, Testor.Dora.metrics(project, kind, days))
  end

  get "/audit" do
    conn = fetch_query_params(conn)
    limit = int(conn.query_params["limit"], 100, 1, 1000)
    # Entries first: reading them waits for those still being written, so the check below
    # covers the same file.
    entries = Testor.Audit.tail(limit)
    {public, _} = Testor.Attestation.keypair()

    verified =
      case Testor.Audit.verify(public) do
        {:ok, entries} -> %{"ok" => true, "entries" => entries}
        {:error, line, reason} -> %{"ok" => false, "line" => line, "reason" => to_string(reason)}
      end

    json(conn, 200, %{"entries" => entries, "verified" => verified})
  end

  get "/agents" do
    json(conn, 200, %{
      "data" => Testor.AgentKeys.all() |> Enum.map(fn {name, key} -> Map.put(key, "agent", name) end)
    })
  end

  put "/agent/jobs/:id/attestation" do
    with_agent(conn, id, fn conn, agent ->
      case body_params(conn, 1_048_576) do
        {:ok, envelope, conn} -> id |> Remote.attest(agent, envelope) |> remote_reply(conn)
        {:error, conn} -> conn
      end
    end)
  end

  get "/attestation/key" do
    json(conn, 200, Testor.Attestation.public_key())
  end

  get "/runs/:id/log" do
    with_id(conn, id, fn conn ->
      conn = fetch_query_params(conn)
      params = conn.query_params
      tail = int(params["tail"], 512 * 1024, 1, Testor.Query.max_tail())
      context = int(params["context"], 0, 0, 20)
      log = Query.log(id, tail, params["grep"], context)

      conn
      |> put_resp_header("x-log-size", to_string(log.size))
      |> put_resp_header("x-log-truncated", to_string(log.truncated))
      |> then(&if(log.matches, do: put_resp_header(&1, "x-log-matches", to_string(log.matches)), else: &1))
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_content_type("text/plain")
      |> send_resp(200, log.text)
    end)
  end

  get "/runs/:id/events" do
    with_id(conn, id, &SSE.run(&1, id))
  end

  post "/runs/:id/cancel" do
    with_id(conn, id, &reply(&1, Actions.cancel(id), 200))
  end

  delete "/runs/:id" do
    with_id(conn, id, &reply(&1, Actions.delete(id), 200))
  end

  # --- the rest ------------------------------------------------------------------------------

  get "/events" do
    SSE.global(conn)
  end

  get "/projects" do
    json(conn, 200, %{"data" => Testor.Access.filter(Query.projects(), conn.assigns.principal)})
  end

  get "/sessions" do
    json(conn, 200, %{"data" => Sessions.list()})
  end

  get "/stats" do
    json(conn, 200, Stats.get())
  end

  get "/device" do
    json(conn, 200, Device.snapshot())
  end

  get "/screenshots" do
    json(conn, 200, %{"data" => Testor.Access.filter(Views.screenshots_all(), conn.assigns.principal)})
  end

  get "/artifacts" do
    json(conn, 200, %{"data" => Testor.Access.filter(Views.artifacts_all(), conn.assigns.principal)})
  end

  post "/cleanup" do
    json(conn, 200, Janitor.run("api"))
  end

  get "/maintenance" do
    json(conn, 200, Maintenance.state())
  end

  post "/maintenance/scan" do
    json(conn, 202, Maintenance.scan())
  end

  post "/maintenance/clean" do
    case body_params(conn) do
      {:ok, params, conn} -> reply(conn, Actions.maintenance_clean(params), 202)
      {:error, conn} -> conn
    end
  end

  # --- jobs and agents (Testor.Jobs) ---------------------------------------------------------

  get "/jobs" do
    conn = fetch_query_params(conn)
    status = conn.query_params["status"]

    if status in [nil | Jobs.statuses()],
      do: json(conn, 200, %{"data" => Testor.Access.filter(Jobs.list(status), conn.assigns.principal)}),
      else: error(conn, 400, "bad_request", "status is one of #{Enum.join(Jobs.statuses(), ", ")}")
  end

  get "/jobs/:id" do
    with_id(conn, id, fn conn ->
      case Jobs.get(id) do
        nil -> error(conn, 404, "not_found", "no such job")
        job -> json(conn, 200, job)
      end
    end)
  end

  # Approvals of what AI agents ask for (Testor.Approvals).
  get "/approvals" do
    conn = fetch_query_params(conn)
    list = Testor.Approvals.list(conn.query_params["status"])
    json(conn, 200, %{"data" => Testor.Access.filter(list, conn.assigns.principal)})
  end

  get "/approvals/:id" do
    case Testor.Approvals.get(id) do
      %{} = approval ->
        if Testor.Access.allowed?(conn.assigns.principal, approval["project"]),
          do: json(conn, 200, approval),
          else: error(conn, 404, "not_found", "no approval #{id}")

      nil ->
        error(conn, 404, "not_found", "no approval #{id}")
    end
  end

  post "/approvals/:id/:decision" when decision in ["approve", "deny"] do
    case Testor.Approvals.decide(
           id,
           conn.assigns.principal,
           if(decision == "approve", do: :approve, else: :deny)
         ) do
      {:ok, approval} ->
        json(conn, 200, approval)

      {:error, :not_found} ->
        error(conn, 404, "not_found", "no approval #{id}")

      {:error, :decided} ->
        error(conn, 409, "decided", "this approval is no longer pending")

      {:error, :own} ->
        error(conn, 403, "own_request", "someone other than who asked must decide")

      {:error, {:forbidden, scope}} ->
        error(conn, 403, "forbidden", "deciding needs the #{scope} scope on its project")
    end
  end

  # The board of other testors (Testor.Hub), each with the projects one may see.
  get "/hub" do
    conn = fetch_query_params(conn)

    case Testor.Hub.board(conn.query_params["label"]) do
      nil ->
        error(conn, 404, "not_found", "no hub: list testors in hub.json")

      testors ->
        principal = conn.assigns.principal

        data =
          Enum.map(
            testors,
            &Map.update!(&1, "projects", fn list -> Testor.Access.filter(list, principal) end)
          )

        json(conn, 200, %{"data" => data})
    end
  end

  # Release gates (Testor.Gates): whether a commit may ship, from signed results.
  get "/gates" do
    json(conn, 200, %{"data" => Testor.Access.filter(Testor.Gates.list(), conn.assigns.principal)})
  end

  get "/gates/:name" do
    conn = fetch_query_params(conn)

    with {:ok, gate} <- Testor.Gates.get(name),
         true <- Testor.Access.allowed?(conn.assigns.principal, gate["project"]) || {:error, :not_found},
         {:ok, result} <- Testor.Gates.evaluate(gate, conn.query_params["commit"]) do
      json(conn, 200, result)
    else
      {:error, :not_found} -> error(conn, 404, "not_found", "no gate #{name}")
      {:error, why} -> error(conn, 400, "bad_request", why)
    end
  end

  # config.json's schedules (Testor.Schedules), each with its next time, of the projects one sees.
  get "/schedules" do
    json(conn, 200, %{"data" => Testor.Access.filter(Testor.Schedules.list(), conn.assigns.principal)})
  end

  post "/jobs" do
    with {:ok, who} <- signed_in(conn),
         {:ok, params, conn} <- body_params(conn) do
      case if(Testor.Access.permits?(conn.assigns.principal, params["project"], "execute"),
             do: Jobs.enqueue(params, who),
             else: {:error, :not_allowed}
           ) do
        {:error, :not_allowed} ->
          error(conn, 403, "forbidden", "#{who} has no access to that project")

        {:ok, job} ->
          json(conn, 201, job)

        {:error, :disabled} ->
          error(conn, 403, "execution_disabled", "jobs are off: set execution.enabled in config.json")

        {:error, :queue_unavailable} ->
          conn
          |> put_resp_header("retry-after", "10")
          |> error(503, "queue_unavailable", "the job queue's broker did not take the job; try again")

        {:error, message} ->
          error(conn, 400, "bad_request", message)
      end
    else
      {:error, conn} -> conn
    end
  end

  post "/jobs/:id/cancel" do
    with_id(conn, id, fn conn ->
      case Jobs.cancel(id) do
        {:ok, job} -> json(conn, 200, job)
        {:error, :not_found} -> error(conn, 404, "not_found", "no such job")
        {:error, :ended} -> error(conn, 409, "ended", "the job has ended")
      end
    end)
  end

  # An agent waits up to `wait` seconds (25 at most) for a job it can take: 200 with the job,
  # or 204 when there is none.
  post "/agent/lease" do
    with {:ok, agent} <- signed_in(conn),
         {:ok, params, conn} <- body_params(conn),
         :ok <- pin_key(conn, agent, params["key"]) do
      labels = if is_list(params["labels"]), do: Enum.filter(params["labels"], &is_binary/1), else: []
      wait = if is_integer(params["wait"]), do: params["wait"] |> max(0) |> min(25), else: 0
      deadline = System.monotonic_time(:millisecond) + wait * 1000

      case wait_for_job(agent, labels, deadline, conn.assigns.principal) do
        {:ok, job} -> json(conn, 200, job)
        :none -> send_resp(conn, 204, "")
      end
    else
      {:error, conn} -> conn
    end
  end

  post "/agent/jobs/:id/heartbeat" do
    with_agent(conn, id, fn conn, agent -> Jobs.heartbeat(id, agent) |> agent_reply(conn) end)
  end

  post "/agent/jobs/:id/finish" do
    with_agent(conn, id, fn conn, agent ->
      case body_params(conn) do
        {:ok, params, conn} -> Jobs.finish(id, agent, params) |> agent_reply(conn)
        {:error, conn} -> conn
      end
    end)
  end

  # An identity token for the job (Testor.Auth.JobTokens), to trade for cloud credentials.
  post "/agent/jobs/:id/token" do
    with_agent(conn, id, fn conn, agent ->
      with {:ok, params, conn} <- body_params(conn),
           {:ok, job} <- Jobs.held(id, agent) do
        case Testor.Auth.JobTokens.issue(Testor.Auth.settings(), job, agent, params["audience"]) do
          {:ok, token} ->
            json(conn, 200, token)

          {:error, :audience} ->
            error(conn, 400, "audience", "the audience is not one of jobTokens.audiences")

          {:error, :off} ->
            error(conn, 404, "off", "testor issues no job tokens (jobTokens in auth.json)")
        end
      else
        {:error, %Plug.Conn{} = conn} -> conn
        error -> agent_reply(error, conn)
      end
    end)
  end

  # A remote agent's run (Testor.Remote): its record, its log in chunks, its files.
  put "/agent/jobs/:id/run" do
    with_agent(conn, id, fn conn, agent ->
      case body_params(conn) do
        {:ok, params, conn} -> id |> Remote.record(agent, params) |> remote_reply(conn)
        {:error, conn} -> conn
      end
    end)
  end

  post "/agent/jobs/:id/log" do
    with_agent(conn, id, fn conn, agent ->
      conn = fetch_query_params(conn)

      offset =
        case Integer.parse(conn.query_params["offset"] || "") do
          {n, ""} when n >= 0 -> n
          _ -> nil
        end

      case read_body(conn, length: Application.get_env(:testor, :remote_chunk_max, 1_048_576)) do
        {:ok, data, conn} when is_integer(offset) ->
          case Remote.append_log(id, agent, offset, data) do
            {:ok, size} -> json(conn, 200, %{"size" => size})
            error -> remote_reply(error, conn)
          end

        {:ok, _data, conn} ->
          error(conn, 400, "bad_request", "offset is the size of the log before this chunk")

        {_, _data, conn} ->
          error(conn, 413, "too_large", "a log chunk is 1 MB at most")
      end
    end)
  end

  put "/agent/jobs/:id/files/:area/*path" do
    with_agent(conn, id, fn conn, agent ->
      case read_body(conn, length: Application.get_env(:testor, :remote_file_max, 64 * 1024 * 1024)) do
        {:ok, data, conn} ->
          case Remote.put_file(id, agent, area, path, data) do
            {:ok, bytes} -> json(conn, 200, %{"bytes" => bytes})
            error -> remote_reply(error, conn)
          end

        {_, _data, conn} ->
          error(conn, 413, "too_large", "a file is 64 MB at most")
      end
    end)
  end

  match _ do
    error(
      conn,
      404,
      "not_found",
      "no such endpoint: #{conn.method} /api/v1/#{Enum.join(conn.path_info, "/")}"
    )
  end

  # --- helpers -------------------------------------------------------------------------------

  defp reply(conn, {:ok, data}, status), do: json(conn, status, data)
  defp reply(conn, {:error, status, code, message}, _), do: error(conn, status, code, message)

  defp with_id(conn, id, fun) do
    if valid_id?(id), do: fun.(conn), else: error(conn, 400, "bad_request", "bad id")
  end

  # Jobs are asked for and taken by someone: never anonymously, even with authentication off.
  defp signed_in(conn) do
    case conn.assigns.principal do
      %{sub: sub} when is_binary(sub) -> {:ok, sub}
      _ -> {:error, error(conn, 403, "authentication_required", "jobs need authentication: add users first")}
    end
  end

  # An agent presents its public key with each lease; the first one is pinned to it.
  defp pin_key(_conn, _agent, nil), do: :ok

  defp pin_key(conn, agent, pem) do
    case Testor.AgentKeys.pin(agent, pem) do
      :ok ->
        :ok

      {:error, :mismatch} ->
        {:error,
         error(
           conn,
           403,
           "key_mismatch",
           "#{agent} has another key pinned: forget it (Testor.Auth.CLI.forget_agent_key) if the agent was rebuilt"
         )}

      {:error, :bad_key} ->
        {:error, error(conn, 400, "bad_key", "key is the SPKI PEM of an ECDSA P-256 public key")}
    end
  end

  defp with_agent(conn, id, fun) do
    with_id(conn, id, fn conn ->
      case signed_in(conn) do
        {:ok, agent} -> fun.(conn, agent)
        {:error, conn} -> conn
      end
    end)
  end

  defp wait_for_job(agent, labels, deadline, principal) do
    case Jobs.lease(agent, labels, &Testor.Access.permits?(principal, &1, "agent")) do
      {:ok, job} ->
        {:ok, job}

      :none ->
        if System.monotonic_time(:millisecond) >= deadline do
          :none
        else
          Process.sleep(Application.get_env(:testor, :lease_poll_ms, 500))
          wait_for_job(agent, labels, deadline, principal)
        end
    end
  end

  # A finished run's spec table as a report for another tool (Testor.Reports.Export).
  defp export(conn, id, type, render) do
    with_id(conn, id, fn conn ->
      case Testor.Store.get(id) do
        nil ->
          error(conn, 404, "not_found", "no such run")

        run ->
          Testor.Storage.local(id)

          conn
          |> put_resp_content_type(type)
          |> put_resp_header(
            "content-disposition",
            ~s(attachment; filename="#{id}.#{if type =~ "xml", do: "junit.xml", else: "ctrf.json"}")
          )
          |> send_resp(200, render.(run, Testor.Reports.run_specs(id)))
      end
    end)
  end

  defp remote_reply({:ok, data}, conn), do: json(conn, 200, data)

  defp remote_reply({:error, :final}, conn),
    do: error(conn, 409, "final", "the run has ended: it cannot change")

  defp remote_reply({:error, :other_run}, conn), do: error(conn, 409, "other_run", "the job has another run")
  defp remote_reply({:error, :no_run}, conn), do: error(conn, 409, "no_run", "send the run's record first")
  defp remote_reply({:error, :too_large}, conn), do: error(conn, 413, "too_large", "over the run's limit")

  defp remote_reply({:error, :too_many}, conn),
    do: error(conn, 409, "too_many", "a run keeps #{Testor.Reports.max_files()} reports at most")

  defp remote_reply({:error, {:offset, size}}, conn) do
    conn
    |> put_resp_header("x-log-size", to_string(size))
    |> error(409, "offset", "the log has #{size} bytes: send from there")
  end

  defp remote_reply({:error, :no_key}, conn),
    do: error(conn, 409, "no_key", "no key is pinned to this agent: lease with it first")

  defp remote_reply({:error, :signature}, conn),
    do: error(conn, 400, "signature", "the signature is not the agent's pinned key's")

  defp remote_reply({:error, :files_differ}, conn),
    do: error(conn, 409, "files_differ", "the attestation's files are not the ones testor received")

  defp remote_reply({:error, reason}, conn)
       when reason in [:bad_run_id, :bad_status, :bad_path, :not_an_image, :malformed, :not_this_run],
       do: error(conn, 400, "bad_request", "not accepted: #{reason}")

  # The bucket refused or could not be reached (Testor.Storage): the agent sends it again.
  defp remote_reply({:error, why}, conn) when is_binary(why) do
    conn
    |> put_resp_header("retry-after", "5")
    |> error(503, "storage_unavailable", "the run's files cannot be stored now: try again")
  end

  defp remote_reply(error, conn), do: agent_reply(error, conn)

  defp agent_reply({:ok, data}, conn), do: json(conn, 200, data)
  defp agent_reply({:error, :not_found}, conn), do: error(conn, 404, "not_found", "no such job")

  defp agent_reply({:error, :not_yours}, conn),
    do: error(conn, 409, "not_yours", "another agent holds this job")

  defp agent_reply({:error, :ended}, conn),
    do: error(conn, 409, "ended", "the job has ended or its lease expired")

  defp oauth_error(conn, status, code, description) do
    json(conn, status, %{"error" => code, "error_description" => description})
  end

  defp run_filters(params) do
    statuses = Query.statuses()

    cond do
      params["status"] not in [nil | statuses] ->
        {:error, "status is one of #{Enum.join(statuses, ", ")}"}

      params["before"] != nil and not valid_id?(params["before"]) ->
        {:error, "before is a run id"}

      true ->
        {:ok,
         %{
           status: params["status"],
           project: params["project"],
           kind: params["kind"],
           q: blank_to_nil(params["q"]),
           before: params["before"],
           limit: int(params["limit"], 50, 1, 500)
         }}
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value) when is_binary(value), do: value
  defp blank_to_nil(_), do: nil

  defp int(value, default, low, high) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n |> max(low) |> min(high)
      _ -> default
    end
  end

  defp int(_value, default, _low, _high), do: default
end
