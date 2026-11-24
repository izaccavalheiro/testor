defmodule Testor.Events do
  @moduledoc """
  Publish/subscribe over a duplicate-key Registry. Topics: `"global"` (the run list, sessions,
  stats) and `{"run", id}` (one run's log, specs and screenshots). Subscribers receive
  `{:event, name, data}`; the SSE handlers forward these to browsers.
  """
  @registry Testor.EventRegistry

  def subscribe(topic), do: Registry.register(@registry, topic, nil)

  def broadcast(topic, name, data) do
    Registry.dispatch(@registry, topic, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:event, name, data})
    end)
  end

  def subscribers(topic), do: Registry.count_match(@registry, topic, :_)
end
