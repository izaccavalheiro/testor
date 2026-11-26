defmodule Testor.AgentKeys.Local do
  @moduledoc "Agents' pinned keys in `agent-keys.json` in the secrets folder (`Testor.AgentKeys`)."
  alias Testor.{AgentKeys, Files}

  def all do
    case Files.read_json(AgentKeys.file()) do
      {:ok, keys} -> keys
      :error -> %{}
    end
  end

  @doc "Pins `entry` to `agent` unless it has one: `:ok`, or `{:exists, pinned}`."
  def put_new(agent, entry) do
    :global.trans({__MODULE__, self()}, fn ->
      keys = all()

      case keys[agent] do
        nil ->
          File.mkdir_p!(Path.dirname(AgentKeys.file()))
          Files.write_json(AgentKeys.file(), Map.put(keys, agent, entry))
          File.chmod(AgentKeys.file(), 0o600)
          :ok

        pinned ->
          {:exists, pinned}
      end
    end)
  end

  @doc "Forgets `agent`'s pin: whether it had one."
  def delete(agent) do
    :global.trans({__MODULE__, self()}, fn ->
      keys = all()
      Files.write_json(AgentKeys.file(), Map.delete(keys, agent))
      Map.has_key?(keys, agent)
    end)
  end
end
