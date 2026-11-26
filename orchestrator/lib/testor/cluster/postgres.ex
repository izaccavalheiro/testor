defmodule Testor.Cluster.Postgres do
  @moduledoc """
  Claims and documents in PostgreSQL, for several testors (`Testor.Cluster`): a claim is a row
  whose key is unique, so one insert wins; claims older than a week are pruned.
  """
  @pool Testor.Jobs.Postgres

  def init do
    Postgrex.query!(
      @pool,
      """
      CREATE TABLE IF NOT EXISTS testor_claims (
        kind text NOT NULL, key text NOT NULL, owner text NOT NULL,
        claimed_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (kind, key))
      """,
      []
    )

    Postgrex.query!(
      @pool,
      """
      CREATE TABLE IF NOT EXISTS testor_docs (
        kind text NOT NULL, id text NOT NULL, doc text NOT NULL, PRIMARY KEY (kind, id))
      """,
      []
    )

    Postgrex.query!(@pool, "DELETE FROM testor_claims WHERE claimed_at < now() - interval '7 days'", [])
    %{}
  end

  def claim(kind, key) do
    %{num_rows: rows} =
      Postgrex.query!(
        @pool,
        "INSERT INTO testor_claims (kind, key, owner) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING",
        [kind, to_string(key), Testor.Cluster.instance()]
      )

    rows == 1
  end

  def put(kind, id, doc) do
    Postgrex.query!(
      @pool,
      "INSERT INTO testor_docs (kind, id, doc) VALUES ($1, $2, $3) ON CONFLICT (kind, id) DO UPDATE SET doc = EXCLUDED.doc",
      [kind, id, JSON.encode!(doc)]
    )

    :ok
  end

  def put_new(kind, id, doc) do
    %{num_rows: rows} =
      Postgrex.query!(
        @pool,
        "INSERT INTO testor_docs (kind, id, doc) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING",
        [kind, id, JSON.encode!(doc)]
      )

    rows == 1
  end

  def delete(kind, id) do
    %{num_rows: rows} =
      Postgrex.query!(@pool, "DELETE FROM testor_docs WHERE kind = $1 AND id = $2", [kind, id])

    rows == 1
  end

  def get(kind, id) do
    case Postgrex.query!(@pool, "SELECT doc FROM testor_docs WHERE kind = $1 AND id = $2", [kind, id]) do
      %{rows: [[doc]]} -> JSON.decode!(doc)
      %{rows: []} -> nil
    end
  end

  def list(kind) do
    %{rows: rows} = Postgrex.query!(@pool, "SELECT doc FROM testor_docs WHERE kind = $1", [kind])
    Enum.map(rows, fn [doc] -> JSON.decode!(doc) end)
  end

  def clear do
    Postgrex.query!(@pool, "TRUNCATE testor_claims, testor_docs", [])
    :ok
  end
end
