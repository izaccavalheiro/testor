defmodule Testor.NetTest do
  use ExUnit.Case, async: true
  alias Testor.Net

  describe "CIDR ranges" do
    test "parse_cidr/1 reads ranges and single addresses, IPv4 and IPv6" do
      assert Net.parse_cidr("10.0.0.0/8") == {:ok, {{10, 0, 0, 0}, 8}}
      assert Net.parse_cidr(" 192.168.1.7 ") == {:ok, {{192, 168, 1, 7}, 32}}
      assert Net.parse_cidr("fc00::/7") == {:ok, {{0xFC00, 0, 0, 0, 0, 0, 0, 0}, 7}}
      assert Net.parse_cidr("::1") == {:ok, {{0, 0, 0, 0, 0, 0, 0, 1}, 128}}
      assert Net.parse_cidr("10.0.0.0/33") == :error
      assert Net.parse_cidr("10.0.0.0/x") == :error
      assert Net.parse_cidr("10.0.0/8") == :error
      assert Net.parse_cidr("example.com") == :error
    end

    test "parse_cidrs/1 keeps the entries that parse" do
      assert Net.parse_cidrs(nil) == []
      assert Net.parse_cidrs("10.0.0.0/8, nope 127.0.0.1") == [{{10, 0, 0, 0}, 8}, {{127, 0, 0, 1}, 32}]
    end

    test "in_cidrs?/2 compares prefixes of the same family; IPv4-mapped IPv6 counts as IPv4" do
      cidrs = Net.parse_cidrs("10.0.0.0/8 2001:db8::/32")
      assert Net.in_cidrs?({10, 200, 3, 4}, cidrs)
      refute Net.in_cidrs?({11, 0, 0, 1}, cidrs)
      assert Net.in_cidrs?({0x2001, 0xDB8, 1, 0, 0, 0, 0, 1}, cidrs)
      refute Net.in_cidrs?({0x2001, 0xDB9, 0, 0, 0, 0, 0, 1}, cidrs)
      assert Net.in_cidrs?({0, 0, 0, 0, 0, 0xFFFF, 0x0A01, 0x0203}, cidrs)
      assert Net.in_cidrs?({1, 2, 3, 4}, Net.parse_cidrs("0.0.0.0/0"))
    end

    test "private?/1 and loopback?/1" do
      for ip <- [
            {127, 0, 0, 1},
            {10, 1, 2, 3},
            {172, 16, 0, 1},
            {192, 168, 0, 1},
            {169, 254, 1, 1},
            {100, 64, 0, 1},
            {0, 0, 0, 0, 0, 0, 0, 1},
            {0xFD00, 0, 0, 0, 0, 0, 0, 1},
            {0xFE80, 0, 0, 0, 0, 0, 0, 1}
          ] do
        assert Net.private?(ip), inspect(ip)
      end

      for ip <- [{8, 8, 8, 8}, {172, 32, 0, 1}, {100, 128, 0, 1}, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}] do
        refute Net.private?(ip), inspect(ip)
      end

      assert Net.loopback?({127, 9, 9, 9})
      refute Net.loopback?({10, 0, 0, 1})
    end
  end

  describe "client_ip/3" do
    @trusted Net.parse_cidrs("127.0.0.1 10.0.0.0/8")

    test "only a trusted proxy names the client, from the right" do
      assert Net.client_ip({127, 0, 0, 1}, ["203.0.113.9"], []) == {127, 0, 0, 1}
      assert Net.client_ip({198, 51, 100, 1}, ["203.0.113.9"], @trusted) == {198, 51, 100, 1}
      assert Net.client_ip({127, 0, 0, 1}, ["1.1.1.1, 203.0.113.9", "10.0.0.5"], @trusted) == {203, 0, 113, 9}
    end

    test "a chain of trusted proxies ends at the last one; garbage stops the walk" do
      assert Net.client_ip({127, 0, 0, 1}, ["10.0.0.9, 10.0.0.5"], @trusted) == {10, 0, 0, 9}
      assert Net.client_ip({127, 0, 0, 1}, ["203.0.113.9, unknown"], @trusted) == {127, 0, 0, 1}
      assert Net.client_ip({127, 0, 0, 1}, [], @trusted) == {127, 0, 0, 1}
    end
  end

  describe "host_allowed?/3" do
    test "IP literals, localhost and this machine's names need no list" do
      for host <- [
            "127.0.0.1",
            "100.64.1.2:6767",
            "[::1]:6767",
            "[fe80::1]",
            "localhost",
            "LOCALHOST:6767",
            "app.localhost",
            "runner",
            "Runner.local",
            "runner."
          ] do
        assert Net.host_allowed?(host, ["runner"], []), host
      end
    end

    test "other names only when listed: exactly, as a suffix, or *" do
      refute Net.host_allowed?("evil.example", ["runner"], [])
      refute Net.host_allowed?("runner.evil.example", ["runner"], [])
      refute Net.host_allowed?("[evil]", ["runner"], [])
      refute Net.host_allowed?("", ["runner"], [])
      refute Net.host_allowed?(nil, ["runner"], ["*"])
      assert Net.host_allowed?("testor.example.com:443", [], ["testor.example.com"])
      assert Net.host_allowed?("a.example.com", [], [".example.com"])
      assert Net.host_allowed?("b.example.com", [], ["*.example.com"])
      refute Net.host_allowed?("example.com", [], ["*.example.com"])
      assert Net.host_allowed?("anything", [], ["*"])
    end

    test "parse_hosts/1 normalizes a list" do
      assert Net.parse_hosts(nil) == []

      assert Net.parse_hosts("Testor.Example.com., .example.org  *") == [
               "testor.example.com",
               ".example.org",
               "*"
             ]
    end

    test "machine_names/1 is the host name, and its full name when the resolver knows it" do
      {:ok, name} = :inet.gethostname()
      name = String.downcase(to_string(name))
      assert Net.machine_names(fn _ -> {:error, :nxdomain} end) == [name]

      assert Net.machine_names(fn _ -> {:ok, {:hostent, ~c"Box.Example.Lan", [], :inet, 4, []}} end) ==
               [name, "box.example.lan"]

      assert Net.machine_names() == Net.machine_names()
    end
  end
end
