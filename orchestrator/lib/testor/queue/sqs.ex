defmodule Testor.Queue.SQS do
  @moduledoc """
  Amazon SQS FIFO queues (and compatibles such as ElasticMQ) as the job queue: the JSON 1.0
  protocol (`X-Amz-Target: AmazonSQS.*`) over `:httpc`, signed with SigV4 and the credentials
  of `Testor.Archive` (environment, or a web identity through STS).

      {"type": "sqs", "region": "eu-west-1", "queues": [{"labels": [], "url": "https://sqs.eu-west-1.amazonaws.com/123456789012/jobs.fifo"}]}

  A job is a message in group `project` (FIFO keeps one message of a group in flight: one job
  per project) with the job id as deduplication id. Queues must be FIFO (`.fifo`) and HTTPS,
  unless `allowHttp` (a local ElasticMQ). A lease receives with the lease as visibility timeout
  and a short long poll (`waitSeconds`, 1 by default: agents ask again).
  """
  @behaviour Testor.Queue
  alias Testor.Aws.SigV4

  @doc false
  def config(raw) do
    region = raw["region"]

    cond do
      not (is_binary(region) and Regex.match?(~r/^[a-z0-9-]{1,30}$/, region)) ->
        {:error, "execution.queue.region is an AWS region"}

      raw["waitSeconds"] not in [nil | Enum.to_list(0..20)] ->
        {:error, "execution.queue.waitSeconds is 0 to 20"}

      not Enum.all?(raw["queues"], &url?(&1["url"], raw["allowHttp"] == true)) ->
        {:error, "each SQS queue's url is an https:// .fifo queue URL"}

      true ->
        {:ok, %{type: "sqs", region: region, wait: raw["waitSeconds"] || 1}}
    end
  end

  defp url?(url, http?) when is_binary(url) do
    uri = URI.parse(url)

    (uri.scheme == "https" or (http? and uri.scheme == "http")) and is_binary(uri.host) and
      String.ends_with?(url, ".fifo")
  end

  defp url?(_url, _http?), do: false

  @doc false
  def queue(raw),
    do: %{labels: raw["labels"] || [], url: raw["url"], name: raw["url"] |> String.split("/") |> List.last()}

  @impl true
  def enqueue(cfg, queue, job) do
    body = %{
      "QueueUrl" => queue.url,
      "MessageBody" => JSON.encode!(%{"id" => job["id"], "project" => job["project"]}),
      "MessageGroupId" => job["project"],
      "MessageDeduplicationId" => job["id"]
    }

    with {:ok, _} <- request(cfg, queue, "SendMessage", body), do: :ok
  end

  @impl true
  def receive(cfg, queue, lease_seconds) do
    body = %{
      "QueueUrl" => queue.url,
      "MaxNumberOfMessages" => 1,
      "VisibilityTimeout" => lease_seconds,
      "WaitTimeSeconds" => cfg.wait
    }

    with {:ok, answer} <- request(cfg, queue, "ReceiveMessage", body) do
      case answer["Messages"] do
        [%{"Body" => text, "ReceiptHandle" => receipt} | _] ->
          case JSON.decode(text) do
            {:ok, %{"id" => id}} when is_binary(id) -> {:ok, %{id: id, receipt: receipt}}
            _ -> {:ok, %{id: nil, receipt: receipt}}
          end

        _ ->
          {:ok, nil}
      end
    end
  end

  @impl true
  def extend(cfg, queue, receipt, seconds) do
    body = %{"QueueUrl" => queue.url, "ReceiptHandle" => receipt, "VisibilityTimeout" => seconds}
    with {:ok, _} <- request(cfg, queue, "ChangeMessageVisibility", body), do: :ok
  end

  @impl true
  def ack(cfg, queue, receipt) do
    with {:ok, _} <-
           request(cfg, queue, "DeleteMessage", %{"QueueUrl" => queue.url, "ReceiptHandle" => receipt}),
         do: :ok
  end

  @impl true
  def release(cfg, queue, receipt), do: extend(cfg, queue, receipt, 0)

  @impl true
  def depth(cfg, queue) do
    body = %{"QueueUrl" => queue.url, "AttributeNames" => ["ApproximateNumberOfMessages"]}

    with {:ok, %{"Attributes" => %{"ApproximateNumberOfMessages" => n}}} <-
           request(cfg, queue, "GetQueueAttributes", body),
         {count, ""} <- Integer.parse(to_string(n)) do
      {:ok, count}
    else
      {:error, _} = error -> error
      _ -> {:error, :bad_answer}
    end
  end

  # One JSON 1.0 call to the queue's endpoint (its URL's scheme and host).
  defp request(cfg, queue, action, body) do
    uri = %URI{URI.parse(queue.url) | path: "/", query: nil}
    payload = JSON.encode!(body)
    hash = SigV4.hex(:crypto.hash(:sha256, payload))
    extra = [{"content-type", "application/x-amz-json-1.0"}, {"x-amz-target", "AmazonSQS." <> action}]

    with {:ok, creds} <- Testor.Aws.credentials(cfg.region) do
      signed =
        SigV4.authorize("POST", uri, extra, hash, creds, cfg.region, "sqs", DateTime.utc_now(),
          content_hash: false
        )

      headers = for {k, v} <- signed, k != "content-type", do: {String.to_charlist(k), String.to_charlist(v)}
      req = {String.to_charlist(URI.to_string(uri)), headers, ~c"application/x-amz-json-1.0", payload}

      case :httpc.request(:post, req, Testor.Webhooks.http_options(), body_format: :binary) do
        {:ok, {{_, 200, _}, _, answer}} ->
          {:ok, decode(answer)}

        {:ok, {{_, status, _}, _, answer}} ->
          {:error, {status, decode(answer)["__type"] || decode(answer)["message"]}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp decode(""), do: %{}

  defp decode(text) do
    case JSON.decode(text) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end
end
