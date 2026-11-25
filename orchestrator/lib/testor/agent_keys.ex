defmodule Testor.AgentKeys do
  @moduledoc """
  Agents' signing keys: an agent (`runner/agent.ps1`) makes an ECDSA P-256 key on its first
  start and presents its public half with every lease. The first key an agent user presents is
  pinned to it (trust on first use) in `agent-keys.json` in the secrets folder; a different key
  later is refused, until an administrator forgets the pinned one
  (`bin/testor eval 'Testor.Auth.CLI.forget_agent_key ~s[name]'`), as for a rebuilt agent.

  Runs an agent sends are then signed by it (`Testor.Remote.attest/3`): evidence of what the
  agent ran that does not depend on testor.
  """
  alias Testor.{Config, Files}

  # secp256r1 (P-256).
  @p256 {1, 2, 840, 10045, 3, 1, 7}

  def file, do: Path.join(Config.secrets_dir(), "agent-keys.json")

  @doc "The pinned agents: `%{name => %{\"publicKey\", \"keyid\", \"pinnedAt\"}}`."
  def all do
    case Files.read_json(file()) do
      {:ok, keys} -> keys
      :error -> %{}
    end
  end

  @doc "The key pinned to `agent`, decoded for `:public_key.verify/4`, or nil."
  def get(agent) do
    with %{"publicKey" => pem} <- all()[agent],
         {:ok, key} <- decode(pem) do
      key
    else
      _ -> nil
    end
  end

  @doc """
  Pins `pem` (an SPKI PEM of a P-256 key) to `agent` if it has none: `:ok` when it is the
  pinned key (or now is), `{:error, :mismatch}` for another, `{:error, :bad_key}`.
  """
  def pin(agent, pem) when is_binary(pem) do
    with {:ok, _key} <- decode(pem) do
      :global.trans({__MODULE__, self()}, fn ->
        keys = all()

        case keys[agent] do
          nil ->
            entry = %{
              "publicKey" => pem,
              "keyid" => keyid(pem),
              "pinnedAt" => DateTime.utc_now() |> DateTime.to_iso8601()
            }

            File.mkdir_p!(Path.dirname(file()))
            Files.write_json(file(), Map.put(keys, agent, entry))
            File.chmod(file(), 0o600)
            :ok

          %{"publicKey" => pinned} ->
            if normalize(pinned) == normalize(pem), do: :ok, else: {:error, :mismatch}
        end
      end)
    end
  end

  def pin(_agent, _pem), do: {:error, :bad_key}

  @doc "Forgets `agent`'s key: its next lease pins the key it presents."
  def forget(agent) do
    :global.trans({__MODULE__, self()}, fn ->
      keys = all()
      Files.write_json(file(), Map.delete(keys, agent))
      Map.has_key?(keys, agent)
    end)
  end

  @doc "A P-256 public key from its SPKI PEM: `{:ok, key}` or `{:error, :bad_key}`."
  def decode(pem) when is_binary(pem) do
    case :public_key.pem_decode(pem) do
      [{:SubjectPublicKeyInfo, _, _} = entry] ->
        case :public_key.pem_entry_decode(entry) do
          {{:ECPoint, _}, {:namedCurve, @p256}} = key -> {:ok, key}
          _ -> {:error, :bad_key}
        end

      _ ->
        {:error, :bad_key}
    end
  rescue
    _ -> {:error, :bad_key}
  end

  def decode(_), do: {:error, :bad_key}

  @doc "A key's id: the SHA-256 of its DER, in hex."
  def keyid(pem) do
    [{_, der, _}] = :public_key.pem_decode(pem)
    :crypto.hash(:sha256, der) |> Base.encode16(case: :lower)
  end

  defp normalize(pem), do: pem |> String.replace(~r/\s+/, "")
end
