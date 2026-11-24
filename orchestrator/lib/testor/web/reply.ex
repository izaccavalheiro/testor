defmodule Testor.Web.Reply do
  @moduledoc """
  JSON responses. `/api/v1/*` and `/mcp` answer errors as `{"error": {"code", "message"}}`;
  the dashboard's routes keep `{"error": "message"}`, which its page reads.
  """
  import Plug.Conn

  def json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, JSON.encode!(data))
  end

  def error(conn, status, code, message) do
    body =
      if structured?(conn),
        do: %{"error" => %{"code" => code, "message" => message}},
        else: %{"error" => message}

    json(conn, status, body)
  end

  defp structured?(%Plug.Conn{path_info: ["api", "v1" | _]}), do: true
  defp structured?(%Plug.Conn{path_info: ["mcp" | _]}), do: true
  defp structured?(%Plug.Conn{script_name: ["api", "v1" | _]}), do: true
  defp structured?(_conn), do: false

  @doc "A JSON or form body, up to `limit` bytes: `{:ok, map, conn}` or `{:error, conn}` (already answered)."
  def body_params(conn, limit \\ 65_536) do
    case read_body(conn, length: limit) do
      {:ok, body, conn} ->
        type = conn |> get_req_header("content-type") |> List.first("") |> String.downcase()

        cond do
          String.trim(body) == "" ->
            {:ok, %{}, conn}

          String.starts_with?(type, "application/x-www-form-urlencoded") ->
            {:ok, URI.decode_query(body), conn}

          true ->
            case JSON.decode(body) do
              {:ok, %{} = map} -> {:ok, map, conn}
              _ -> {:error, error(conn, 400, "bad_request", "the body is not a JSON object")}
            end
        end

      _ ->
        {:error, error(conn, 413, "too_large", "the body is larger than #{limit} bytes or was cut off")}
    end
  end

  @doc "Whether `id` is a run id (or a file name) the routes accept."
  def valid_id?(id), do: is_binary(id) and Regex.match?(~r/^[\w.-]{1,200}$/, id)
end
