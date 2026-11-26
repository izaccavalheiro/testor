defmodule Testor.Queue do
  @moduledoc """
  The queue port: who dispatches queued jobs to agents. By default testor's own store does
  (files or PostgreSQL, `Testor.Jobs`); with `execution.queue` in config.json, a broker does:

      "execution": {"enabled": true, "queue": {"type": "sqs", "region": "eu-west-1",
        "queues": [{"labels": ["mutation"], "url": "https://sqs.eu-west-1.amazonaws.com/1234/heavy.fifo"},
                   {"labels": [], "url": "https://sqs.eu-west-1.amazonaws.com/1234/jobs.fifo"}]}}

  `type` is `sqs` (`Testor.Queue.SQS`, FIFO queues) or `nats` (`Testor.Queue.NATS`, JetStream).
  The broker only dispatches: job records (status, attempts, the run) stay in the store, and
  agents keep leasing through testor's API, so they never hold broker credentials. A message
  holds the job's id and project; testor reads everything else from its own record, so a
  forged message cannot carry a command or labels.

  A job goes to the first queue whose `labels` it carries all of (a job matching none is
  refused); an agent receives from every queue whose labels it has. The lifecycle maps onto
  the broker: queued is a message; a lease receives it with a visibility timeout of the lease;
  a heartbeat extends it; finishing deletes it; a lease that runs out lets it come back; a job
  cancelled while queued is deleted when it is next received; one already leased for its
  project is put back.
  """
  require Logger

  @callback enqueue(cfg :: map, queue :: map, job :: map) :: :ok | {:error, term}
  @callback receive(cfg :: map, queue :: map, lease_seconds :: pos_integer) ::
              {:ok, nil | %{id: String.t(), receipt: String.t()}} | {:error, term}
  @callback extend(cfg :: map, queue :: map, receipt :: String.t(), seconds :: pos_integer) ::
              :ok | {:error, term}
  @callback ack(cfg :: map, queue :: map, receipt :: String.t()) :: :ok | {:error, term}
  @callback release(cfg :: map, queue :: map, receipt :: String.t()) :: :ok | {:error, term}
  @callback depth(cfg :: map, queue :: map) :: {:ok, non_neg_integer} | {:error, term}

  @adapters %{"sqs" => Testor.Queue.SQS, "nats" => Testor.Queue.NATS}

  @doc "The broker settings, `nil` for the store's own dispatch; invalid ones are logged and off."
  def config(execution \\ Testor.Jobs.settings()) do
    case execution["queue"] do
      nil -> nil
      %{"type" => type} = raw when is_map_key(@adapters, type) -> check(@adapters[type], raw)
      _ -> invalid("execution.queue.type is sqs or nats")
    end
  end

  defp check(adapter, raw) do
    queues = raw["queues"]

    with true <- (is_list(queues) and queues != []) || "execution.queue.queues is a list of queues",
         true <- Enum.all?(queues, &labels?/1) || "each queue's labels is a list of names",
         {:ok, cfg} <- adapter.config(raw) do
      Map.merge(cfg, %{adapter: adapter, queues: Enum.map(queues, &adapter.queue/1)})
    else
      {:error, why} -> invalid(why)
      why -> invalid(why)
    end
  end

  defp labels?(%{"labels" => labels}) when is_list(labels), do: Enum.all?(labels, &is_binary/1)
  defp labels?(%{} = queue), do: not Map.has_key?(queue, "labels")
  defp labels?(_), do: false

  defp invalid(why) do
    Logger.error("queue: #{why}; jobs are dispatched by the store")
    nil
  end

  @doc "The queue job `labels` go to: the first whose labels they all carry, or nil."
  def queue_for(cfg, labels), do: Enum.find(cfg.queues, &Enum.all?(&1.labels, fn l -> l in labels end))

  @doc "The queues an agent with `labels` receives from."
  def queues_for(cfg, labels), do: Enum.filter(cfg.queues, &Enum.all?(&1.labels, fn l -> l in labels end))

  # --- calls, with their health --------------------------------------------------------------

  @doc "Runs `fun` (a broker call), counting a failure for health and metrics."
  def call(cfg, name, fun) do
    case fun.() do
      {:error, reason} = error ->
        :counters.add(errors(), 1, 1)
        :persistent_term.put({__MODULE__, :failed}, System.monotonic_time(:second))
        Logger.warning("queue: #{name} failed on #{cfg.type}: #{inspect(reason)}")
        error

      ok ->
        ok
    end
  end

  defp errors do
    case :persistent_term.get({__MODULE__, :errors}, nil) do
      nil ->
        ref = :counters.new(1, [:atomics])
        :persistent_term.put({__MODULE__, :errors}, ref)
        ref

      ref ->
        ref
    end
  end

  @doc "Broker calls that failed since start (`testor_queue_errors_total`)."
  def error_count, do: :counters.get(errors(), 1)

  @doc "`ok`, `degraded` (a call failed in the last minute: queued jobs wait), or nil without a broker."
  def health(cfg \\ config()) do
    if cfg do
      case :persistent_term.get({__MODULE__, :failed}, nil) do
        at when is_integer(at) -> if System.monotonic_time(:second) - at < 60, do: "degraded", else: "ok"
        nil -> "ok"
      end
    end
  end

  @doc false
  def reset, do: :persistent_term.erase({__MODULE__, :failed})
end
