defmodule Testor.Test.FakeAcme do
  @moduledoc """
  An ACME CA for tests (RFC 8555), over HTTPS on a loopback port, with a root of its own: the
  directory, nonces, accounts, orders, authorizations whose HTTP-01 challenge it checks by
  fetching the token from the listener a test names, finalization (it decodes the CSR and
  certifies its key for the order's names) and renewal information. JWS signatures are
  verified. `mode/1` makes it misbehave: `:bad_nonce` (once), `:invalid` (the challenge
  fails), `:wrong_name`, `:wrong_key`, `:directory_error`, `:order_forbidden`, `:no_nonce`,
  `:pending` (authorizations stay pending), `:preauthorized` (they are valid at once),
  `:deactivated`, `:no_http01`, `:bad_token`, `:huge` (a directory over the size cap),
  `:finalize_error`, `:expired` (a certificate already expired).
  """
  use Plug.Router
  require Record

  Record.defrecordp(
    :tbs,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  plug(:match)
  plug(:dispatch)

  @state __MODULE__.State

  @doc """
  Starts it under the test's supervisor, with challenges fetched from `http_port`: returns
  `%{directory, ca_bundle}` (a PEM file of its roots, written to `dir`).
  """
  def start(dir, http_port, opts \\ []) do
    root =
      :public_key.pkix_test_root_cert(~c"Fake ACME root", [
        {:key, {:namedCurve, :secp256r1}},
        {:digest, :sha256}
      ])

    issuer = root.cert |> :public_key.pkix_decode_cert(:otp) |> elem(1) |> elem(6)

    # The server's own TLS chain, for "localhost".
    tls_opts = [{:digest, :sha256}, {:key, {:namedCurve, :secp256r1}}]

    %{server_config: server} =
      :public_key.pkix_test_data(%{
        server_chain: %{
          root: tls_opts,
          peer:
            tls_opts ++ [{:extensions, [{:Extension, {2, 5, 29, 17}, false, [{:dNSName, ~c"localhost"}]}]}]
        },
        client_chain: %{root: tls_opts, peer: tls_opts}
      })

    tls_root = server[:cacerts] |> List.last()

    ExUnit.Callbacks.start_supervised!(%{
      id: @state,
      start:
        {Agent, :start_link,
         [
           fn ->
             %{
               root: root,
               issuer: issuer,
               http_port: http_port,
               nonces: MapSet.new(),
               mode: Keyword.get(opts, :mode),
               validity: Keyword.get(opts, :validity, 90 * 86_400),
               ari: Keyword.get(opts, :ari),
               accounts: %{},
               orders: %{},
               authz: %{},
               certs: %{},
               base: nil,
               serial: 1000
             }
           end,
           [name: @state]
         ]}
    })

    {key_type, key_der} = server[:key]

    pid =
      ExUnit.Callbacks.start_supervised!(
        {Bandit,
         plug: __MODULE__,
         ip: :loopback,
         port: 0,
         startup_log: false,
         scheme: :https,
         certfile: write(dir, "fake-acme-tls.pem", [{:Certificate, server[:cert], :not_encrypted}]),
         keyfile: write(dir, "fake-acme-tls.key", [{key_type, key_der, :not_encrypted}])}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    base = "https://localhost:#{port}"
    Agent.update(@state, &%{&1 | base: base})

    bundle =
      write(dir, "fake-acme-roots.pem", [
        {:Certificate, root.cert, :not_encrypted},
        {:Certificate, tls_root, :not_encrypted}
      ])

    %{directory: base <> "/dir", ca_bundle: bundle, root: root.cert, tls_root: tls_root}
  end

  defp write(dir, name, entries) do
    path = Path.join(dir, name)
    File.write!(path, :public_key.pem_encode(entries))
    path
  end

  def mode(mode), do: Agent.update(@state, &%{&1 | mode: mode})
  def state, do: Agent.get(@state, & &1)

  # --- routes --------------------------------------------------------------------------------

  get "/dir" do
    s = state()

    cond do
      s.mode == :directory_error -> send_resp(conn, 500, "{}")
      s.mode == :huge -> send_resp(conn, 200, :binary.copy("x", 1_100_000))
      true -> directory(conn, s)
    end
  end

  defp directory(conn, s) do
    dir = %{
      "newNonce" => s.base <> "/nonce",
      "newAccount" => s.base <> "/account",
      "newOrder" => s.base <> "/order"
    }

    dir = if s.ari, do: Map.put(dir, "renewalInfo", s.base <> "/ari/"), else: dir
    json(conn, 200, dir)
  end

  head "/nonce" do
    if state().mode == :no_nonce, do: send_resp(conn, 200, ""), else: conn |> nonce() |> send_resp(200, "")
  end

  get "/ari/:id" do
    {start, finish} = state().ari
    json(conn, 200, %{"suggestedWindow" => %{"start" => iso(start), "end" => iso(finish)}})
  end

  post "/account" do
    with_jws(conn, fn conn, protected, _payload ->
      jwk = protected["jwk"]
      kid = state().base <> "/acct/" <> thumbprint(jwk)
      Agent.update(@state, &put_in(&1.accounts[kid], jwk))
      conn |> put_resp_header("location", kid) |> json(201, %{"status" => "valid"})
    end)
  end

  post "/order" do
    with_jws(conn, fn conn, _protected, payload ->
      s = state()

      if s.mode == :order_forbidden do
        problem(conn, 403, "unauthorized", "not allowed")
      else
        id = Integer.to_string(System.unique_integer([:positive]))
        names = Enum.map(payload["identifiers"], & &1["value"])

        authz =
          for name <- names, into: %{} do
            status = if s.mode == :preauthorized, do: "valid", else: "pending"
            {"#{id}-#{name}", %{name: name, status: status, token: token()}}
          end

        Agent.update(@state, fn s ->
          %{
            s
            | orders: Map.put(s.orders, id, %{names: names, status: "pending", cert: nil}),
              authz: Map.merge(s.authz, authz)
          }
        end)

        conn
        |> put_resp_header("location", s.base <> "/order/" <> id)
        |> json(201, order_json(id))
      end
    end)
  end

  post "/order/:id" do
    with_jws(conn, fn conn, _p, _payload -> json(conn, 200, order_json(id)) end)
  end

  post "/authz/:id" do
    with_jws(conn, fn conn, _p, _payload ->
      s = state()
      a = s.authz[id]
      token = if s.mode == :bad_token, do: "bad token!", else: a.token

      http =
        %{"type" => "http-01", "url" => s.base <> "/chall/" <> id, "token" => token}
        |> then(&if(a[:error], do: Map.put(&1, "error", %{"detail" => a.error}), else: &1))

      json(conn, 200, %{
        "status" => if(s.mode == :deactivated, do: "deactivated", else: a.status),
        "identifier" => %{"type" => "dns", "value" => a.name},
        "challenges" =>
          [%{"type" => "dns-01", "url" => s.base <> "/chall/x", "token" => "x"}] ++
            if(s.mode == :no_http01, do: [], else: [http])
      })
    end)
  end

  post "/chall/:id" do
    with_jws(conn, fn conn, protected, _payload ->
      s = state()
      a = s.authz[id]
      expected = a.token <> "." <> thumbprint(s.accounts[protected["kid"]])

      {status, error} =
        cond do
          s.mode == :pending -> {"pending", nil}
          s.mode == :invalid -> {"invalid", "the CA could not fetch the token"}
          fetch(s.http_port, a.name, a.token) == expected -> {"valid", nil}
          true -> {"invalid", "wrong key authorization"}
        end

      Agent.update(@state, &put_in(&1.authz[id], Map.merge(a, %{status: status, error: error})))
      json(conn, 200, %{"type" => "http-01", "status" => "processing"})
    end)
  end

  post "/finalize/:id" do
    with_jws(conn, fn conn, _p, payload -> finalize(conn, id, payload) end)
  end

  defp finalize(conn, id, payload) do
    if state().mode == :finalize_error do
      problem(conn, 403, "badCSR", "no")
    else
      csr = Base.url_decode64!(payload["csr"], padding: false)
      {:CertificationRequest, info, _alg, _sig} = :public_key.der_decode(:CertificationRequest, csr)
      public = csr_public_key(info)
      s = state()
      order = s.orders[id]

      {names, public} =
        case s.mode do
          :wrong_name -> {["other.example.org"], public}
          :wrong_key -> {order.names, other_key()}
          _ -> {order.names, public}
        end

      pem = issue(s, names, public)
      Agent.update(@state, &put_in(&1.orders[id], %{order | status: "valid", cert: pem}))
      json(conn, 200, order_json(id))
    end
  end

  post "/cert/:id" do
    with_jws(conn, fn conn, _p, _payload ->
      conn
      |> put_resp_content_type("application/pem-certificate-chain")
      |> send_resp(200, state().orders[id].cert)
    end)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # --- helpers -------------------------------------------------------------------------------

  defp order_json(id) do
    s = state()
    order = s.orders[id]
    authz = for {aid, a} <- s.authz, String.starts_with?(aid, id <> "-"), do: {aid, a}

    status =
      cond do
        order.status == "valid" -> "valid"
        Enum.all?(authz, fn {_, a} -> a.status == "valid" end) -> "ready"
        Enum.any?(authz, fn {_, a} -> a.status == "invalid" end) -> "invalid"
        true -> "pending"
      end

    %{
      "status" => status,
      "authorizations" => Enum.map(authz, fn {aid, _} -> s.base <> "/authz/" <> aid end),
      "finalize" => s.base <> "/finalize/" <> id
    }
    |> then(&if(status == "valid", do: Map.put(&1, "certificate", s.base <> "/cert/" <> id), else: &1))
  end

  defp with_jws(conn, fun) do
    {:ok, body, conn} = read_body(conn)
    %{"protected" => p64, "payload" => pl64, "signature" => sig} = JSON.decode!(body)
    protected = p64 |> Base.url_decode64!(padding: false) |> JSON.decode!()
    s = state()
    jwk = protected["jwk"] || s.accounts[protected["kid"]]

    cond do
      s.mode == :bad_nonce ->
        mode(nil)
        conn |> nonce() |> problem(400, "badNonce", "stale nonce")

      not MapSet.member?(s.nonces, protected["nonce"]) ->
        conn |> nonce() |> problem(400, "badNonce", "unknown nonce")

      not verify(p64 <> "." <> pl64, sig, jwk) ->
        problem(conn, 400, "malformed", "bad signature")

      true ->
        Agent.update(@state, &%{&1 | nonces: MapSet.delete(&1.nonces, protected["nonce"])})
        payload = if pl64 == "", do: nil, else: pl64 |> Base.url_decode64!(padding: false) |> JSON.decode!()
        fun.(nonce(conn), protected, payload)
    end
  end

  defp verify(message, sig, %{"x" => x, "y" => y}) do
    <<r::256, s::256>> = Base.url_decode64!(sig, padding: false)
    der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})
    point = <<4>> <> Base.url_decode64!(x, padding: false) <> Base.url_decode64!(y, padding: false)
    :public_key.verify(message, :sha256, der, {{:ECPoint, point}, {:namedCurve, :secp256r1}})
  end

  defp verify(_message, _sig, _jwk), do: false

  defp thumbprint(%{"x" => x, "y" => y}),
    do:
      Base.url_encode64(:crypto.hash(:sha256, ~s({"crv":"P-256","kty":"EC","x":"#{x}","y":"#{y}"})),
        padding: false
      )

  defp nonce(conn) do
    n = token()
    Agent.update(@state, &%{&1 | nonces: MapSet.put(&1.nonces, n)})
    put_resp_header(conn, "replay-nonce", n)
  end

  defp token, do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

  defp problem(conn, status, type, detail) do
    json(conn, status, %{"type" => "urn:ietf:params:acme:error:" <> type, "detail" => detail})
  end

  defp json(conn, status, data) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, JSON.encode!(data))
  end

  defp fetch(port, host, token) do
    url = ~c"http://127.0.0.1:#{port}/.well-known/acme-challenge/#{token}"

    case :httpc.request(:get, {url, [{~c"host", String.to_charlist(host)}]}, [], body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} -> body
      _ -> nil
    end
  end

  defp csr_public_key({:CertificationRequestInfo, _v, _subject, {_, {_, oid, _}, bits}, _attrs}) do
    case oid do
      {1, 2, 840, 10045, 2, 1} -> {{:ECPoint, bits}, {:namedCurve, {1, 2, 840, 10045, 3, 1, 7}}}
      {1, 2, 840, 113_549, 1, 1, 1} -> :public_key.der_decode(:RSAPublicKey, bits)
    end
  end

  defp other_key do
    {:ECPrivateKey, _, _, curve, public, _} = :public_key.generate_key({:namedCurve, :secp256r1})
    {{:ECPoint, public}, curve}
  end

  defp issue(s, names, public) do
    Agent.update(@state, &%{&1 | serial: &1.serial + 1})
    now = if s.mode == :expired, do: System.os_time(:second) - 2 * s.validity, else: System.os_time(:second)

    spki =
      case public do
        {{:ECPoint, point}, {:namedCurve, curve}} ->
          {:OTPSubjectPublicKeyInfo, {:PublicKeyAlgorithm, {1, 2, 840, 10045, 2, 1}, {:namedCurve, curve}},
           {:ECPoint, point}}

        {:RSAPublicKey, _, _} = rsa ->
          {:OTPSubjectPublicKeyInfo, {:PublicKeyAlgorithm, {1, 2, 840, 113_549, 1, 1, 1}, :NULL}, rsa}
      end

    aki = :crypto.hash(:sha, s.root.cert) |> binary_part(0, 20)

    der =
      tbs(
        version: :v3,
        serialNumber: s.serial + 1,
        signature: {:SignatureAlgorithm, {1, 2, 840, 10045, 4, 3, 2}, :asn1_NOVALUE},
        issuer: s.issuer,
        validity: {:Validity, utc(now - 60), utc(now - 60 + s.validity)},
        subject: {:rdnSequence, []},
        subjectPublicKeyInfo: spki,
        issuerUniqueID: :asn1_NOVALUE,
        subjectUniqueID: :asn1_NOVALUE,
        extensions: [
          {:Extension, {2, 5, 29, 17}, true, Enum.map(names, &{:dNSName, String.to_charlist(&1)})},
          {:Extension, {2, 5, 29, 35}, false, {:AuthorityKeyIdentifier, aki, :asn1_NOVALUE, :asn1_NOVALUE}}
        ]
      )
      |> :public_key.pkix_sign(s.root.key)

    :public_key.pem_encode([{:Certificate, der, :not_encrypted}])
  end

  defp utc(posix) do
    {{y, mo, d}, {h, mi, sec}} =
      posix |> DateTime.from_unix!() |> DateTime.to_naive() |> NaiveDateTime.to_erl()

    pad = &String.pad_leading(Integer.to_string(&1), 2, "0")

    {:utcTime,
     String.to_charlist(pad.(rem(y, 100)) <> pad.(mo) <> pad.(d) <> pad.(h) <> pad.(mi) <> pad.(sec) <> "Z")}
  end

  defp iso(posix), do: posix |> DateTime.from_unix!() |> DateTime.to_iso8601()
end
