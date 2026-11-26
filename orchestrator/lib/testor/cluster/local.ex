defmodule Testor.Cluster.Local do
  @moduledoc "One testor (no PostgreSQL): claims and documents in ETS, for as long as it runs."
  @docs :testor_docs
  @claims :testor_claims

  def init do
    :ets.new(@docs, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(@claims, [:named_table, :public, :set])
    %{}
  end

  def claim(kind, key), do: :ets.insert_new(@claims, {{kind, to_string(key)}})
  def put(kind, id, doc), do: :ets.insert(@docs, {{kind, id}, doc}) && :ok

  def get(kind, id) do
    case :ets.lookup(@docs, {kind, id}) do
      [{_, doc}] -> doc
      [] -> nil
    end
  end

  def list(kind), do: :ets.match_object(@docs, {{kind, :_}, :_}) |> Enum.map(&elem(&1, 1))

  def clear do
    :ets.delete_all_objects(@docs)
    :ets.delete_all_objects(@claims)
    :ok
  end
end
