defmodule Testor.Probe do
  @moduledoc """
  A health probe for containers whose image has no HTTP client:

      bin/testor eval 'Testor.Probe.check()'

  asks `GET /api/health` of the server on this machine and exits 0 when it answers 200, 1
  otherwise. It needs only the kernel's TCP, which every release has.
  """

  @doc "`:ok` when the server on `port` answers its health check with 200, else `{:error, reason}`."
  def health(port, timeout \\ 5_000) do
    with {:ok, socket} <- :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], timeout),
         :ok <- :gen_tcp.send(socket, "GET /api/health HTTP/1.0\r\nHost: localhost\r\n\r\n"),
         {:ok, data} <- :gen_tcp.recv(socket, 0, timeout) do
      :gen_tcp.close(socket)
      if Regex.match?(~r{^HTTP/1\.[01] 200 }, data), do: :ok, else: {:error, :unhealthy}
    end
  end

  @doc "Exits the VM with 0 when the server on `TESTOR_PORT` (else 6767) is healthy, 1 otherwise."
  def check do
    port = String.to_integer(System.get_env("TESTOR_PORT", "6767"))
    # Tests set :probe_halt, to see the code instead of stopping.
    halt = Application.get_env(:testor, :probe_halt, &System.halt/1)
    halt.(if health(port) == :ok, do: 0, else: 1)
  end
end
