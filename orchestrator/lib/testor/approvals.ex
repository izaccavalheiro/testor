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
  `ttlMinutes` (30 by default), does nothing. Requests are kept as `Testor.Cluster` keeps
  documents: in memory for one testor (a restart drops pending ones), in PostgreSQL for several.
  """
  use GenServer
  alias Testor.{Access, Auth, Cluster, Config, Events}

  @kind "approval"

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

  # Requests are documents of Testor.Cluster (ETS, or PostgreSQL shared by several testors);
  # this process puts one testor's decisions in a row, and a claim one across testors.
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Records a request of `principal` to call `tool` with `args` on `project`'s run."
  def request(tool, args, principal, project, base) do
    GenServer.call(__MODULE__, {:request, tool, args, principal, project, base, ttl()})
  end

  @doc "Approvals, newest first, optionally of one status; those past their time are expired."
  def list(status) do
    now = System.system_time(:second)

    Cluster.list(@kind)
    |> Enum.map(&expired(&1, now))
    |> Enum.filter(&(status == nil or &1["status"] == status))
    |> Enum.sort_by(&{&1["createdAt"], &1["id"]}, :desc)
    |> Enum.map(&public/1)
  end

  def get(id) do
    case Cluster.get(@kind, id) do
      nil -> nil
      approval -> approval |> expired(System.system_time(:second)) |> public()
    end
  end

  @doc """
  `approver` approves (`:approve`) or denies (`:deny`) approval `id`: `{:ok, approval}` (with the
  tool's result once approved), or `{:error, :not_found | :decided | :own | {:forbidden, scope}}`.
  """
  def decide(id, approver, decision),
    do: GenServer.call(__MODULE__, {:decide, id, approver, decision}, 60_000)

  @doc "Forgets every approval (tests)."
  def reset, do: Cluster.clear()

  @doc "Makes approval `id` past its time (tests)."
  def expire(id), do: Cluster.put(@kind, id, Map.put(Cluster.get(@kind, id), "expires", 0))

  @impl true
  def init(nil), do: {:ok, nil}

  @impl true
  def handle_call({:request, tool, args, principal, project, base, ttl}, _from, state) do
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
      "expires" => now + ttl,
      # Who asked, to act as them once approved; and the server's URL, for the tool's links.
      "principal" => principal_doc(principal),
      "base" => base
    }

    :ok = Cluster.put(@kind, approval["id"], approval)
    Events.broadcast("global", "approval", public(approval))
    {:reply, {:ok, public(approval)}, state}
  end

  def handle_call({:decide, id, approver, decision}, _from, state) do
    case Cluster.get(@kind, id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      approval ->
        approval = expired(approval, System.system_time(:second))
        requester = principal(approval["principal"])
        scope = Testor.MCP.Tools.scope(approval["tool"])

        cond do
          approval["status"] != "pending" ->
            {:reply, {:error, :decided}, state}

          approver[:sub] != nil and approver[:sub] == requester[:sub] ->
            {:reply, {:error, :own}, state}

          not Access.permits?(approver, approval["project"], scope) ->
            {:reply, {:error, {:forbidden, scope}}, state}

          # One decision across testors: the first to claim it.
          true ->
            if Cluster.claim("approval", id),
              do: commit(approval, requester, approver, decision, state),
              else: {:reply, {:error, :decided}, state}
        end
    end
  end

  defp commit(approval, requester, approver, decision, state) do
    approval = settle(approval, requester, approver, decision)
    :ok = Cluster.put(@kind, approval["id"], approval)
    Events.broadcast("global", "approval", public(approval))
    {:reply, {:ok, public(approval)}, state}
  end

  defp settle(approval, _requester, approver, :deny) do
    Map.merge(approval, %{"status" => "denied", "decidedBy" => Auth.who(approver), "decidedAt" => now_iso()})
  end

  defp settle(approval, requester, approver, :approve) do
    # As the agent that asked: its access is checked again now.
    result = Testor.MCP.Tools.execute(approval["tool"], approval["arguments"], requester, approval["base"])

    Map.merge(approval, %{
      "status" => if(result["isError"], do: "failed", else: "done"),
      "decidedBy" => Auth.who(approver),
      "decidedAt" => now_iso(),
      "result" => result["structuredContent"] || result["content"]
    })
  end

  defp expired(%{"status" => "pending", "expires" => expires} = approval, now) when expires <= now,
    do: Map.put(approval, "status", "expired")

  defp expired(approval, _now), do: approval

  # A principal as JSON holds it, and back (role per project included).
  defp principal_doc(principal) do
    %{
      "sub" => principal[:sub],
      "scopes" => principal[:scopes] || [],
      "via" => to_string(principal[:via]),
      "projects" => principal[:projects],
      "projectRoles" =>
        principal[:project_roles] &&
          Enum.map(principal[:project_roles], &Map.new(&1, fn {k, v} -> {to_string(k), v} end))
    }
  end

  defp principal(doc) do
    roles =
      doc["projectRoles"] &&
        Enum.map(doc["projectRoles"], &%{pattern: &1["pattern"], role: &1["role"], scopes: &1["scopes"]})

    %{
      sub: doc["sub"],
      scopes: doc["scopes"],
      via: String.to_existing_atom(doc["via"]),
      projects: doc["projects"],
      project_roles: roles
    }
  end

  defp public(approval), do: Map.drop(approval, ["principal", "base", "expires"])
  defp now_iso, do: iso(System.system_time(:second))
  defp iso(seconds), do: seconds |> DateTime.from_unix!() |> DateTime.to_iso8601()
end
