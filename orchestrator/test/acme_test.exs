defmodule Testor.AcmeTest do
  # Writes config.json and <home>/acme, starts listeners: not async.
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Testor.Acme
  alias Testor.Acme.{Client, DER}
  alias Testor.Test.FakeAcme

  @moduletag :tmp_dir
  @domain "www.example.com"

  setup %{tmp_dir: dir} do
    File.rm_rf!(Acme.dir())
    # Claims of earlier tests (an order per ten minutes) must not hold this one's back.
    Testor.Cluster.clear()
    config = Path.join(Testor.Config.data_dir(), "config.json")
    saved = File.read(config)
    Application.put_env(:testor, :acme_poll_ms, 10)
    :persistent_term.erase({Acme, :served})

    on_exit(fn ->
      case saved do
        {:ok, text} -> File.write!(config, text)
        _ -> File.rm(config)
      end

      rm_acme()
      :persistent_term.erase({Acme, :served})
      Application.delete_env(:testor, :acme_poll_ms)
    end)

    http =
      start_supervised!({Bandit, plug: Testor.Web.AcmeHttp, ip: :loopback, port: 0, startup_log: false},
        id: :http
      )

    {:ok, {_, http_port}} = ThousandIsland.listener_info(http)
    %{dir: dir, config: config, http_port: http_port}
  end

  # A renewer stopped at the end of a test may have been writing: try again.
  defp rm_acme(tries \\ 20) do
    case File.rm_rf(Acme.dir()) do
      {:ok, _} -> :ok
      _ when tries > 0 -> Process.sleep(50) && rm_acme(tries - 1)
    end
  end

  defp ca(ctx, opts \\ []), do: FakeAcme.start(ctx.dir, ctx.http_port, opts)

  defp cfg(ca, extra \\ %{}) do
    Map.merge(
      %{
        directory: ca.directory,
        domains: [@domain],
        email: "ops@example.com",
        ca_bundle: ca.ca_bundle,
        renew_before: nil,
        http_port: nil,
        key_type: "ec"
      },
      extra
    )
  end

  defp write_config(ctx, acme) do
    File.write!(ctx.config, JSON.encode!(%{"tls" => %{"acme" => acme}}))
  end

  describe "config/1" do
    test "checks every setting, and is off without tls.acme" do
      assert Acme.config(%{}) == nil

      log =
        capture_log(fn ->
          assert Acme.config(%{"tls" => %{"acme" => 1}}) == nil

          assert Acme.config(%{
                   "tls" => %{"acme" => %{"domains" => [@domain], "directory" => "http://x/dir"}}
                 }) == nil

          assert Acme.config(%{"tls" => %{"acme" => %{"domains" => []}}}) == nil
          assert Acme.config(%{"tls" => %{"acme" => %{"domains" => ["no_dots"]}}}) == nil
          assert Acme.config(%{"tls" => %{"acme" => %{"domains" => ["other.example.org"]}}}) == nil
          assert Acme.config(%{"tls" => %{"acme" => %{"domains" => [@domain], "email" => "no"}}}) == nil
          assert Acme.config(%{"tls" => %{"acme" => %{"domains" => [@domain], "httpPort" => 0}}}) == nil
          assert Acme.config(%{"tls" => %{"acme" => %{"domains" => [@domain], "keyType" => "dsa"}}}) == nil
        end)

      assert log =~ "tls.acme is not an object"
      assert log =~ "https:// URL"
      assert log =~ "list of DNS names"
      assert log =~ "other.example.org not in TESTOR_ALLOWED_HOSTS"
      assert log =~ "not an email address"
      assert log =~ "port number"
      assert log =~ "ec or rsa"

      assert %{
               directory: "https://acme-v02.api.letsencrypt.org/directory",
               domains: [@domain],
               email: nil,
               renew_before: nil,
               http_port: nil,
               key_type: "ec"
             } =
               Acme.config(%{"tls" => %{"acme" => %{"domains" => ["WWW.example.com"]}}})

      assert %{renew_before: 864_000, http_port: 8080, key_type: "rsa", email: "a@b.c"} =
               Acme.config(%{
                 "tls" => %{
                   "acme" => %{
                     "domains" => [@domain],
                     "renewBefore" => 10,
                     "httpPort" => 8080,
                     "keyType" => "rsa",
                     "email" => "a@b.c"
                   }
                 }
               })
    end

    test "or TESTOR_ACME, the same object as JSON" do
      on_exit(fn -> System.delete_env("TESTOR_ACME") end)
      System.put_env("TESTOR_ACME", ~s({"domains": ["#{@domain}"]}))
      assert %{domains: [@domain]} = Acme.config(%{})
      System.put_env("TESTOR_ACME", "{nope")
      assert capture_log(fn -> assert Acme.config(%{}) == nil end) =~ "not an object"
      System.put_env("TESTOR_ACME", "")
      assert Acme.config(%{}) == nil
    end

    test "the certificate files win over it" do
      Application.put_env(:testor, :tls_cert, "c.pem")
      Application.put_env(:testor, :tls_key, "k.pem")

      on_exit(fn ->
        Application.delete_env(:testor, :tls_cert)
        Application.delete_env(:testor, :tls_key)
      end)

      assert capture_log(fn ->
               assert Acme.config(%{"tls" => %{"acme" => %{"domains" => [@domain]}}}) == nil
             end) =~
               "tls.acme is ignored"
    end
  end

  describe "DER" do
    test "a CSR OTP decodes, for an EC and an RSA key, and a long first name" do
      for key <- [Client.new_key(), :public_key.generate_key({:rsa, 2048, 65_537})] do
        csr = DER.csr([@domain, "b.example.com"], key)

        assert {:CertificationRequest, {:CertificationRequestInfo, :v1, _, _, [_]}, _, _} =
                 :public_key.der_decode(:CertificationRequest, csr)
      end

      long = String.duplicate("a", 60) <> ".example.com"
      csr = DER.csr([long], Client.new_key())

      assert {:CertificationRequest, {_, _, {:rdnSequence, []}, _, _}, _, _} =
               :public_key.der_decode(:CertificationRequest, csr)
    end

    test "integers, lengths and object identifiers" do
      assert DER.integer(128) == <<2, 2, 0, 128>>
      assert DER.integer(1) == <<2, 1, 1>>
      assert DER.oid({1, 2, 840, 113_549}) == <<6, 6, 42, 134, 72, 134, 247, 13>>
      assert <<4, 0x82, 1, 44, _::binary>> = DER.octets(:binary.copy(<<0>>, 300))
    end
  end

  describe "an order" do
    test "an account, the HTTP-01 challenge, a certificate checked and installed", ctx do
      ca = ca(ctx)
      cfg = cfg(ca)
      assert {:ok, info} = Acme.order(cfg)

      assert info.not_after > System.os_time(:second) + 80 * 86_400
      assert is_binary(info.ari)
      assert File.exists?(Acme.cert_file()) and File.exists?(Acme.key_file())
      assert [certs_keys: [%{cert: [_leaf], key: {:ECPrivateKey, _}}]] = Acme.sni(@domain)
      assert Acme.expiry() == info.not_after
      assert Testor.Metrics.render() |> IO.iodata_to_binary() =~ "testor_tls_expiry_seconds "
      # The challenges are withdrawn.
      assert File.ls!(Path.join(Acme.dir(), "challenges")) == []

      # A second order reuses the account key, and survives a stale nonce.
      FakeAcme.mode(:bad_nonce)
      assert {:ok, second} = Acme.order(%{cfg | key_type: "rsa"})
      assert second.serial != info.serial
      assert [certs_keys: [%{key: {:RSAPrivateKey, _}}]] = Acme.sni(@domain)
    end

    test "failures: the challenge, the names, the key, the trust, the CA's answers", ctx do
      ca = ca(ctx)
      cfg = cfg(ca)

      FakeAcme.mode(:invalid)
      assert {:error, {:authorization, "invalid", "the CA could not fetch the token"}} = Acme.order(cfg)
      FakeAcme.mode(:pending)
      assert {:error, {:authorization, "timeout", _}} = Acme.order(cfg)
      FakeAcme.mode(:wrong_name)
      assert {:error, :name_mismatch} = Acme.order(cfg)
      FakeAcme.mode(:wrong_key)
      assert {:error, :key_mismatch} = Acme.order(cfg)
      FakeAcme.mode(nil)

      # Its root not trusted: only the CA's TLS root in the bundle.
      only_tls = Path.join(ctx.dir, "tls-only.pem")
      File.write!(only_tls, :public_key.pem_encode([{:Certificate, ca.tls_root, :not_encrypted}]))
      assert {:error, :untrusted} = Acme.order(%{cfg | ca_bundle: only_tls})

      FakeAcme.mode(:deactivated)
      assert {:error, {:authorization, "deactivated", nil}} = Acme.order(cfg)
      FakeAcme.mode(:no_http01)
      assert {:error, {:no_http01, @domain}} = Acme.order(cfg)
      FakeAcme.mode(:bad_token)
      assert {:error, :bad_token} = Acme.order(cfg)
      FakeAcme.mode(:finalize_error)
      assert {:error, {:acme, 403, "urn:ietf:params:acme:error:badCSR", "no"}} = Acme.order(cfg)
      FakeAcme.mode(:expired)
      assert {:error, {:bad_chain, :cert_expired}} = Acme.order(cfg)
      FakeAcme.mode(:huge)
      assert {:error, :too_large} = Acme.order(cfg)
      # Authorizations the account already holds need no challenge.
      FakeAcme.mode(:preauthorized)
      assert {:ok, _} = Acme.order(cfg)

      FakeAcme.mode(:order_forbidden)

      assert {:error, {:acme, 403, "urn:ietf:params:acme:error:unauthorized", "not allowed"}} =
               Acme.order(cfg)

      FakeAcme.mode(:no_nonce)
      assert {:error, :no_nonce} = Acme.order(cfg)
      FakeAcme.mode(:directory_error)
      assert {:error, {:directory, 500}} = Acme.order(cfg)

      # Its TLS not trusted, plain HTTP, nobody there.
      assert {:error, {:http, _}} = Acme.order(%{cfg | ca_bundle: nil})
      assert {:error, {:not_https, _}} = Acme.order(%{cfg | directory: "http://localhost/dir"})
      assert {:error, {:bad_url, nil}} = Client.request(%{}, :get, nil, [], nil)
      assert {:error, {:http, _}} = Acme.order(%{cfg | directory: "https://localhost:1/dir"})
    end

    test "checks: no certificate, garbage" do
      cfg = %{domains: [@domain], ca_bundle: nil}
      assert Acme.check("", Client.new_key(), cfg) == {:error, :no_certificate}

      garbage = :public_key.pem_encode([{:Certificate, "not a certificate", :not_encrypted}])
      assert Acme.check(garbage, Client.new_key(), cfg) == {:error, :bad_certificate}
    end
  end

  describe "renewal" do
    test "at two thirds, no later than renewBefore, or in the CA's window" do
      info = %{not_before: 0, not_after: 90}
      assert Acme.renew_at(info, %{renew_before: nil}) == 60
      assert Acme.renew_at(info, %{renew_before: 50}) == 40
      at = Acme.renew_at(info, %{renew_before: nil}, {10, 20})
      assert at in 10..20
      assert Acme.renew_at(info, %{renew_before: nil}, {20, 10}) == 60
    end

    test "times in certificates" do
      assert Acme.posix({:utcTime, ~c"700101000000Z"}) == 0
      assert Acme.posix({:utcTime, ~c"260101000000Z"}) == 1_767_225_600
      assert Acme.posix({:generalTime, ~c"20260101000000Z"}) == 1_767_225_600
    end

    test "the renewer orders, serves without a restart, and renews in the CA's window", ctx do
      now = System.os_time(:second)
      ca = ca(ctx, ari: {now - 10, now - 5})
      write_config(ctx, %{"domains" => [@domain], "directory" => ca.directory, "caBundle" => ca.ca_bundle})

      # The listener first serves a self-signed certificate.
      options = Testor.Application.bandit_options(0)
      assert options[:scheme] == :https
      pid = start_supervised!({Bandit, options}, id: :https)
      {:ok, {_, port}} = ThousandIsland.listener_info(pid)
      first = served(port)

      capture_log(fn ->
        start_supervised!(Acme)
        # The CA's window has passed: it orders, then renews at once.
        Testor.Test.Helpers.wait_until(fn -> FakeAcme.state().serial >= 1002 end)

        Testor.Test.Helpers.wait_until(fn -> served(port) != first and served(port) == current_serial() end)
      end)

      # Checks while it orders, and later ones, are quiet.
      Acme.poke()
      Acme.poke()
      assert is_pid(Process.whereis(Acme))
    end

    test "a failed order is retried later, and logged", ctx do
      ca = ca(ctx, mode: :invalid)
      write_config(ctx, %{"domains" => [@domain], "directory" => ca.directory, "caBundle" => ca.ca_bundle})

      log =
        capture_log(fn ->
          start_supervised!(Acme)
          Testor.Test.Helpers.wait_until(fn -> :sys.get_state(Acme).failures == 1 end)
        end)

      assert log =~ "failed: {:authorization, \"invalid\""
      assert log =~ "next attempt in 60 s"
      # Another testor has claimed the next attempt: this one waits for that one's files.
      assert Testor.Cluster.claim("acme", ":#{div(System.os_time(:second), 600)}:1")
      send(Acme, :check)
      assert %{failures: 1, task: nil} = :sys.get_state(Acme)
    end

    test "without a window from the CA, it renews at two thirds of the lifetime", ctx do
      ca = ca(ctx)
      write_config(ctx, %{"domains" => [@domain], "directory" => ca.directory, "caBundle" => ca.ca_bundle})

      capture_log(fn ->
        start_supervised!(Acme)
        Testor.Test.Helpers.wait_until(fn -> match?(%{info: %{}, task: nil}, :sys.get_state(Acme)) end)
      end)

      %{info: info, renew_at: at} = :sys.get_state(Acme)
      assert at == Acme.renew_at(info, %{renew_before: nil})
      Acme.poke()
      assert %{info: ^info, task: nil} = :sys.get_state(Acme)
    end

    test "a crashed order counts as a failure", ctx do
      ca = ca(ctx)
      write_config(ctx, %{"domains" => [@domain], "directory" => ca.directory, "caBundle" => ca.ca_bundle})
      ref = make_ref()

      capture_log(fn ->
        start_supervised!(Acme)
        :sys.replace_state(Acme, &%{&1 | task: %Task{ref: ref, pid: self(), owner: self(), mfa: {M, :f, 0}}})
        send(Acme, {:DOWN, ref, :process, self(), :boom})
        Testor.Test.Helpers.wait_until(fn -> :sys.get_state(Acme).failures == 1 end)
      end)

      send(Acme, :unexpected)
      assert :sys.get_state(Acme).failures == 1
    end

    test "off without tls.acme" do
      assert Acme.start_link(nil) == :ignore
      assert Acme.tls_options(nil) == nil
      assert Acme.http_child(nil) == nil
      assert Acme.sni(@domain) == :undefined
      assert Acme.expiry() == nil
    end
  end

  defp current_serial do
    {:ok, pem} = File.read(Acme.cert_file())
    [{:Certificate, der, _} | _] = :public_key.pem_decode(pem)
    der |> :public_key.pkix_decode_cert(:otp) |> elem(1) |> elem(2)
  end

  defp served(port) do
    {:ok, socket} =
      :ssl.connect(
        ~c"127.0.0.1",
        port,
        [verify: :verify_none, active: false, server_name_indication: ~c"#{@domain}"],
        5_000
      )

    {:ok, der} = :ssl.peercert(socket)
    :ssl.close(socket)
    der |> :public_key.pkix_decode_cert(:otp) |> elem(1) |> elem(2)
  end

  describe "the challenge listener" do
    test "answers tokens of an order in progress, redirects the certificate's names", ctx do
      Acme.publish("tok_1", "tok_1.thumb")

      get = fn path, host ->
        url = ~c"http://127.0.0.1:#{ctx.http_port}#{path}"
        :httpc.request(:get, {url, [{~c"host", host}]}, [autoredirect: false], body_format: :binary)
      end

      assert {:ok, {{_, 200, _}, _, "tok_1.thumb"}} = get.("/.well-known/acme-challenge/tok_1", ~c"x")
      assert {:ok, {{_, 404, _}, _, _}} = get.("/.well-known/acme-challenge/nope", ~c"x")
      assert {:ok, {{_, 404, _}, _, _}} = get.("/.well-known/acme-challenge/bad%20token", ~c"x")

      # An old token: its order has long ended.
      File.touch!(Path.join([Acme.dir(), "challenges", "tok_1"]), System.os_time(:second) - 7200)
      assert {:ok, {{_, 404, _}, _, _}} = get.("/.well-known/acme-challenge/tok_1", ~c"x")
      Acme.withdraw("tok_1")

      assert {:ok, {{_, 404, _}, _, _}} = get.("/runs", ~c"#{@domain}")
      write_config(ctx, %{"domains" => [@domain]})
      assert {:ok, {{_, 301, _}, headers, _}} = get.("/runs?x=1", ~c"#{@domain}")
      assert {~c"location", ~c"https://#{@domain}:0/runs?x=1"} in headers
      assert {:ok, {{_, 301, _}, headers, _}} = get.("/", ~c"#{@domain}")
      assert {~c"location", ~c"https://#{@domain}:0/"} in headers
      assert {:ok, {{_, 404, _}, _, _}} = get.("/", ~c"other.example.org")

      Application.put_env(:testor, :port, 443)
      on_exit(fn -> Application.put_env(:testor, :port, 0) end)
      assert {:ok, {{_, 301, _}, headers, _}} = get.("/", ~c"#{@domain}")
      assert {~c"location", ~c"https://#{@domain}/"} in headers
    end

    test "the main listener answers them too, before authentication" do
      Acme.publish("tok_2", "tok_2.thumb")
      conn = Plug.Test.conn(:get, "/.well-known/acme-challenge/tok_2") |> Testor.Web.Router.call([])
      assert conn.status == 200 and conn.resp_body == "tok_2.thumb"
      conn = Plug.Test.conn(:get, "/.well-known/acme-challenge/none") |> Testor.Web.Router.call([])
      assert conn.status == 404
    end

    test "its child spec, with httpPort", ctx do
      ca = %{directory: "https://localhost/dir", ca_bundle: nil}
      assert %{id: :acme_http} = Acme.http_child(cfg(ca, %{http_port: 8080}))
      _ = ctx
    end
  end
end
