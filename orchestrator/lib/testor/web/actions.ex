defmodule Testor.Web.Actions do
  @moduledoc "State-changing actions the dashboard's routes, the versioned API and MCP share."
  alias Testor.{Maintenance, Store}

  @doc """
  Cancels a running run: `{:ok, run}` or `{:error, status, code, message}`. The run is asked
  to end itself first (`Store.request_cancel/1`); after `cancel_grace_ms` (5 s) without its
  process ending (a run.ps1 older than 0.3, or one that hangs), it is killed.
  """
  def cancel(id) do
    case Store.get(id) do
      # A remote run is cancelled by its agent: its job tells it at the next heartbeat.
      %{"status" => "running", "remote" => agent, "job" => job} = run when is_binary(agent) ->
        case Testor.Jobs.request_cancel(job) do
          {:ok, _} -> {:ok, run}
          _ -> cancel_here(id)
        end

      _ ->
        cancel_here(id)
    end
  end

  defp cancel_here(id) do
    with %{"status" => "running", "pid" => pid} <- Store.get(id) do
      Store.request_cancel(id)
      grace = Application.get_env(:testor, :cancel_grace_ms, 5_000)
      await_exit(pid, System.monotonic_time(:millisecond) + grace)
    end

    case Store.cancel(id) do
      {:ok, run} -> {:ok, run}
      {:error, :not_found} -> {:error, 404, "not_found", "no such run"}
      {:error, :not_running} -> {:error, 409, "not_running", "the run is not running"}
    end
  end

  defp await_exit(pid, deadline) do
    cond do
      not Testor.OS.alive?(pid) ->
        :gone

      System.monotonic_time(:millisecond) >= deadline ->
        :timeout

      true ->
        Process.sleep(100)
        await_exit(pid, deadline)
    end
  end

  @doc "Deletes a finished run: `{:ok, %{\"deleted\" => id}}` or `{:error, status, code, message}`."
  def delete(id) do
    case Store.delete(id) do
      :ok -> {:ok, %{"deleted" => id}}
      {:error, :running} -> {:error, 409, "running", "the run is still running; cancel it first"}
    end
  end

  @doc "Cleans targets of the last maintenance scan, from `{\"scanId\", \"targets\"}`."
  def maintenance_clean(params) do
    with %{"scanId" => scan_id, "targets" => [_ | _] = targets} <- params,
         true <- Enum.all?(targets, &is_binary/1) do
      case Maintenance.clean(scan_id, targets) do
        {:ok, state} ->
          {:ok, state}

        {:error, :disabled} ->
          {:error, 403, "disabled", "cleaning is off: set maintenance.enabled in config.json"}

        {:error, :busy} ->
          {:error, 409, "busy", "a run, a session or a scan is in progress; try again when it ends"}

        {:error, :stale} ->
          {:error, 409, "stale_scan", "the scan changed; look at the new one and choose again"}

        {:error, {:unknown, ids}} ->
          {:error, 400, "unknown_target", "not in the scan: #{Enum.join(ids, ", ")}"}
      end
    else
      _ -> {:error, 400, "bad_request", ~s(expected {"scanId": "...", "targets": ["..."]})}
    end
  end
end
