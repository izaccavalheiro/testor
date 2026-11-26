defmodule Testor.Cluster do
  @moduledoc """
  Several testors serving one team: they share one testor home (a ReadWriteMany volume: EFS,
  Filestore, Azure Files, NFS) and one PostgreSQL (`TESTOR_DATABASE_URL`), and each answers any
  request. The home holds the runs, logs and files, so every testor sees and serves every run;
  PostgreSQL holds the job queue (`Testor.Jobs.Postgres`), the approvals, and the **claims**
  that make one testor, not each, do what must happen once:

    * a run's side effects when it starts and ends (signing, archive, webhooks, commit
      statuses, its trace);
    * a schedule's job for a minute, and the janitor's cleaning for a period.

  `claim/2` is that: true for the first testor that asks. Without PostgreSQL there is one
  testor, and it is always it (`Testor.Cluster.Local`). Each testor writes its own audit trail
  (`audit.<instance>.jsonl`): a chain has one writer. `TESTOR_INSTANCE` names a testor (by
  default its host name).
  """
  use GenServer

  def enabled?, do: Testor.Jobs.Postgres.enabled?()

  @doc "This testor's name: `TESTOR_INSTANCE`, else its host name."
  def instance do
    case System.get_env("TESTOR_INSTANCE") do
      name when name not in [nil, ""] -> name
      _ -> :inet.gethostname() |> elem(1) |> to_string()
    end
  end

  defp backend, do: if(enabled?(), do: Testor.Cluster.Postgres, else: Testor.Cluster.Local)

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil), do: {:ok, backend().init()}

  @doc "Whether this testor does `kind` for `key` (`\"finished\"`, a run's id): true once across testors."
  def claim(kind, key), do: backend().claim(kind, key)

  @doc "Saves document `id` of `kind` (approvals): a map JSON can hold."
  def put(kind, id, doc), do: backend().put(kind, id, doc)

  def get(kind, id), do: backend().get(kind, id)

  @doc "Every document of `kind`."
  def list(kind), do: backend().list(kind)

  @doc "Forgets every document and claim (tests)."
  def clear, do: backend().clear()
end
