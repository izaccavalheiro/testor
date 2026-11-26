defmodule Testor.JobsPostgresTest do
  @moduledoc "The job queue in PostgreSQL: its connection settings, locking and failures."
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Testor.Jobs
  alias Testor.Jobs.Postgres

  @moduletag :postgres

  setup do
    Jobs.reset()
    on_exit(fn -> Jobs.reset() end)
  end

  test "connection settings from the URL: TLS checked by default away from this machine" do
    remote = Postgres.options("postgres://tes%40tor:p%3Ass@db.example.com/evidence")
    assert remote[:hostname] == "db.example.com" and remote[:port] == 5432 and remote[:database] == "evidence"
    assert remote[:username] == "tes@tor" and remote[:password] == "p:ss"
    assert remote[:ssl][:verify] == :verify_peer

    assert Postgres.options("postgres://u@localhost:6543")[:ssl] == false
    assert Postgres.options("postgres://u@localhost:6543")[:password] == nil
    assert Postgres.options("postgres://u@localhost:6543")[:database] == "testor"
    assert Postgres.options("postgres://u:p@db/x?sslmode=require")[:ssl] == [verify: :verify_none]
    assert Postgres.options("postgres://u:p@localhost/x?sslmode=verify-full")[:ssl][:verify] == :verify_peer
  end

  test "jobs are rows; the table is made once" do
    File.write!(
      Path.join(Testor.Config.data_dir(), "config.json"),
      JSON.encode!(%{"execution" => %{"enabled" => true}})
    )

    on_exit(fn -> File.rm(Path.join(Testor.Config.data_dir(), "config.json")) end)
    {:ok, job} = Jobs.enqueue(%{"project" => "pg", "kind" => "test"}, "ada")

    assert %{rows: [[status, doc]]} =
             Postgrex.query!(Postgres, "SELECT status, doc FROM testor_jobs WHERE id = $1", [job["id"]])

    assert status == "queued" and JSON.decode!(doc)["project"] == "pg"
    assert Postgres.migrate!() == :ok
  end

  test "leases on several instances wait for one another (the advisory lock)" do
    parent = self()

    work = fn name ->
      Task.async(fn ->
        Postgres.transaction(%{}, :open, fn _jobs ->
          send(parent, {:in, name, System.monotonic_time(:millisecond)})
          Process.sleep(200)
          send(parent, {:out, name, System.monotonic_time(:millisecond)})
          {:ok, []}
        end)
      end)
    end

    Task.await_many([work.(:a), work.(:b)])
    events = for _ <- 1..4, do: receive(do: (message -> message))
    [first, second, third, fourth] = Enum.sort_by(events, &elem(&1, 2))
    # In, out, in, out: never both inside.
    assert [{:in, x, _}, {:out, x, _}, {:in, y, _}, {:out, y, _}] = [first, second, third, fourth]
    assert x != y
  end

  test "a database that refuses answers unavailable, and nothing changes" do
    log =
      capture_log(fn ->
        assert {{:error, :unavailable}, %{}, [], %{}} =
                 Postgres.transaction(%{}, {:all, nil}, fn _ -> raise Postgrex.Error, message: "gone" end)
      end)

    assert log =~ "jobs: PostgreSQL: gone"
  end
end
