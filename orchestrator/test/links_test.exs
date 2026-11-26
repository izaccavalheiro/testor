defmodule Testor.LinksTest do
  # Records runs in the store (projects of links): not async.
  use ExUnit.Case, async: false
  alias Testor.Auth.Links

  @key String.duplicate("s", 32)
  @now 1_800_000_000
  @settings %{enabled: true, key: @key, link_ttl: 900}

  setup_all do
    Testor.Test.Helpers.record(%{
      "id" => "20261126-010000-link01",
      "project" => "links-a",
      "status" => "passed"
    })

    :ok
  end

  defp ada, do: %{sub: "ada", scopes: ["read"], via: :basic}

  defp bound(body, principal \\ ada(), settings \\ @settings, now \\ @now),
    do: Links.bind(body, principal, settings, now)

  defp cap_of(body), do: body |> String.split("/") |> Enum.at(2)

  describe "ttl/1" do
    test "linkMinutes, from a minute to a day; 15 minutes by default" do
      assert Links.ttl(%{}) == 900
      assert Links.ttl(%{"linkMinutes" => 5}) == 300
      assert Links.ttl(%{"linkMinutes" => 0.5}) == 900
      assert Links.ttl(%{"linkMinutes" => "5"}) == 900
      assert Links.ttl(%{"linkMinutes" => 100_000}) == 86_400
    end
  end

  describe "bind/4 and check/5" do
    test "a placeholder becomes a link for the viewer, valid until linkMinutes at most" do
      assert Links.prefix(@settings) == "/s/~"
      body = bound(~s({"url":"/s/~/shots/20261126-010000-link01/a.png"}))
      assert body =~ ~r{^\{"url":"/s/v2\.\d+\.[\w-]+\.[\w-]+/shots/20261126-010000-link01/a\.png"\}$}
      cap = cap_of(body)
      ["v2", expires | _] = String.split(cap, ".")
      expires = String.to_integer(expires)
      assert expires > @now + 450 and expires <= @now + 900

      id = "20261126-010000-link01"
      assert Links.check(cap, id, ada(), @settings, @now) == :ok
      assert Links.check(cap, id, ada(), @settings, expires - 1) == :ok
      # No credentials (a sandboxed report): the link alone.
      assert Links.check(cap, id, %{sub: nil, scopes: [], via: :public}, @settings, @now) == :ok
      assert Links.check(cap, id, nil, @settings, @now) == :ok
      # Someone else signed in.
      assert Links.check(cap, id, %{ada() | sub: "bob"}, @settings, @now) == {:error, :forbidden}
      # Expired, another run, another key, garbage.
      assert Links.check(cap, id, ada(), @settings, expires) == {:error, :invalid}
      assert Links.check(cap, "20261126-010000-other", ada(), @settings, @now) == {:error, :invalid}

      assert Links.check(cap, id, ada(), %{@settings | key: String.duplicate("t", 32)}, @now) ==
               {:error, :invalid}

      assert Links.check("v2.x.y", id, ada(), @settings, @now) == {:error, :invalid}
      assert Links.check("v2.1.y.z", id, ada(), @settings, @now) == {:error, :invalid}
      # A link longer than linkMinutes now (the setting was lowered) is refused.
      assert Links.check(cap, id, ada(), %{@settings | link_ttl: 60}, @now) == {:error, :invalid}
    end

    test "the same link for requests close together, so browsers cache the files" do
      body = ~s("/s/~/artifacts/20261126-010000-link01/r/index.html")
      assert bound(body) == bound(body, ada(), @settings, @now + 1)
      assert bound(body) =~ "/artifacts/20261126-010000-link01/r/index.html"
    end

    test "a viewer who may not see the run's project gets no link, and is refused one" do
      restricted = Map.put(ada(), :projects, ["other-*"])
      body = ~s("/s/~/shots/20261126-010000-link01/a.png")
      assert bound(body, restricted) == body

      cap = body |> bound() |> cap_of()
      assert Links.check(cap, "20261126-010000-link01", restricted, @settings, @now) == {:error, :forbidden}
    end

    test "without a user, a link for anyone (viewer none), recorded in the audit trail" do
      body = bound(~s("/s/~/shots/loose.png"), %{sub: nil, scopes: [], via: :public})
      cap = cap_of(body)
      assert [_, _, "-", _] = String.split(cap, ".")
      assert Links.check(cap, "loose.png", ada(), @settings, @now) == :ok
      assert bound(~s("/s/~/shots/loose.png"), nil) =~ ".-."
    end

    test "while authentication is off, or without a placeholder, the body is unchanged" do
      off = %{enabled: false}
      assert Links.prefix(off) == ""
      assert Links.bind("/s/~/shots/x/a.png", ada(), off) == "/s/~/shots/x/a.png"
      assert bound("no links here") == "no links here"
      assert Links.check("anything", "x", ada(), off, @now) == :ok
      assert Links.check(nil, "x", ada(), @settings, @now) == {:error, :invalid}
      assert Links.check("x", "x", ada(), %{enabled: true, key: nil}, @now) == {:error, :invalid}
    end

    test "inside a JSON string (MCP's text content), links are bound too" do
      inner = JSON.encode!(%{"url" => "/s/~/shots/20261126-010000-link01/a.png"})
      outer = JSON.encode!(%{"text" => inner})
      refute bound(outer) =~ "/s/~"
    end
  end

  describe "version 1 links" do
    test "still open until they expire, for viewers of the run's project" do
      id = "20261126-010000-link01"
      expires = (div(@now, 86_400) + 2) * 86_400
      cap = "#{expires}." <> Links.v1_mac(@key, id, expires)

      assert Links.check(cap, id, ada(), @settings, @now) == :ok
      assert Links.check(cap, id, nil, @settings, @now) == :ok
      assert Links.check(cap, id, Map.put(ada(), :projects, ["x"]), @settings, @now) == {:error, :forbidden}
      assert Links.check(cap, id, ada(), @settings, expires) == {:error, :invalid}
      assert Links.check(cap, id, ada(), @settings, expires - 4 * 86_400) == {:error, :invalid}
      assert Links.check("nope", id, ada(), @settings, @now) == {:error, :invalid}
      assert Links.check("1.2", id, ada(), @settings, @now) == {:error, :invalid}
    end
  end
end
