defmodule Testor.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    base = [
      {Registry, keys: :duplicate, name: Testor.EventRegistry},
      {Registry, keys: :unique, name: Testor.TrackerRegistry},
      # One entry per open event stream, under its user or address (Testor.Web.SSE's limits).
      {Registry, keys: :duplicate, name: Testor.StreamRegistry},
      {Task.Supervisor, name: Testor.TaskSupervisor},
      Testor.Auth.Guard
    ]

    # The tests start the server themselves (server/0), once they have chosen their folders.
    server = if Application.get_env(:testor, :start_server, true), do: server(), else: []
    Supervisor.start_link(base ++ server, strategy: :one_for_one, name: Testor.Supervisor)
  end

  @doc "The processes that follow the runs and serve them, in start order."
  def server do
    [
      {DynamicSupervisor, name: Testor.TrackerSupervisor, strategy: :one_for_one},
      Testor.Store,
      Testor.Jobs,
      Testor.Schedules,
      Testor.Approvals,
      Testor.Sessions,
      Testor.Stats,
      Testor.Janitor,
      Testor.Device,
      Testor.Maintenance,
      Testor.Audit,
      {Bandit, bandit_options()}
    ]
  end

  @doc """
  The HTTP server's options. With `TESTOR_TLS_CERT` and `TESTOR_TLS_KEY` (PEM files) it speaks
  HTTPS only, with Plug's strong cipher suite (TLS 1.2 and 1.3): a reverse proxy is optional.
  """
  def bandit_options(port \\ Application.fetch_env!(:testor, :port)) do
    base = [plug: Testor.Web.Router, ip: Application.get_env(:testor, :ip, {0, 0, 0, 0}), port: port]

    case {Application.get_env(:testor, :tls_cert), Application.get_env(:testor, :tls_key)} do
      {cert, key} when is_binary(cert) and is_binary(key) ->
        base ++ [scheme: :https, certfile: cert, keyfile: key, cipher_suite: :strong]

      _ ->
        base
    end
  end
end
