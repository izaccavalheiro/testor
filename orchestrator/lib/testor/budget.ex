defmodule Testor.Budget do
  @moduledoc """
  What MCP tools that queue work may spend (`mcp.jobBudget` in config.json): jobs per minute and
  per day for each caller, so a looping or prompt-injected assistant cannot flood the queue.

      {"mcp": {"jobBudget": {"perMinute": 10, "perDay": 200}}}

  Counted per caller (its user, or its token's subject) in memory, by testor: a restart starts
  the counts again.
  """
  use GenServer

  @table :testor_budget

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, write_concurrency: true])
    {:ok, nil}
  end

  def settings do
    defaults = %{"perMinute" => 10, "perDay" => 200}

    case Testor.Config.user()["mcp"] do
      %{"jobBudget" => %{} = budget} -> Map.merge(defaults, budget)
      _ -> defaults
    end
  end

  @doc "Spends one job of `who`'s budget: `:ok`, or `{:error, message}` when a limit is reached."
  def take(who, now \\ System.os_time(:second)) do
    limits = settings()
    minute = {who, :minute, div(now, 60)}
    day = {who, :day, div(now, 86_400)}

    cond do
      count(minute) >= limits["perMinute"] ->
        {:error,
         "#{who} queued #{limits["perMinute"]} jobs this minute (mcp.jobBudget.perMinute): wait a minute"}

      count(day) >= limits["perDay"] ->
        {:error, "#{who} queued #{limits["perDay"]} jobs today (mcp.jobBudget.perDay): the budget is spent"}

      true ->
        :ets.update_counter(@table, minute, 1, {minute, 0})
        :ets.update_counter(@table, day, 1, {day, 0})
        :ok
    end
  end

  @doc "What `who` has left: `%{\"minute\", \"day\"}`."
  def left(who, now \\ System.os_time(:second)) do
    limits = settings()

    %{
      "minute" => max(limits["perMinute"] - count({who, :minute, div(now, 60)}), 0),
      "day" => max(limits["perDay"] - count({who, :day, div(now, 86_400)}), 0)
    }
  end

  @doc false
  def reset, do: :ets.delete_all_objects(@table)

  defp count(key) do
    case :ets.lookup(@table, key) do
      [{_, n}] -> n
      [] -> 0
    end
  end
end
