defmodule Testor.Test.FakeSQS do
  @moduledoc """
  SQS's JSON 1.0 protocol for tests, in memory on a loopback port: SendMessage (FIFO
  deduplication), ReceiveMessage (visibility timeouts; one message of a group in flight),
  ChangeMessageVisibility, DeleteMessage, GetQueueAttributes. It checks requests carry a
  SigV4 authorization. `fail/1`: `true` answers 500, `:empty` an empty 200, `:garbage` a body
  that is not JSON, `:bad_attrs` attributes without the count.
  """
  use Plug.Router
  plug(:match)
  plug(:dispatch)

  @state __MODULE__.State

  def start do
    ExUnit.Callbacks.start_supervised!(%{
      id: @state,
      start:
        {Agent, :start_link,
         [fn -> %{messages: [], seen: MapSet.new(), fail: false, n: 0} end, [name: @state]]}
    })

    pid =
      ExUnit.Callbacks.start_supervised!(
        {Bandit, plug: __MODULE__, ip: :loopback, port: 0, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    "http://127.0.0.1:#{port}/000000000000/"
  end

  def fail(on?), do: Agent.update(@state, &%{&1 | fail: on?})
  def messages, do: Agent.get(@state, & &1.messages)

  post "/" do
    {:ok, body, conn} = read_body(conn)
    [target] = get_req_header(conn, "x-amz-target")
    auth = get_req_header(conn, "authorization")
    req = JSON.decode!(body)
    now = System.os_time(:millisecond)

    cond do
      Agent.get(@state, & &1.fail) == true ->
        json(conn, 500, %{"__type" => "InternalError"})

      Agent.get(@state, & &1.fail) == :empty ->
        send_resp(conn, 200, "")

      Agent.get(@state, & &1.fail) == :garbage ->
        send_resp(conn, 200, "nope")

      Agent.get(@state, & &1.fail) == :bad_attrs ->
        json(conn, 200, %{"Attributes" => %{}})

      not match?(["AWS4-HMAC-SHA256 Credential=" <> _], auth) ->
        json(conn, 403, %{"__type" => "MissingAuthenticationToken"})

      true ->
        json(conn, 200, Agent.get_and_update(@state, &handle(target, req, now, &1)))
    end
  end

  defp handle("AmazonSQS.SendMessage", req, _now, s) do
    if MapSet.member?(s.seen, req["MessageDeduplicationId"]) do
      {%{"MessageId" => "dup"}, s}
    else
      m = %{
        id: "m#{s.n}",
        queue: req["QueueUrl"],
        body: req["MessageBody"],
        group: req["MessageGroupId"],
        visible: 0,
        receipt: nil
      }

      {%{"MessageId" => m.id},
       %{s | messages: s.messages ++ [m], seen: MapSet.put(s.seen, req["MessageDeduplicationId"]), n: s.n + 1}}
    end
  end

  defp handle("AmazonSQS.ReceiveMessage", req, now, s) do
    busy = for m <- s.messages, m.visible > now, into: MapSet.new(), do: m.group

    case Enum.find(
           s.messages,
           &(&1.queue == req["QueueUrl"] and &1.visible <= now and not MapSet.member?(busy, &1.group))
         ) do
      nil ->
        {%{}, s}

      m ->
        receipt = "r#{System.unique_integer([:positive])}"
        m2 = %{m | visible: now + req["VisibilityTimeout"] * 1000, receipt: receipt}

        {%{"Messages" => [%{"MessageId" => m.id, "Body" => m.body, "ReceiptHandle" => receipt}]},
         %{s | messages: replace(s.messages, m, m2)}}
    end
  end

  defp handle("AmazonSQS.ChangeMessageVisibility", req, now, s) do
    case Enum.find(s.messages, &(&1.receipt == req["ReceiptHandle"])) do
      nil ->
        {%{}, s}

      m ->
        {%{}, %{s | messages: replace(s.messages, m, %{m | visible: now + req["VisibilityTimeout"] * 1000})}}
    end
  end

  defp handle("AmazonSQS.DeleteMessage", req, _now, s),
    do: {%{}, %{s | messages: Enum.reject(s.messages, &(&1.receipt == req["ReceiptHandle"]))}}

  defp handle("AmazonSQS.GetQueueAttributes", req, now, s) do
    n = Enum.count(s.messages, &(&1.queue == req["QueueUrl"] and &1.visible <= now))
    {%{"Attributes" => %{"ApproximateNumberOfMessages" => Integer.to_string(n)}}, s}
  end

  defp replace(list, old, new), do: Enum.map(list, &if(&1 == old, do: new, else: &1))

  defp json(conn, status, data),
    do: conn |> put_resp_content_type("application/x-amz-json-1.0") |> send_resp(status, JSON.encode!(data))
end
