defmodule Testor.TLSTest do
  @moduledoc "Built-in TLS: TESTOR_TLS_CERT and TESTOR_TLS_KEY make the server speak HTTPS, with HSTS."
  use ExUnit.Case, async: false
  import Plug.Test

  @tag :tmp_dir
  test "with a certificate and a key the server speaks HTTPS only", %{tmp_dir: dir} do
    # A throwaway chain from OTP (SHA-256: its default digest is one modern TLS refuses).
    opts = [{:digest, :sha256}, {:key, {:namedCurve, :secp256r1}}]

    %{server_config: server} =
      :public_key.pkix_test_data(%{
        server_chain: %{root: opts, peer: opts},
        client_chain: %{root: opts, peer: opts}
      })

    {key_type, key_der} = server[:key]
    cert = Path.join(dir, "cert.pem")
    key = Path.join(dir, "key.pem")
    File.write!(cert, :public_key.pem_encode([{:Certificate, server[:cert], :not_encrypted}]))
    File.write!(key, :public_key.pem_encode([{key_type, key_der, :not_encrypted}]))

    Application.put_env(:testor, :tls_cert, cert)
    Application.put_env(:testor, :tls_key, key)

    on_exit(fn ->
      Application.delete_env(:testor, :tls_cert)
      Application.delete_env(:testor, :tls_key)
    end)

    options = Testor.Application.bandit_options(0)
    assert options[:scheme] == :https and options[:cipher_suite] == :strong
    {:ok, pid} = start_supervised({Bandit, options})
    {:ok, {_, port}} = ThousandIsland.listener_info(pid)

    {:ok, socket} =
      :ssl.connect(~c"127.0.0.1", port, [verify: :verify_none, active: false, mode: :binary], 5_000)

    {:ok, protocol} =
      :ssl.connection_information(socket, [:protocol]) |> then(fn {:ok, [protocol: p]} -> {:ok, p} end)

    assert protocol in [:"tlsv1.2", :"tlsv1.3"]
    :ok = :ssl.send(socket, "GET /api/health HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n\r\n")
    {:ok, response} = :ssl.recv(socket, 0, 5_000)
    assert response =~ "HTTP/1.1 200"
    assert response =~ "strict-transport-security: max-age=31536000"

    # Plain HTTP to the same port is not answered as HTTP.
    {:ok, plain} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    :gen_tcp.send(plain, "GET /api/health HTTP/1.1\r\nhost: localhost\r\n\r\n")
    refute match?({:ok, "HTTP/1.1 200" <> _}, :gen_tcp.recv(plain, 0, 2_000))
  end

  test "without both files the options are plain HTTP, and HSTS only rides on HTTPS" do
    refute Keyword.has_key?(Testor.Application.bandit_options(0), :scheme)
    conn = conn(:get, "http://www.example.com/api/health") |> Testor.Web.Router.call([])
    assert Plug.Conn.get_resp_header(conn, "strict-transport-security") == []
  end
end
