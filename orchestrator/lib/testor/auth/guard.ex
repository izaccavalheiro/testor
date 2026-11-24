defmodule Testor.Auth.Guard do
  @moduledoc """
  Owns the two tables authentication keeps in memory:

    * verified credentials: PBKDF2 is slow on purpose, and a browser sends its Basic
      credentials with every request (the dashboard, its event streams), so a verified pair is
      remembered for #{300} s under an HMAC of the user, the password and the stored hash,
      keyed with a secret drawn at start. Nothing in the table can be turned back into a
      password, and changing the password (the stored hash) forgets it at once.
    * failed attempts by client address: after #{10} failures in #{15} minutes the address is
      refused (429) until the window ends.
  """
  use GenServer

  @cache :testor_auth_cache
  @failures :testor_auth_failures
  @cache_ttl 300
  @window 900
  @max_failures 10
  @sweep_ms 60_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The cache key of a credential pair (and the hash it was checked against)."
  def cache_key(parts) when is_list(parts) do
    :crypto.mac(:hmac, :sha256, :persistent_term.get({__MODULE__, :secret}), Enum.join(parts, <<0>>))
  end

  def cached?(key, now \\ now()) do
    match?([{_, expires}] when expires > now, :ets.lookup(@cache, key))
  end

  def remember(key, now \\ now()), do: :ets.insert(@cache, {key, now + @cache_ttl})

  @doc "`:ok`, or `{:blocked, seconds}` while `address` has failed too often."
  def check(address, now \\ now()) do
    case :ets.lookup(@failures, address) do
      [{_, count, since}] when count >= @max_failures and now < since + @window ->
        {:blocked, since + @window - now}

      _ ->
        :ok
    end
  end

  @doc "Counts a failed attempt from `address`."
  def failed(address, now \\ now()) do
    case :ets.lookup(@failures, address) do
      [{_, _, since}] when now < since + @window -> :ets.update_counter(@failures, address, {2, 1})
      _ -> :ets.insert(@failures, {address, 1, now})
    end

    :ok
  end

  @doc "Forgets everything (tests)."
  def reset do
    :ets.delete_all_objects(@cache)
    :ets.delete_all_objects(@failures)
    :ok
  end

  @impl true
  def init(nil) do
    :ets.new(@cache, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(@failures, [:named_table, :public, :set, write_concurrency: true])
    :persistent_term.put({__MODULE__, :secret}, :crypto.strong_rand_bytes(32))
    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = now()
    :ets.select_delete(@cache, [{{:_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    :ets.select_delete(@failures, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now - @window}], [true]}])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end

  defp now, do: System.system_time(:second)
end
