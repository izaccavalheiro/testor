defmodule Testor.ProbeTest do
  use ExUnit.Case, async: false
  alias Testor.Probe

  test "a healthy server, a closed port, and the exit codes check/2 gives" do
    port = Application.fetch_env!(:testor, :test_port)
    assert Probe.health(port) == :ok

    {:ok, listener} = :gen_tcp.listen(0, active: false)
    {:ok, closed} = :inet.port(listener)
    :gen_tcp.close(listener)
    assert {:error, _} = Probe.health(closed)

    Application.put_env(:testor, :probe_halt, & &1)

    on_exit(fn ->
      System.delete_env("TESTOR_PORT")
      Application.delete_env(:testor, :probe_halt)
    end)

    System.put_env("TESTOR_PORT", to_string(port))
    assert Probe.check() == 0
    System.put_env("TESTOR_PORT", to_string(closed))
    assert Probe.check() == 1
  end

  test "a server that answers something else is not healthy" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(listener)

    Task.start(fn ->
      {:ok, socket} = :gen_tcp.accept(listener)
      {:ok, _} = :gen_tcp.recv(socket, 0)
      :gen_tcp.send(socket, "HTTP/1.1 503 Service Unavailable\r\n\r\n")
      :gen_tcp.close(socket)
    end)

    assert Probe.health(port) == {:error, :unhealthy}
  end
end
