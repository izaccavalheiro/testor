defmodule Testor.Net do
  @moduledoc """
  Addresses and host names: CIDR ranges, the private ranges testor answers without
  authentication, and the `Host` allow-list that stops DNS rebinding.

  DNS rebinding needs a name the attacker controls that resolves to this machine. A `Host`
  that is an IP literal cannot be such a name, so it is always accepted; a name must be
  `localhost`, this machine's name (also as `<name>.local`), or listed in
  `TESTOR_ALLOWED_HOSTS` (`testor.example.com`, `.example.com` for every subdomain, `*` for
  any name).
  """
  import Bitwise

  # Loopback, RFC 1918, link-local, CGNAT (Tailscale's 100.64.0.0/10), and their IPv6
  # counterparts: loopback, unique local (fc00::/7) and link-local (fe80::/10).
  @private ~w(127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10
              ::1/128 fc00::/7 fe80::/10)
  @loopback ~w(127.0.0.0/8 ::1/128)

  @doc "A CIDR range (`10.0.0.0/8`) or a single address: `{:ok, {address, bits}}` or `:error`."
  def parse_cidr(text) when is_binary(text) do
    {address, bits} =
      case String.split(String.trim(text), "/", parts: 2) do
        [address, bits] -> {address, Integer.parse(bits)}
        [address] -> {address, nil}
      end

    with {:ok, ip} <- :inet.parse_strict_address(String.to_charlist(address)),
         max = if(tuple_size(ip) == 4, do: 32, else: 128),
         {:ok, bits} <- bits(bits, max) do
      {:ok, {ip, bits}}
    else
      _ -> :error
    end
  end

  defp bits(nil, max), do: {:ok, max}
  defp bits({n, ""}, max) when n >= 0 and n <= max, do: {:ok, n}
  defp bits(_, _max), do: :error

  @doc "CIDR ranges from a comma- or space-separated list; entries that do not parse are dropped."
  def parse_cidrs(nil), do: []

  def parse_cidrs(text) when is_binary(text) do
    for part <- String.split(text, [",", " "], trim: true), {:ok, cidr} <- [parse_cidr(part)], do: cidr
  end

  @doc "Whether `ip` (a tuple) is in one of `cidrs`. IPv4-mapped IPv6 addresses count as IPv4."
  def in_cidrs?(ip, cidrs) do
    ip = unmap(ip)
    Enum.any?(cidrs, fn {net, bits} -> same_family?(ip, net) and prefix(ip, bits) == prefix(net, bits) end)
  end

  @doc "Whether `ip` is loopback, private, link-local or in the CGNAT range."
  def private?(ip), do: in_cidrs?(ip, ranges(@private))

  @doc "Whether `ip` is a loopback address."
  def loopback?(ip), do: in_cidrs?(ip, ranges(@loopback))

  defp ranges(list), do: Enum.map(list, fn cidr -> elem(parse_cidr(cidr), 1) end)

  defp unmap({0, 0, 0, 0, 0, 0xFFFF, a, b}), do: {a >>> 8, a &&& 0xFF, b >>> 8, b &&& 0xFF}
  defp unmap(ip), do: ip

  defp same_family?(a, b), do: tuple_size(a) == tuple_size(b)

  defp prefix(ip, bits) do
    width = if tuple_size(ip) == 4, do: 8, else: 16
    value = ip |> Tuple.to_list() |> Enum.reduce(0, fn part, acc -> (acc <<< width) + part end)
    value >>> (tuple_size(ip) * width - bits)
  end

  @doc "The address a client is, behind the proxies in `trusted`: `X-Forwarded-For` read from the right."
  def client_ip(remote, forwarded, trusted) do
    if trusted != [] and in_cidrs?(remote, trusted) do
      forwarded
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> Enum.reverse()
      |> Enum.reduce_while(remote, fn entry, current ->
        case :inet.parse_strict_address(String.to_charlist(entry)) do
          {:ok, ip} -> if in_cidrs?(ip, trusted), do: {:cont, ip}, else: {:halt, ip}
          _ -> {:halt, current}
        end
      end)
    else
      remote
    end
  end

  @doc """
  Whether a request's `Host` may be answered: an IP literal, `localhost`, one of `names` (this
  machine's) or `<name>.local`, or a match in `allowed` (exact, `.suffix`, or `*`).
  """
  def host_allowed?(host, names, allowed) do
    host = normalize(host)

    cond do
      host == "" -> false
      "*" in allowed -> true
      ip_literal?(host) -> true
      host == "localhost" or String.ends_with?(host, ".localhost") -> true
      host in names or Enum.any?(names, &(host == &1 <> ".local")) -> true
      true -> Enum.any?(allowed, &matches?(host, &1))
    end
  end

  defp matches?(host, "." <> _ = suffix), do: String.ends_with?(host, suffix)
  defp matches?(host, "*." <> suffix), do: String.ends_with?(host, "." <> suffix)
  defp matches?(host, name), do: host == name

  defp ip_literal?("[" <> rest), do: ip_literal?(String.trim_trailing(rest, "]"))
  defp ip_literal?(host), do: match?({:ok, _}, :inet.parse_strict_address(String.to_charlist(host)))

  @doc "A host name lower-cased, without a port or a trailing dot (`[::1]` keeps its brackets)."
  def normalize(host) when is_binary(host) do
    host = String.downcase(String.trim(host))

    host =
      case host do
        "[" <> _ -> host |> String.split("]", parts: 2) |> hd() |> Kernel.<>("]")
        _ -> host |> String.split(":") |> then(&if(length(&1) == 2, do: hd(&1), else: host))
      end

    String.trim_trailing(host, ".")
  end

  def normalize(_), do: ""

  @doc "Names from a comma- or space-separated list, normalized."
  def parse_hosts(nil), do: []
  def parse_hosts(text), do: text |> String.split([",", " "], trim: true) |> Enum.map(&normalize/1)

  @doc "This machine's names (`machine_names/1`), looked up once."
  def machine_names do
    with nil <- :persistent_term.get({__MODULE__, :names}, nil) do
      names = machine_names(&:inet.gethostbyname/1)
      :persistent_term.put({__MODULE__, :names}, names)
      names
    end
  end

  @doc "This machine's names: its host name and, when `resolve` knows it, its fully qualified name."
  def machine_names(resolve) do
    {:ok, name} = :inet.gethostname()
    name = normalize(to_string(name))

    fqdn =
      case resolve.(String.to_charlist(name)) do
        {:ok, {:hostent, full, _, _, _, _}} -> [normalize(to_string(full))]
        _ -> []
      end

    Enum.uniq([name | fqdn])
  end
end
