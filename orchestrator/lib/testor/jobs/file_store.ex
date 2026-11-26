defmodule Testor.Jobs.FileStore do
  @moduledoc """
  The job queue in files (the default): `<home>/jobs/<id>.json`, all of them in memory, for one
  testor. `Testor.Jobs.Postgres` holds it in PostgreSQL instead, for several.
  """
  alias Testor.{Config, Files}

  def dir, do: Path.join(Config.data_dir(), "jobs")

  @doc "Every job, read from its file."
  def init do
    File.mkdir_p!(dir())

    jobs =
      for name <- Files.ls(dir()),
          String.ends_with?(name, ".json"),
          {:ok, job} <- [Files.read_json(Path.join(dir(), name))],
          into: %{} do
        {job["id"], job}
      end

    %{jobs: jobs}
  end

  @doc "Runs `fun` on every job and saves those it changed: `{reply, before, changed, state}`."
  def transaction(%{jobs: jobs} = state, _scope, fun) do
    {reply, changed} = fun.(jobs)
    for job <- changed, do: Files.write_json(Path.join(dir(), job["id"] <> ".json"), job)
    {reply, jobs, changed, %{state | jobs: Enum.reduce(changed, jobs, &Map.put(&2, &1["id"], &1))}}
  end

  @doc "Removes every job (tests)."
  def clear(_state) do
    File.rm_rf!(dir())
    File.mkdir_p!(dir())
    %{jobs: %{}}
  end
end
