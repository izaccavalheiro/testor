defmodule Testor.QueueTest do
  @moduledoc "The queue port: SQS and NATS JetStream against fakes, one contract, and jobs dispatched through them."
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Testor.{Jobs, Queue}
  alias Testor.Queue.NATS
  alias Testor.Test.{FakeNATS, FakeSQS}

  @moduletag :tmp_dir

  setup do
    config = Path.join(Testor.Config.data_dir(), "config.json")
    System.put_env("AWS_ACCESS_KEY_ID", "AKIDTEST")
    System.put_env("AWS_SECRET_ACCESS_KEY", "secret")
    Jobs.reset()
    Queue.reset()

    on_exit(fn ->
      File.rm(config)
      System.delete_env("AWS_ACCESS_KEY_ID")
      System.delete_env("AWS_SECRET_ACCESS_KEY")
      Jobs.reset()
      Queue.reset()

      for {k, _} <- :persistent_term.get(),
          match?({Testor.Queue.NATS, :ready, _, _, _, _}, k),
          do: :persistent_term.erase(k)
    end)

    %{config: config}
  end

  defp execution(ctx, queue, extra \\ %{}) do
    execution = Map.merge(%{"enabled" => true, "leaseSeconds" => 30, "queue" => queue}, extra)
    File.write!(ctx.config, JSON.encode!(%{"execution" => execution}))
  end

  defp sqs(base, extra \\ %{}) do
    Map.merge(
      %{
        "type" => "sqs",
        "region" => "us-east-1",
        "allowHttp" => true,
        "waitSeconds" => 0,
        "queues" => [
          %{"labels" => ["mutation"], "url" => base <> "heavy.fifo"},
          %{"labels" => [], "url" => base <> "jobs.fifo"}
        ]
      },
      extra
    )
  end

  defp nats(port, extra \\ %{}) do
    Map.merge(
      %{
        "type" => "nats",
        "url" => "nats://127.0.0.1:#{port}",
        "tls" => false,
        "stream" => "TESTOR",
        "queues" => [
          %{"labels" => ["mutation"], "subject" => "testor.jobs.heavy"},
          %{"subject" => "testor.jobs.default"}
        ]
      },
      extra
    )
  end

  # The same lifecycle on every adapter.
  defp contract(cfg) do
    [heavy, default] = cfg.queues
    job = %{"id" => "job-1", "project" => "web"}
    assert :ok = cfg.adapter.enqueue(cfg, default, job)
    assert :ok = cfg.adapter.enqueue(cfg, default, job)
    assert {:ok, 1} = cfg.adapter.depth(cfg, default)
    assert {:ok, nil} = cfg.adapter.receive(cfg, heavy, 30)

    assert {:ok, %{id: "job-1", receipt: r1}} = cfg.adapter.receive(cfg, default, 30)
    assert {:ok, nil} = cfg.adapter.receive(cfg, default, 30)
    assert :ok = cfg.adapter.extend(cfg, default, r1, 30)
    assert :ok = cfg.adapter.release(cfg, default, r1)
    assert {:ok, %{id: "job-1", receipt: r2}} = cfg.adapter.receive(cfg, default, 30)
    assert :ok = cfg.adapter.ack(cfg, default, r2)
    assert {:ok, nil} = cfg.adapter.receive(cfg, default, 30)
    assert {:ok, 0} = cfg.adapter.depth(cfg, default)
  end

  describe "configuration" do
    test "the store dispatches without a queue; a bad one is logged and off" do
      assert Queue.config(%{}) == nil
      assert Queue.health(nil) == nil

      log =
        capture_log(fn ->
          for bad <- [
                %{"type" => "kafka"},
                %{"type" => "sqs", "queues" => []},
                %{"type" => "sqs", "queues" => [%{"labels" => "x", "url" => "u"}]},
                %{"type" => "sqs", "queues" => [7]},
                %{"type" => "sqs", "region" => "Bad Region", "queues" => [%{"url" => "https://q/x.fifo"}]},
                %{
                  "type" => "sqs",
                  "region" => "us-east-1",
                  "waitSeconds" => 30,
                  "queues" => [%{"url" => "https://q/x.fifo"}]
                },
                %{"type" => "sqs", "region" => "us-east-1", "queues" => [%{"url" => "http://q/x.fifo"}]},
                %{"type" => "sqs", "region" => "us-east-1", "queues" => [%{"url" => "https://q/x"}]},
                %{"type" => "sqs", "region" => "us-east-1", "queues" => [%{"url" => 5}]},
                %{"type" => "nats", "url" => "http://x", "queues" => [%{"subject" => "a"}]},
                %{"type" => "nats", "url" => "nats://x", "queues" => [%{"subject" => "a"}]},
                %{"type" => "nats", "url" => "tls://x", "stream" => "a b", "queues" => [%{"subject" => "a"}]},
                %{"type" => "nats", "url" => "tls://x", "queues" => [%{"subject" => "a.*"}]}
              ],
              do: assert(Queue.config(%{"queue" => bad}) == nil)
        end)

      for why <- [
            "sqs or nats",
            "list of queues",
            "list of names",
            "AWS region",
            "0 to 20",
            ".fifo queue URL",
            "tls://host",
            "needs \"tls\": false",
            "stream is a name",
            "without wildcards"
          ],
          do: assert(log =~ why)

      assert %{type: "nats", port: 4222, tls: true, stream: "TESTOR"} =
               Queue.config(%{
                 "queue" => %{"type" => "nats", "url" => "tls://n", "queues" => [%{"subject" => "a"}]}
               })
    end

    test "routing: a job to the first queue it fits, an agent from those it fits" do
      cfg = Queue.config(%{"queue" => sqs("https://sqs.example/1/", %{"allowHttp" => false})})
      assert %{name: "jobs.fifo"} = Queue.queue_for(cfg, [])
      assert %{name: "heavy.fifo"} = Queue.queue_for(cfg, ["mutation", "linux"])
      assert [%{name: "jobs.fifo"}] = Queue.queues_for(cfg, ["linux"])
      assert [_, _] = Queue.queues_for(cfg, ["mutation"])

      only =
        Queue.config(%{
          "queue" =>
            sqs("https://sqs.example/1/", %{
              "queues" => [%{"labels" => ["gpu"], "url" => "https://sqs.example/1/g.fifo"}]
            })
        })

      assert Queue.queue_for(only, ["linux"]) == nil
    end
  end

  describe "SQS" do
    test "the contract, and its errors", ctx do
      base = FakeSQS.start()
      cfg = Queue.config(%{"queue" => sqs(base)})
      contract(cfg)

      [_, default] = cfg.queues
      FakeSQS.fail(true)

      assert {:error, {500, "InternalError"}} =
               cfg.adapter.enqueue(cfg, default, %{"id" => "j", "project" => "p"})

      assert {:error, _} = cfg.adapter.depth(cfg, default)
      FakeSQS.fail(false)

      System.delete_env("AWS_ACCESS_KEY_ID")
      assert {:error, "no credentials" <> _} = cfg.adapter.depth(cfg, default)
      System.put_env("AWS_ACCESS_KEY_ID", "AKIDTEST")

      down = Queue.config(%{"queue" => sqs("http://127.0.0.1:1/0/")})
      assert {:error, _} = down.adapter.receive(down, hd(down.queues), 30)
      _ = ctx
    end

    test "answers that are empty, not JSON, or without the count" do
      base = FakeSQS.start()
      cfg = Queue.config(%{"queue" => sqs(base)})
      [_, default] = cfg.queues
      FakeSQS.fail(:empty)
      assert {:ok, nil} = cfg.adapter.receive(cfg, default, 30)
      FakeSQS.fail(:garbage)
      assert {:ok, nil} = cfg.adapter.receive(cfg, default, 30)
      FakeSQS.fail(:bad_attrs)
      assert {:error, :bad_answer} = cfg.adapter.depth(cfg, default)
    end

    test "a message that is not a job's is received, to be dropped" do
      base = FakeSQS.start()
      cfg = Queue.config(%{"queue" => sqs(base)})
      [_, default] = cfg.queues

      Agent.update(
        FakeSQS.State,
        &%{
          &1
          | messages: [%{id: "x", queue: default.url, body: "{nope", group: "g", visible: 0, receipt: nil}]
        }
      )

      assert {:ok, %{id: nil}} = cfg.adapter.receive(cfg, default, 30)
    end
  end

  describe "NATS JetStream" do
    test "the contract, with the stream and consumers made" do
      port = FakeNATS.start()
      cfg = Queue.config(%{"queue" => nats(port)})
      contract(cfg)
      # A second queue's subject is added to the stream.
      [heavy, _] = cfg.queues
      assert :ok = cfg.adapter.enqueue(cfg, heavy, %{"id" => "job-2", "project" => "web"})
      assert {:ok, %{id: "job-2"}} = cfg.adapter.receive(cfg, heavy, 30)
    end

    test "token and NKey authentication, refused or not", %{tmp_dir: dir} do
      private = :crypto.strong_rand_bytes(32)
      {public, _} = :crypto.generate_key(:eddsa, :ed25519, private)
      seed = NATS.encode_seed(private)
      assert {:ok, ^private} = NATS.decode_seed(seed)
      assert {:error, :bad_nkey_seed} = NATS.decode_seed("SUNOPE")
      assert "U" <> _ = NATS.encode_public(public)

      port = FakeNATS.start({:nkey, NATS.encode_public(public)})
      seed_file = Path.join(dir, "user.nk")
      File.write!(seed_file, seed <> "\n")
      ok = Queue.config(%{"queue" => nats(port, %{"auth" => %{"nkeySeedFile" => seed_file}})})
      assert {:ok, 0} = ok.adapter.depth(ok, hd(ok.queues))

      creds = Path.join(dir, "user.creds")

      File.write!(creds, """
      -----BEGIN NATS USER JWT-----
      eyJ0eXAiOiJKV1QiLCJhbGciOiJlZDI1NTE5LW5rZXkifQ.e30.c2ln
      ------END NATS USER JWT------

      -----BEGIN USER NKEY SEED-----
      #{seed}
      ------END USER NKEY SEED------
      """)

      by_creds = Queue.config(%{"queue" => nats(port, %{"auth" => %{"credsFile" => creds}})})
      assert {:ok, 0} = by_creds.adapter.depth(by_creds, hd(by_creds.queues))

      wrong = Queue.config(%{"queue" => nats(port, %{"auth" => %{"token" => "nope"}})})
      assert {:error, {:refused, "'Authorization Violation'"}} = wrong.adapter.depth(wrong, hd(wrong.queues))

      File.write!(Path.join(dir, "bad.creds"), "nothing")
      bad = Queue.config(%{"queue" => nats(port, %{"auth" => %{"credsFile" => Path.join(dir, "bad.creds")}})})
      assert {:error, :bad_creds_file} = bad.adapter.depth(bad, hd(bad.queues))

      missing =
        Queue.config(%{"queue" => nats(port, %{"auth" => %{"nkeySeedFile" => Path.join(dir, "none")}})})

      assert {:error, :enoent} = missing.adapter.depth(missing, hd(missing.queues))
    end

    test "over TLS, verified; chatty, oversized, broken and headerless answers" do
      port = FakeNATS.start(nil, tls: true)

      tls =
        %{"url" => "tls://localhost:#{port}", "caBundle" => FakeNATS.ca_file()}
        |> then(&Map.merge(nats(port), &1))
        |> Map.delete("tls")

      cfg = Queue.config(%{"queue" => tls})
      [_, default] = cfg.queues
      assert :ok = cfg.adapter.enqueue(cfg, default, %{"id" => "t-1", "project" => "p"})
      assert {:ok, %{id: "t-1"}} = cfg.adapter.receive(cfg, default, 30)

      untrusted = Queue.config(%{"queue" => Map.delete(tls, "caBundle")})
      assert {:error, {:tls, _}} = untrusted.adapter.depth(untrusted, default)

      FakeNATS.mode(:chatty)
      assert :ok = cfg.adapter.enqueue(cfg, default, %{"id" => "t-2", "project" => "q"})
      assert {:ok, %{id: "t-2"}} = cfg.adapter.receive(cfg, default, 30)
      FakeNATS.mode(:plain_next)
      assert :ok = cfg.adapter.enqueue(cfg, default, %{"id" => "t-3", "project" => "r"})
      assert {:ok, %{id: "t-3", receipt: "$JS.ACK." <> _}} = cfg.adapter.receive(cfg, default, 30)
      FakeNATS.mode(:huge)
      assert {:error, :too_large} = cfg.adapter.depth(cfg, default)
      FakeNATS.mode(:bad_body)
      assert {:error, :bad_message} = cfg.adapter.depth(cfg, default)
      FakeNATS.mode(:long_line)
      assert {:error, :line_too_long} = cfg.adapter.depth(cfg, default)
    end

    test "every way a broker can answer wrong" do
      port = FakeNATS.start()
      cfg = Queue.config(%{"queue" => nats(port)})
      [_, default] = cfg.queues
      job = %{"id" => "w-1", "project" => "p"}

      FakeNATS.mode(:create_error)
      assert {:error, %{"code" => 400}} = cfg.adapter.enqueue(cfg, default, job)
      FakeNATS.mode(nil)
      assert :ok = cfg.adapter.enqueue(cfg, default, job)
      FakeNATS.mode(:pub_error)
      assert {:error, %{"code" => 503}} = cfg.adapter.enqueue(cfg, default, %{job | "id" => "w-2"})
      FakeNATS.mode(:next_409)
      assert {:error, {:unexpected, 409}} = cfg.adapter.receive(cfg, default, 30)
      FakeNATS.mode(:info_error)
      assert {:error, %{"code" => 404}} = cfg.adapter.depth(cfg, default)
      FakeNATS.mode(:huge)
      assert {:error, :too_large} = cfg.adapter.receive(cfg, default, 30)
      FakeNATS.mode(:err_reply)
      assert {:error, {:refused, "'Permissions Violation'"}} = cfg.adapter.depth(cfg, default)
      FakeNATS.mode(:cut)
      assert {:error, _} = cfg.adapter.depth(cfg, default)
      FakeNATS.mode(:no_info)
      assert {:error, {:unexpected, "HELLO"}} = cfg.adapter.depth(cfg, default)
      FakeNATS.mode(:close_after_connect)
      assert {:error, _} = cfg.adapter.depth(cfg, default)
    end

    test "a message that is not a job's, and a refused stream" do
      port = FakeNATS.start()
      cfg = Queue.config(%{"queue" => nats(port)})
      [_, default] = cfg.queues
      assert {:ok, nil} = cfg.adapter.receive(cfg, default, 30)

      Agent.update(
        FakeNATS.State,
        &%{&1 | messages: [%{seq: 9, subject: default.subject, id: "x", payload: "{no", out: false}]}
      )

      assert {:ok, %{id: nil}} = cfg.adapter.receive(cfg, default, 30)
      assert {:error, :enoent} = NATS.auth(%{"credsFile" => "/no/such.creds"}, "n")
    end

    test "tokens and passwords from the environment" do
      assert {:ok, %{"auth_token" => "t"}} = NATS.auth(%{"token" => "t"}, nil)
      System.put_env("NATS_TEST_PASS", "p")
      on_exit(fn -> System.delete_env("NATS_TEST_PASS") end)

      assert {:ok, %{"user" => "u", "pass" => "p"}} =
               NATS.auth(%{"user" => "u", "password" => "env:NATS_TEST_PASS"}, nil)

      assert {:error, {:no_env, "NATS_NONE"}} = NATS.auth(%{"token" => "env:NATS_NONE"}, nil)
      assert {:error, :no_nonce} = NATS.auth(%{"nkeySeedFile" => write_seed()}, nil)
      assert {:ok, %{}} = NATS.auth(%{}, "n")
    end

    defp write_seed do
      path = Path.join(System.tmp_dir!(), "seed-#{System.unique_integer([:positive])}.nk")
      File.write!(path, NATS.encode_seed(:crypto.strong_rand_bytes(32)))
      path
    end

    test "a broker without JetStream, one that speaks nonsense, none at all; bad receipts" do
      port = FakeNATS.start()
      cfg = Queue.config(%{"queue" => nats(port)})
      [_, default] = cfg.queues
      FakeNATS.mode(:no_js)
      assert {:error, {:no_answer, 503}} = cfg.adapter.depth(cfg, default)
      assert {:error, _} = cfg.adapter.enqueue(cfg, default, %{"id" => "j", "project" => "p"})
      FakeNATS.mode(:garbage)
      assert {:error, {:unexpected, "WHAT"}} = cfg.adapter.depth(cfg, default)
      FakeNATS.mode(nil)
      assert {:error, :bad_receipt} = cfg.adapter.ack(cfg, default, "nope")

      down = Queue.config(%{"queue" => nats(1)})
      assert {:error, :econnrefused} = down.adapter.depth(down, hd(down.queues))
    end
  end

  describe "jobs through a broker" do
    test "queued, leased, renewed, finished; one per project; gone and refused jobs", ctx do
      base = FakeSQS.start()
      execution(ctx, sqs(base))

      assert {:error, "no queue takes jobs" <> _} =
               (fn ->
                  execution(
                    ctx,
                    sqs(base, %{"queues" => [%{"labels" => ["gpu"], "url" => base <> "g.fifo"}]})
                  )

                  Jobs.enqueue(%{"project" => "web", "kind" => "test"}, "ada")
                end).()

      execution(ctx, sqs(base))
      {:ok, a} = Jobs.enqueue(%{"project" => "web", "kind" => "test"}, "ada")
      {:ok, b} = Jobs.enqueue(%{"project" => "web", "kind" => "lint"}, "ada")
      {:ok, c} = Jobs.enqueue(%{"project" => "api", "kind" => "test"}, "ada")

      {:ok, heavy} =
        Jobs.enqueue(%{"project" => "big", "kind" => "mutation", "labels" => ["mutation"]}, "ada")

      assert {:ok, %{"id" => id} = leased} = Jobs.lease("bot", [])
      assert id == a["id"]
      refute Map.has_key?(leased, "dispatch")
      assert %{"status" => "leased"} = Jobs.get(id)
      refute Map.has_key?(Jobs.get(id), "dispatch")
      assert [_ | _] = Jobs.list()

      # FIFO keeps web's second job back while the first is out; api's comes next.
      assert {:ok, %{"id" => second}} = Jobs.lease("bot2", [])
      assert second == c["id"]
      assert :none = Jobs.lease("bot3", ["linux"])

      assert {:ok, %{"cancel" => false}} = Jobs.heartbeat(id, "bot")
      assert {:ok, %{"status" => "passed"}} = Jobs.finish(id, "bot", %{"exitCode" => 0})
      assert {:ok, %{"id" => third}} = Jobs.lease("bot", [])
      assert third == b["id"]

      # An agent that may not take the project puts the message back.
      assert :none = Jobs.lease("restricted", ["mutation"], &(&1 != "big"))
      assert {:ok, %{"id" => h}} = Jobs.lease("heavy-bot", ["mutation"])
      assert h == heavy["id"]

      # A job cancelled while queued: its message goes when received.
      {:ok, d} = Jobs.enqueue(%{"project" => "docs", "kind" => "test"}, "ada")
      {:ok, _} = Jobs.cancel(d["id"])
      assert :none = Jobs.lease("bot", [])
      assert Enum.all?(FakeSQS.messages(), &(&1.group != "docs"))

      # An expired job's message is deleted (one attempt only here).
      execution(ctx, sqs(base), %{"maxAttempts" => 1})
      capture_log(fn -> Testor.Jobs.sweep_now(System.os_time(:second) + 3600) end)
      Testor.Test.Helpers.wait_until(fn -> FakeSQS.messages() == [] end)

      metrics = IO.iodata_to_binary(Testor.Metrics.render())
      assert metrics =~ ~s(testor_queue_depth{queue="jobs.fifo"})
      assert metrics =~ "testor_queue_errors_total "
      assert Queue.health() == "ok"
    end

    test "past ten jobs that are gone in a row, the next queue", ctx do
      base = FakeSQS.start()
      execution(ctx, sqs(base))

      for n <- 1..11 do
        {:ok, job} = Jobs.enqueue(%{"project" => "p#{n}", "kind" => "test"}, "ada")
        {:ok, _} = Jobs.cancel(job["id"])
      end

      assert :none = Jobs.lease("bot", [])
      assert length(FakeSQS.messages()) == 1
    end

    test "a broker that refuses: the job is not left queued, health degrades", ctx do
      base = FakeSQS.start()
      execution(ctx, sqs(base))
      FakeSQS.fail(true)

      capture_log(fn ->
        assert {:error, :queue_unavailable} = Jobs.enqueue(%{"project" => "web", "kind" => "test"}, "ada")
        assert :none = Jobs.lease("bot", [])
      end)

      assert [%{"status" => "cancelled", "error" => "the queue did not take it"}] = Jobs.list()
      assert Queue.health() == "degraded"
      assert Queue.error_count() > 0

      conn =
        Plug.Test.conn(:get, "/api/health")
        |> Plug.Conn.assign(:principal, Testor.Auth.anonymous())
        |> Testor.Web.Router.call([])

      assert %{"queue" => "degraded"} = JSON.decode!(conn.resp_body)
    end

    test "a heartbeat or finish after the queue's configuration went away", ctx do
      base = FakeSQS.start()
      execution(ctx, sqs(base))
      {:ok, job} = Jobs.enqueue(%{"project" => "web", "kind" => "test"}, "ada")
      {:ok, _} = Jobs.lease("bot", [])
      execution(ctx, sqs(base, %{"queues" => [%{"url" => base <> "other.fifo"}]}))
      assert {:ok, _} = Jobs.heartbeat(job["id"], "bot")
      File.write!(ctx.config, JSON.encode!(%{"execution" => %{"enabled" => true}}))
      assert {:ok, _} = Jobs.finish(job["id"], "bot", %{"exitCode" => 1})
    end

    test "with NATS too", ctx do
      port = FakeNATS.start()
      execution(ctx, nats(port))
      {:ok, job} = Jobs.enqueue(%{"project" => "web", "kind" => "test"}, "ada")
      assert {:ok, %{"id" => id}} = Jobs.lease("bot", [])
      assert id == job["id"]
      assert {:ok, _} = Jobs.heartbeat(id, "bot")
      assert {:ok, _} = Jobs.finish(id, "bot", %{"exitCode" => 0})
      Testor.Test.Helpers.wait_until(fn -> FakeNATS.messages() == [] end)
    end

    test "an API caller hears 503 when the broker refused", ctx do
      base = FakeSQS.start()
      execution(ctx, sqs(base))
      FakeSQS.fail(true)

      Application.put_env(:testor, :auth, %{
        "users" => %{
          "ada" => %{
            "password" => Testor.Auth.Password.hash("correct horse battery", 1000),
            "role" => "admin"
          }
        }
      })

      on_exit(fn -> Application.delete_env(:testor, :auth) end)

      conn =
        Plug.Test.conn(:post, "/api/v1/jobs", JSON.encode!(%{"project" => "web", "kind" => "test"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("authorization", "Basic " <> Base.encode64("ada:correct horse battery"))
        |> Testor.Web.Router.call([])

      assert conn.status == 503
      assert Plug.Conn.get_resp_header(conn, "retry-after") == ["10"]
    end
  end
end
