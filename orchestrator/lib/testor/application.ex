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
      Testor.Sessions,
      Testor.Stats,
      Testor.Janitor,
      Testor.Device,
      Testor.Maintenance,
      {Bandit,
       plug: Testor.Web.Router,
       ip: Application.get_env(:testor, :ip, {0, 0, 0, 0}),
       port: Application.fetch_env!(:testor, :port)}
    ]
  end
end
