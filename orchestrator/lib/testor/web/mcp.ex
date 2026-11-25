defmodule Testor.Web.MCP do
  @moduledoc """
  A Model Context Protocol server at `/mcp`, over the Streamable HTTP transport, stateless:
  each `POST` carries a JSON-RPC 2.0 message (or a batch) and is answered with
  `application/json`. testor sends no requests or notifications of its own, so `GET` (the
  server's event stream) is refused with 405 and no session id is issued.

  Methods: `initialize`, `ping`, `tools/list`, `tools/call` (see `Testor.MCP.Tools`).
  Notifications and responses from the client are accepted with 202.

  Security: the same authentication as the API (Basic, or better a Bearer token, which an MCP
  client sends as a configured header), the `read` scope to connect and each tool's own scope;
  an `Origin` other than this server's is refused, and the body must be JSON, which a
  cross-site form cannot send. DNS rebinding is stopped before, by `Testor.Web.Edge`.
  """
  import Plug.Conn
  alias Testor.MCP.Tools
  alias Testor.Web.Reply

  @versions ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
  @latest "2025-11-25"
  @max_body 1_048_576

  @instructions "testor records the test runs of a remote test runner: each run's status, spec " <>
                  "results, console output, screenshots and artifacts. Start with get_status or " <>
                  "list_runs; get_run gives a run's spec files and failures; get_run_log with grep " <>
                  "(FAIL, Error, a test name) finds why it failed; wait_for_run waits for a run in " <>
                  "progress to end."

  def versions, do: @versions

  def init(opts), do: opts

  def call(%Plug.Conn{method: "POST"} = conn, _opts) do
    cond do
      not json?(conn) ->
        Reply.error(conn, 415, "unsupported_media_type", "send JSON-RPC with Content-Type: application/json")

      not version_ok?(conn) ->
        Reply.error(
          conn,
          400,
          "unsupported_protocol_version",
          "MCP-Protocol-Version is one of #{Enum.join(@versions, ", ")}"
        )

      true ->
        case read_body(conn, length: @max_body) do
          {:ok, body, conn} ->
            handle(conn, body)

          _ ->
            Reply.error(
              conn,
              413,
              "too_large",
              "the message is larger than #{@max_body} bytes or was cut off"
            )
        end
    end
  end

  def call(conn, _opts) do
    conn
    |> put_resp_header("allow", "POST")
    |> Reply.error(405, "method_not_allowed", "this MCP server is stateless: POST JSON-RPC messages")
  end

  defp handle(conn, body) do
    case JSON.decode(body) do
      {:ok, [_ | _] = batch} ->
        case batch |> Enum.map(&message(&1, conn)) |> Enum.reject(&is_nil/1) do
          [] -> send_resp(conn, 202, "")
          responses -> Reply.json(conn, 200, responses)
        end

      {:ok, %{} = msg} ->
        case message(msg, conn) do
          nil -> send_resp(conn, 202, "")
          response -> Reply.json(conn, 200, response)
        end

      {:ok, _} ->
        Reply.json(conn, 200, rpc_error(nil, -32600, "Invalid Request"))

      {:error, _} ->
        Reply.json(conn, 200, rpc_error(nil, -32700, "Parse error"))
    end
  end

  @doc false
  # A request: its response. A notification or a response from the client: nil.
  def message(%{"jsonrpc" => "2.0", "method" => method, "id" => id} = msg, conn)
      when is_binary(method) and (is_binary(id) or is_integer(id)) do
    case dispatch(method, Map.get(msg, "params", %{}), conn) do
      {:ok, result} -> %{"jsonrpc" => "2.0", "id" => id, "result" => result}
      {:error, code, text} -> rpc_error(id, code, text)
    end
  end

  def message(%{"jsonrpc" => "2.0", "method" => method} = msg, _conn)
      when is_binary(method) and not is_map_key(msg, "id"),
      do: nil

  def message(%{"jsonrpc" => "2.0", "id" => _} = msg, _conn)
      when is_map_key(msg, "result") or is_map_key(msg, "error"),
      do: nil

  def message(msg, _conn) do
    id = if is_map(msg) and (is_binary(msg["id"]) or is_integer(msg["id"])), do: msg["id"]
    rpc_error(id, -32600, "Invalid Request")
  end

  defp dispatch(_method, params, _conn) when not is_map(params),
    do: {:error, -32602, "params must be an object"}

  defp dispatch("initialize", params, _conn) do
    requested = params["protocolVersion"]

    {:ok,
     %{
       "protocolVersion" => if(requested in @versions, do: requested, else: @latest),
       "capabilities" => %{"tools" => %{"listChanged" => false}},
       "serverInfo" => %{
         "name" => "testor",
         "title" => "testor test runner",
         "version" => to_string(Application.spec(:testor, :vsn) || "0.0.0")
       },
       "instructions" => @instructions
     }}
  end

  defp dispatch("ping", _params, _conn), do: {:ok, %{}}

  defp dispatch("tools/list", _params, conn), do: {:ok, %{"tools" => Tools.list(conn.assigns.principal)}}

  defp dispatch("tools/call", %{"name" => name} = params, conn) when is_binary(name) do
    case Map.get(params, "arguments", %{}) do
      args when is_map(args) ->
        case Tools.call(name, args, conn.assigns.principal, base_url(conn)) do
          {:ok, result} -> {:ok, result}
          {:error, :unknown_tool} -> {:error, -32602, "Unknown tool: #{name}"}
        end

      _ ->
        {:error, -32602, "arguments must be an object"}
    end
  end

  defp dispatch("tools/call", _params, _conn), do: {:error, -32602, "name is required"}

  defp dispatch(method, _params, _conn), do: {:error, -32601, "Method not found: #{method}"}

  defp rpc_error(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}

  defp json?(conn) do
    case get_req_header(conn, "content-type") do
      [type | _] -> type |> String.downcase() |> String.starts_with?("application/json")
      _ -> false
    end
  end

  defp version_ok?(conn) do
    case get_req_header(conn, "mcp-protocol-version") do
      [] -> true
      [version | _] -> version in @versions
    end
  end

  defp base_url(conn) do
    host = conn |> get_req_header("host") |> List.first() || "#{conn.host}:#{conn.port}"
    "#{conn.scheme}://#{host}"
  end
end
