defmodule Testor.Jobs.Postgres do
  @moduledoc """
  The job queue in PostgreSQL, for several testor instances sharing one queue (behind a load
  balancer, or in Kubernetes with more than one replica). On when `TESTOR_DATABASE_URL` is set:

      TESTOR_DATABASE_URL=postgres://testor:<password>@db.example.com:5432/testor?sslmode=verify-full

  `sslmode`: `verify-full` (TLS, the server's certificate checked against the system's roots and
  its name; the default for any host but this machine), `require` (TLS, not checked), `disable`
  (the default for `localhost`). The table `testor_jobs` is made at start. A job is a row (its
  id, project, status and when it was queued as columns, the job itself as JSON text); each
  change is a transaction that locks the rows it reads, and leasing and expiry also hold an
  advisory lock, so one job per project runs at a time across every instance.
  """
  require Logger
  @lock 714_000_001

  def url, do: System.get_env("TESTOR_DATABASE_URL")
  def enabled?, do: url() not in [nil, ""]

  @doc "The connection pool, under the application's supervisor."
  def child_spec(_), do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}}

  def start_link, do: Postgrex.start_link([name: __MODULE__, pool_size: 5] ++ options(url()))

  @doc "Postgrex's options from a `postgres://` URL."
  def options(url) do
    uri = URI.parse(url)
    [user, password] = (uri.userinfo || "") |> String.split(":", parts: 2) |> Enum.map(&URI.decode/1) |> pad()
    query = URI.decode_query(uri.query || "")
    local = uri.host in ["localhost", "127.0.0.1", "::1"]

    ssl =
      case query["sslmode"] || if(local, do: "disable", else: "verify-full") do
        "disable" ->
          false

        "require" ->
          [verify: :verify_none]

        _verify_full ->
          [
            verify: :verify_peer,
            cacerts: :public_key.cacerts_get(),
            server_name_indication: String.to_charlist(uri.host),
            customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
          ]
      end

    [
      hostname: uri.host,
      port: uri.port || 5432,
      database: String.trim_leading(uri.path || "/testor", "/"),
      username: user,
      password: password,
      ssl: ssl
    ]
  end

  defp pad([user]), do: [user, nil]
  defp pad(pair), do: pair

  @doc "The backend's state (none: the database holds it), once the table is there."
  def init do
    migrate!()
    %{}
  end

  @doc "Makes the table when it is not there."
  def migrate! do
    Postgrex.query!(
      __MODULE__,
      """
      CREATE TABLE IF NOT EXISTS testor_jobs (
        id text PRIMARY KEY, project text NOT NULL, status text NOT NULL,
        created_at text NOT NULL, doc text NOT NULL)
      """,
      []
    )

    Postgrex.query!(__MODULE__, "CREATE INDEX IF NOT EXISTS testor_jobs_status ON testor_jobs (status)", [])
    :ok
  end

  @doc """
  Runs `fun` on the jobs `scope` names, in a transaction, and saves the jobs it changed:
  `{reply, before, changed, state}`. Scopes: `{:id, id}` (that row, locked), `:open` (the jobs
  not ended, under the queue's advisory lock), `{:all, status}` (read only), `:none`. With the
  database out of reach the reply is `{:error, :unavailable}` and nothing changes.
  """
  def transaction(state, scope, fun) do
    {:ok, {reply, before, changed}} =
      Postgrex.transaction(__MODULE__, fn conn ->
        if scope == :open, do: Postgrex.query!(conn, "SELECT pg_advisory_xact_lock($1)", [@lock])
        jobs = load(conn, scope)
        {reply, changed} = fun.(jobs)
        Enum.each(changed, &save(conn, &1))
        {reply, jobs, changed}
      end)

    {reply, before, changed, state}
  rescue
    # The database out of reach, a query refused, a transaction rolled back.
    error in [Postgrex.Error, DBConnection.ConnectionError, MatchError] ->
      Logger.error("jobs: PostgreSQL: #{Exception.message(error)}")
      {{:error, :unavailable}, %{}, [], state}
  end

  defp load(_conn, :none), do: %{}

  defp load(conn, {:id, id}),
    do: rows(conn, "SELECT doc FROM testor_jobs WHERE id = $1 FOR UPDATE", [id])

  defp load(conn, :open),
    do:
      rows(conn, "SELECT doc FROM testor_jobs WHERE status IN ('queued', 'leased', 'running') FOR UPDATE", [])

  defp load(conn, {:all, nil}), do: rows(conn, "SELECT doc FROM testor_jobs", [])
  defp load(conn, {:all, status}), do: rows(conn, "SELECT doc FROM testor_jobs WHERE status = $1", [status])

  defp rows(conn, sql, params) do
    %{rows: rows} = Postgrex.query!(conn, sql, params)
    Map.new(rows, fn [doc] -> doc |> JSON.decode!() |> then(&{&1["id"], &1}) end)
  end

  defp save(conn, job) do
    Postgrex.query!(
      conn,
      """
      INSERT INTO testor_jobs (id, project, status, created_at, doc) VALUES ($1, $2, $3, $4, $5)
      ON CONFLICT (id) DO UPDATE SET status = EXCLUDED.status, doc = EXCLUDED.doc
      """,
      [job["id"], job["project"], job["status"], job["createdAt"], JSON.encode!(job)]
    )
  end

  @doc "Removes every job (tests)."
  def clear(state) do
    Postgrex.query!(__MODULE__, "TRUNCATE testor_jobs", [])
    state
  end
end
