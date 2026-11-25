defmodule Testor.Approvals do
  @moduledoc """
  A person's approval for what an AI agent asks to do. `approvals` in config.json names the MCP
  tools that need one:

      "approvals": {"tools": ["delete_run", "cancel_run"], "ttlMinutes": 30}

  When an agent calls such a tool, testor does nothing yet: it records the request (who, the
  tool, its arguments, the run's project), answers the agent with the approval's id, and shows
  it to people (`GET /api/v1/approvals`, the `approval` event, the dashboard). Someone else, with
  the tool's scope on that project, approves it (`POST /api/v1/approvals/:id/approve`): testor
  then calls the tool as the agent, checking the agent's access again, and keeps the result,
  which the agent reads with `get_approval`. A denied request, or one not decided within
  `ttlMinutes` (30 by default), does nothing. Requests live in memory: a restart drops the
  pending ones.
  """
  use GenServer
  alias Testor.{Access, Auth, Config, Events}

  @doc "The tools that need an approval."
  def tools do
    case Config.user()["approvals"] do
      %{"tools" => tools} when is_list(tools) -> Enum.filter(tools, &is_binary/1)
      _ -> []
    end
  end

  defp ttl do
    case Config.user()["approvals"] do
      %{"ttlMinutes" => n} when is_number(n) and n > 0 -> round(n * 60)
      _ -> 1800
    end
  end

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Records a request of `principal` to call `tool` with `args` on `project`'s run."
  def request(tool, args, principal, project, base) do
    GenServer.call(__MODULE__, {:request, tool, args, principal, project, base, ttl()})
  end

  @doc "Approvals, newest first, optionally of one status; those past their time are expired."
  def list(status \\ nil), do: GenServer.call(__MODULE__, {:list, status})

  def get(id), do: GenServer.call(__MODULE__, {:get, id})

  @doc """
  `approver` approves (`:approve`) or denies (`:deny`) approval `id`: `{:ok, approval}` (with the
  tool's result once approved), or `{:error, :not_found | :decided | :own | {:forbidden, scope}}`.
  """
  def decide(id, approver, decision),
    do: GenServer.call(__MODULE__, {:decide, id, approver, decision}, 60_000)

  @impl true
  def init(nil), do: {:ok, %{}}

  @impl true
  def handle_call({:request, tool, args, principal, project, base, ttl}, _from, approvals) do
    now = System.system_time(:second)

    approval = %{
      "id" => "approval-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower),
      "tool" => tool,
      "arguments" => args,
      "project" => project,
      "requestedBy" => Auth.who(principal),
      "status" => "pending",
      "createdAt" => iso(now),
      "expiresAt" => iso(now + ttl),
      principal: principal,
      base: base,
      expires: now + ttl
    }

    Events.broadcast("global", "approval", public(approval))
    {:reply, {:ok, public(approval)}, Map.put(approvals, approval["id"], approval)}
  end

  def handle_call({:list, status}, _from, approvals) do
    approvals = expire(approvals)

    list =
      approvals
      |> Map.values()
      |> Enum.filter(&(status == nil or &1["status"] == status))
      |> Enum.sort_by(&{&1["createdAt"], &1["id"]}, :desc)
      |> Enum.map(&public/1)

    {:reply, list, approvals}
  end

  def handle_call({:get, id}, _from, approvals) do
    approvals = expire(approvals)
    {:reply, approvals |> Map.get(id) |> then(&(&1 && public(&1))), approvals}
  end

  def handle_call({:decide, id, approver, decision}, _from, approvals) do
    approvals = expire(approvals)

    case Map.get(approvals, id) do
      nil ->
        {:reply, {:error, :not_found}, approvals}

      %{"status" => status} when status != "pending" ->
        {:reply, {:error, :decided}, approvals}

      approval ->
        scope = Testor.MCP.Tools.scope(approval["tool"])

        cond do
          approver[:sub] != nil and approver[:sub] == approval.principal[:sub] ->
            {:reply, {:error, :own}, approvals}

          not Access.permits?(approver, approval["project"], scope) ->
            {:reply, {:error, {:forbidden, scope}}, approvals}

          true ->
            approval = settle(approval, approver, decision)
            Events.broadcast("global", "approval", public(approval))
            {:reply, {:ok, public(approval)}, Map.put(approvals, id, approval)}
        end
    end
  end

  defp settle(approval, approver, :deny) do
    Map.merge(approval, %{"status" => "denied", "decidedBy" => Auth.who(approver), "decidedAt" => now_iso()})
  end

  defp settle(approval, approver, :approve) do
    # As the agent that asked: its access is checked again now.
    result =
      Testor.MCP.Tools.execute(approval["tool"], approval["arguments"], approval.principal, approval.base)

    Map.merge(approval, %{
      "status" => if(result["isError"], do: "failed", else: "done"),
      "decidedBy" => Auth.who(approver),
      "decidedAt" => now_iso(),
      "result" => result["structuredContent"] || result["content"]
    })
  end

  defp expire(approvals) do
    now = System.system_time(:second)

    Map.new(approvals, fn
      {id, %{"status" => "pending", expires: expires} = approval} when expires <= now ->
        {id, Map.put(approval, "status", "expired")}

      entry ->
        entry
    end)
  end

  defp public(approval), do: Map.drop(approval, [:principal, :base, :expires])
  defp now_iso, do: iso(System.system_time(:second))
  defp iso(seconds), do: seconds |> DateTime.from_unix!() |> DateTime.to_iso8601()
end
