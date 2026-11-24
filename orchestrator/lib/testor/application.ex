defmodule Testor.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    base = [
      {Registry, keys: :duplicate, name: Testor.EventRegistry},
      {Registry, keys: :unique, name: Testor.TrackerRegistry},
      {Task.Supervisor, name: Testor.TaskSupervisor}
    ]

    server =
      if Application.get_env(:testor, :start_server, true) do
        port = Application.fetch_env!(:testor, :port)

        [
          {DynamicSupervisor, name: Testor.TrackerSupervisor, strategy: :one_for_one},
          Testor.Store,
          Testor.Sessions,
          Testor.Stats,
          Testor.Janitor,
          Testor.Device,
          {Bandit, plug: Testor.Web.Router, ip: {0, 0, 0, 0}, port: port}
        ]
      else
        []
      end

    Supervisor.start_link(base ++ server, strategy: :one_for_one, name: Testor.Supervisor)
  end
end
