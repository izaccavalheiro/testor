defmodule Testor.AgentKeys.Shared do
  @moduledoc """
  Agents' pinned keys as documents in PostgreSQL (`Testor.Cluster`), for testors that share no
  volume: an agent pinned through one is known to every other. A pin is an insert that only
  the first testor wins.
  """
  alias Testor.Cluster

  @kind "agent-key"

  def all, do: @kind |> Cluster.list() |> Map.new(&{&1["agent"], Map.delete(&1, "agent")})

  def put_new(agent, entry) do
    if Cluster.put_new(@kind, agent, Map.put(entry, "agent", agent)),
      do: :ok,
      else: {:exists, Cluster.get(@kind, agent)}
  end

  def delete(agent), do: Cluster.delete(@kind, agent)

  @doc "Copies pins from agent-keys.json (`Testor.Storage.CLI.migrate/1`); pins already here stay."
  def import(pins) do
    Testor.Cluster.Postgres.init()
    for {agent, entry} <- pins, do: Cluster.put_new(@kind, agent, Map.put(entry, "agent", agent))
    :ok
  end
end
