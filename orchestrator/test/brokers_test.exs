defmodule Testor.BrokersTest do
  @moduledoc """
  The queue contract against real brokers: ElasticMQ (SQS FIFO) and NATS with JetStream.
  Tagged `brokers`, excluded unless TESTOR_BROKERS=1 (CI's brokers job starts them):
  TESTOR_SQS_ENDPOINT (http://127.0.0.1:9324) and TESTOR_NATS_PORT (4222).
  """
  use ExUnit.Case, async: false
  alias Testor.Queue

  @moduletag :brokers

  setup do
    System.put_env("AWS_ACCESS_KEY_ID", "x")
    System.put_env("AWS_SECRET_ACCESS_KEY", "x")

    on_exit(fn ->
      System.delete_env("AWS_ACCESS_KEY_ID")
      System.delete_env("AWS_SECRET_ACCESS_KEY")
    end)
  end

  defp contract(cfg) do
    [queue] = cfg.queues
    id = "job-#{System.unique_integer([:positive])}"
    job = %{"id" => id, "project" => "p-#{id}"}
    assert :ok = cfg.adapter.enqueue(cfg, queue, job)
    assert :ok = cfg.adapter.enqueue(cfg, queue, job)
    assert {:ok, %{id: ^id, receipt: r1}} = cfg.adapter.receive(cfg, queue, 30)
    assert :ok = cfg.adapter.extend(cfg, queue, r1, 30)
    assert :ok = cfg.adapter.release(cfg, queue, r1)

    assert {:ok, %{id: ^id, receipt: r2}} =
             Testor.Test.Helpers.wait_until(fn -> ok_message(cfg.adapter.receive(cfg, queue, 30)) end)

    assert :ok = cfg.adapter.ack(cfg, queue, r2)
    assert {:ok, 0} = cfg.adapter.depth(cfg, queue)
  end

  defp ok_message({:ok, %{} = m}), do: {:ok, m}
  defp ok_message(_), do: nil

  test "ElasticMQ" do
    endpoint = System.get_env("TESTOR_SQS_ENDPOINT", "http://127.0.0.1:9324")
    name = "testor-#{System.unique_integer([:positive])}.fifo"
    body = JSON.encode!(%{"QueueName" => name, "Attributes" => %{"FifoQueue" => "true"}})

    headers = [
      {~c"x-amz-target", ~c"AmazonSQS.CreateQueue"},
      {~c"authorization", ~c"AWS4-HMAC-SHA256 Credential=x/20260101/elasticmq/sqs/aws4_request"}
    ]

    {:ok, {{_, 200, _}, _, answer}} =
      :httpc.request(
        :post,
        {String.to_charlist(endpoint <> "/"), headers, ~c"application/x-amz-json-1.0", body},
        [],
        body_format: :binary
      )

    url = JSON.decode!(answer)["QueueUrl"]

    cfg =
      Queue.config(%{
        "queue" => %{
          "type" => "sqs",
          "region" => "elasticmq",
          "allowHttp" => true,
          "waitSeconds" => 0,
          "queues" => [%{"url" => url}]
        }
      })

    contract(cfg)
  end

  test "NATS JetStream" do
    port = String.to_integer(System.get_env("TESTOR_NATS_PORT", "4222"))
    subject = "testor.ci.q#{System.unique_integer([:positive])}"

    cfg =
      Queue.config(%{
        "queue" => %{
          "type" => "nats",
          "url" => "nats://127.0.0.1:#{port}",
          "tls" => false,
          "stream" => "TESTOR_CI#{System.unique_integer([:positive])}",
          "queues" => [%{"subject" => subject}]
        }
      })

    contract(cfg)
  end
end
