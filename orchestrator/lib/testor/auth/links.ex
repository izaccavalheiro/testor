defmodule Testor.Auth.Links do
  @moduledoc """
  Signed links to a run's screenshots and artifacts, while authentication is on.

  A link names its run, an expiry minutes away and the person it was made for:

      /s/v2.<expiry>.<viewer>.<mac>/shots/<run>/...
      /s/v2.<expiry>.<viewer>.<mac>/artifacts/<run>/...

    * `<expiry>` is at most `linkMinutes` (auth.json, 15 by default) away. It is rounded to
      half of that, so links made close together are the same and browsers cache the files.
    * `<viewer>` is an HMAC of the user's name (never the name itself), or `-` for a link
      anyone may open (`viewer: none`), which testor makes only for a request without a user
      and records in the audit trail.
    * `<mac>` covers the version, the run, the expiry and the viewer.

  A request that carries credentials (Basic, a token or a session) must be the link's viewer
  and may see the run's project, else it is refused with `403`; a request without any (an
  image in a sandboxed HTML report, a commit status) needs the link alone. So a copied link
  works for minutes only, and never for another signed-in person.

  Data holds links unbound: `prefix/1` gives the placeholder `/s/~`, and `bind/3` replaces it
  in each response body (JSON replies, event streams, MCP) for the principal it goes to. Links
  of version 1 (`/s/<expiry>.<mac>/`, one to two days long, before 0.13) still open until
  they expire; testor no longer makes them.
  """
  alias Testor.{Access, Store}

  @placeholder "/s/~"
  @pattern ~r{/s/~/(shots|artifacts)/([A-Za-z0-9_.~%-]+)}
  @default_ttl 15 * 60
  @max_ttl 24 * 3600

  @doc "The lifetime of a link, in seconds: `linkMinutes` from auth.json, 1 minute to 1 day."
  def ttl(raw) do
    case raw["linkMinutes"] do
      n when is_number(n) and n >= 1 -> min(round(n * 60), @max_ttl)
      _ -> @default_ttl
    end
  end

  @doc "The prefix of a run's file links in data: the placeholder while authentication is on, else `\"\"`."
  def prefix(%{enabled: true, key: key}) when is_binary(key), do: @placeholder
  def prefix(_settings), do: ""

  @doc """
  `body` (a response, as text) with each placeholder link bound to `principal`. Links to the
  runs of projects the principal may not see are left unbound, so they open nothing.
  """
  def bind(body, principal, settings, now \\ System.system_time(:second))

  def bind(body, principal, %{enabled: true, key: key} = settings, now) when is_binary(key) do
    if String.contains?(body, @placeholder <> "/") do
      viewer = viewer_of(principal, settings)

      Regex.replace(@pattern, body, fn whole, area, segment ->
        id = URI.decode(segment)

        if visible?(principal, id) do
          if viewer == "-", do: audit_none(principal, id)
          "/s/" <> cap(id, viewer, settings, now) <> "/" <> area <> "/" <> segment
        else
          whole
        end
      end)
    else
      body
    end
  end

  def bind(body, _principal, _settings, _now), do: body

  @doc "A link's `<cap>` segment for run `id` and `viewer` (a hash from `viewer_hash/2`, or `-`)."
  def cap(id, viewer, %{key: key} = settings, now) do
    step = max(div(link_ttl(settings), 2), 30)
    expires = (div(now, step) + 2) * step
    "v2.#{expires}.#{viewer}." <> mac(key, id, expires, viewer)
  end

  @doc "The viewer of a link made for `principal`: a hash of its user, or `-` for none."
  def viewer_of(%{sub: sub}, settings) when is_binary(sub), do: viewer_hash(sub, settings)
  def viewer_of(_principal, _settings), do: "-"

  def viewer_hash(sub, %{key: key}) do
    :crypto.mac(:hmac, :sha256, key, "viewer\0" <> sub)
    |> binary_part(0, 9)
    |> Base.url_encode64(padding: false)
  end

  @doc """
  Checks a link to run `id` for the request's `principal`: `:ok`, `{:error, :forbidden}` (valid,
  but made for someone else or a project they may not see) or `{:error, :invalid}`.
  """
  def check(cap, id, principal, settings, now \\ System.system_time(:second))

  def check(_cap, _id, _principal, %{enabled: false}, _now), do: :ok

  def check("v2." <> rest, id, principal, %{key: key} = settings, now) when is_binary(key) do
    with [expires, viewer, mac] <- String.split(rest, ".", parts: 3),
         {expires, ""} <- Integer.parse(expires),
         true <- expires > now and expires <= now + link_ttl(settings),
         true <- Plug.Crypto.secure_compare(mac(key, id, expires, viewer), mac) do
      cond do
        not credentials?(principal) -> :ok
        viewer != "-" and viewer != viewer_hash(principal.sub, settings) -> {:error, :forbidden}
        not visible?(principal, id) -> {:error, :forbidden}
        true -> :ok
      end
    else
      _ -> {:error, :invalid}
    end
  end

  def check(cap, id, principal, %{key: key}, now) when is_binary(key) and is_binary(cap) do
    if v1_valid?(cap, id, key, now) do
      if credentials?(principal) and not visible?(principal, id), do: {:error, :forbidden}, else: :ok
    else
      {:error, :invalid}
    end
  end

  def check(_cap, _id, _principal, _settings, _now), do: {:error, :invalid}

  # Version 1 (before 0.13): `<expiry>.<mac>`, bound to the run only, at most three days ahead.
  defp v1_valid?(cap, id, key, now) do
    with [expires, mac] <- String.split(cap, ".", parts: 2),
         {expires, ""} <- Integer.parse(expires),
         true <- expires > now and expires <= now + 3 * 86_400 do
      Plug.Crypto.secure_compare(v1_mac(key, id, expires), mac)
    else
      _ -> false
    end
  end

  @doc false
  def v1_mac(key, id, expires) do
    :crypto.mac(:hmac, :sha256, key, "file\0#{id}\0#{expires}")
    |> binary_part(0, 18)
    |> Base.url_encode64(padding: false)
  end

  defp mac(key, id, expires, viewer) do
    :crypto.mac(:hmac, :sha256, key, "file\0v2\0#{id}\0#{expires}\0#{viewer}")
    |> binary_part(0, 18)
    |> Base.url_encode64(padding: false)
  end

  defp link_ttl(settings), do: Map.get(settings, :link_ttl, @default_ttl)

  defp credentials?(principal), do: is_map(principal) and is_binary(Map.get(principal, :sub))

  # Loose screenshots belong to no run, and so to no project.
  defp visible?(principal, id) do
    case Store.get(id) do
      %{"project" => project} when is_map(principal) -> Access.allowed?(principal, project)
      _ -> true
    end
  end

  defp audit_none(principal, id) do
    who = if is_map(principal), do: to_string(Map.get(principal, :via, "none")), else: "none"
    Testor.Audit.record("link", %{"run" => id, "viewer" => "none", "who" => who})
  end
end
