defmodule Testor.Events do
  @moduledoc """
  Publish/subscribe over a duplicate-key Registry. Topics: `"global"` (the run list, sessions,
  stats) and `{"run", id}` (one run's log, specs and screenshots). Subscribers receive
  `{:event, name, data}`; the SSE handlers forward these to browsers.
  """
  @registry Testor.EventRegistry

  def subscribe(topic), do: Registry.register(@registry, topic, nil)

  @doc """
  Sends an event to this testor's subscribers; the dashboard's `job` and `approval` events go
  to the other testors too when they share no volume (`Testor.Storage.Shared`).
  """
  def broadcast(topic, name, data) do
    relay? = topic == "global" and name in ["job", "approval"]
    if relay? and Testor.Storage.shared?(), do: Testor.Storage.Shared.relay(topic, name, data)

    local(topic, name, data)
  end

  @doc "Sends an event to this testor's subscribers only."
  def local(topic, name, data) do
    Registry.dispatch(@registry, topic, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:event, name, data})
    end)
  end

  def subscribers(topic), do: Registry.count_match(@registry, topic, :_)
end
