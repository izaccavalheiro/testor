defmodule Testor.ClusterTest do
  @moduledoc "Claims and documents: what one testor does once, and what testors share."
  use ExUnit.Case, async: false
  alias Testor.Cluster

  setup do
    on_exit(fn -> System.delete_env("TESTOR_INSTANCE") end)
  end

  test "a claim is won once; documents are kept, listed and forgotten" do
    key = "k-#{System.unique_integer([:positive])}"
    assert Cluster.claim("test", key)
    refute Cluster.claim("test", key)
    assert Cluster.claim("other", key)

    :ok = Cluster.put("note", "a", %{"n" => 1})
    :ok = Cluster.put("note", "b", %{"n" => 2})
    assert Cluster.get("note", "a") == %{"n" => 1}
    assert Cluster.get("note", "nope") == nil
    assert Cluster.list("note") |> Enum.map(& &1["n"]) |> Enum.sort() == [1, 2]

    # Saved only when there is none; removed once.
    assert Cluster.put_new("note", "c", %{"n" => 3})
    refute Cluster.put_new("note", "c", %{"n" => 4})
    assert Cluster.get("note", "c") == %{"n" => 3}
    assert Cluster.delete("note", "c")
    refute Cluster.delete("note", "c")

    assert Cluster.clear() == :ok
    assert Cluster.list("note") == []
    assert Cluster.claim("test", key)
  end

  test "a testor's name: TESTOR_INSTANCE, else its host's" do
    System.put_env("TESTOR_INSTANCE", "testor-0")
    assert Cluster.instance() == "testor-0"
    System.delete_env("TESTOR_INSTANCE")
    assert Cluster.instance() == :inet.gethostname() |> elem(1) |> to_string()
  end
end
