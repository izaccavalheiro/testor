defmodule Testor.Acme do
  @moduledoc """
  Certificates from an ACME CA (RFC 8555: Let's Encrypt, or any other such as a private CA)
  for the built-in TLS, ordered and renewed by testor itself. On with `tls.acme` in
  config.json:

      {"tls": {"acme": {"domains": ["testor.example.com"], "email": "ops@example.com"}}}

    * `directory`: the CA's directory URL, HTTPS only; Let's Encrypt's production one by
      default (`https://acme-staging-v02.api.letsencrypt.org/directory` to try first).
    * `domains`: the names the certificate covers; each must be one testor answers for
      (`TESTOR_ALLOWED_HOSTS`).
    * `email`: the account's contact (optional). Registering accepts the CA's terms of service.
    * `caBundle`: a PEM file of extra CAs to trust, for the CA's API and the chain it issues
      (a private CA, Pebble in tests).
    * `renewBefore`: days before expiry to renew at the latest; by default at two thirds of the
      lifetime, or when the CA's renewal information (RFC 9773) suggests.
    * `httpPort`: a plain-HTTP listener for the HTTP-01 challenges (80 for a public CA). It
      answers the challenges and redirects everything else to HTTPS. Without it, the CA must
      reach testor's own port on 80 another way (a port forward, a proxy).
    * `keyType`: `ec` (P-256, the default) or `rsa` (2048 bits) for the certificate's key.

  The challenge is HTTP-01: `/.well-known/acme-challenge/<token>` is answered before
  authentication, only for the tokens of an order in progress (anything else is 404). TLS-ALPN-01
  is not offered (`:ssl` cannot answer an `acme-tls/1` handshake with a certificate of its own)
  and DNS-01 neither (a DNS provider's API per host): in Kubernetes, cert-manager covers both.

  Files in `<home>/acme/` (mode 0600 for keys): `account.key`, `key.pem`, `cert.pem` (the
  chain), `challenges/<token>`. Until a certificate is issued, a self-signed one serves, so the
  listener starts. A certificate is checked before it is installed (its names, its key, its
  chain to `caBundle` or the system's CAs), then served to new connections at once, without a
  restart (an SNI callback, and `:ssl`'s PEM cache is cleared). Several testors: one orders
  (a claim, `Testor.Cluster`), the others pick the files up from the shared home within a
  minute. A failed order is retried with a backoff (1 minute, doubling, at most 6 hours),
  logged as an error; `testor_tls_expiry_seconds` is the time left.

  Exclusive with `TESTOR_TLS_CERT`/`TESTOR_TLS_KEY`: with both set, these win and ACME is off.
  """
  use GenServer
  require Logger
  alias Testor.Acme.Client
  alias Testor.Config

  @lets_encrypt "https://acme-v02.api.letsencrypt.org/directory"
  @tick 60_000
  @max_backoff 6 * 3600
  @challenge_ttl 3600

  # --- configuration -------------------------------------------------------------------------

  @doc "The settings of `tls.acme`, `nil` when it is off or not valid (logged)."
  def config(user \\ Config.user()) do
    case get_in(user, ["tls", "acme"]) do
      %{} = acme -> validate(acme)
      nil -> nil
      _ -> invalid("tls.acme is not an object")
    end
  end

  defp validate(acme) do
    domains = acme["domains"]
    directory = acme["directory"] || @lets_encrypt

    cond do
      tls_files?() ->
        invalid("TESTOR_TLS_CERT and TESTOR_TLS_KEY are set: they serve, and tls.acme is ignored")

      not is_binary(directory) or not String.starts_with?(directory, "https://") ->
        invalid("tls.acme.directory must be an https:// URL")

      not (is_list(domains) and domains != [] and Enum.all?(domains, &domain?/1)) ->
        invalid("tls.acme.domains must be a list of DNS names")

      (outside = Enum.reject(domains, &allowed?/1)) != [] ->
        invalid("tls.acme.domains #{Enum.join(outside, ", ")} not in TESTOR_ALLOWED_HOSTS")

      not (is_nil(acme["email"]) or (is_binary(acme["email"]) and acme["email"] =~ ~r/^[^\s@:]+@[^\s@]+$/)) ->
        invalid("tls.acme.email is not an email address")

      not (is_nil(acme["httpPort"]) or (is_integer(acme["httpPort"]) and acme["httpPort"] in 1..65_535)) ->
        invalid("tls.acme.httpPort must be a port number")

      acme["keyType"] not in [nil, "ec", "rsa"] ->
        invalid("tls.acme.keyType must be ec or rsa")

      true ->
        %{
          directory: directory,
          domains: Enum.map(domains, &String.downcase/1),
          email: acme["email"],
          ca_bundle: acme["caBundle"],
          renew_before: if(is_number(acme["renewBefore"]), do: round(acme["renewBefore"] * 86_400)),
          http_port: acme["httpPort"],
          key_type: acme["keyType"] || "ec"
        }
    end
  end

  defp invalid(message) do
    Logger.error("acme: #{message}")
    nil
  end

  defp tls_files?,
    do:
      is_binary(Application.get_env(:testor, :tls_cert)) and is_binary(Application.get_env(:testor, :tls_key))

  defp domain?(name),
    do:
      is_binary(name) and
        Regex.match?(~r/^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/i, name)

  defp allowed?(name), do: Testor.Net.host_allowed?(String.downcase(name), [], Config.allowed_hosts())

  def dir, do: Path.join(Config.data_dir(), "acme")
  def cert_file, do: Path.join(dir(), "cert.pem")
  def key_file, do: Path.join(dir(), "key.pem")
  defp account_file, do: Path.join(dir(), "account.key")
  defp challenges_dir, do: Path.join(dir(), "challenges")

  # --- the listeners -------------------------------------------------------------------------

  @doc """
  The HTTPS listener's options while ACME is on: the installed certificate (a self-signed one
  until the first is issued) and the SNI callback that serves a renewed one. `nil` when off.
  """
  def tls_options(cfg \\ config()) do
    if cfg do
      ensure_bootstrap(cfg)

      [
        scheme: :https,
        certfile: cert_file(),
        keyfile: key_file(),
        cipher_suite: :strong,
        thousand_island_options: [transport_options: [sni_fun: &__MODULE__.sni/1]]
      ]
    end
  end

  @doc "The plain-HTTP listener for the challenges (`httpPort`), or `nil`."
  def http_child(cfg \\ config()) do
    if cfg && cfg.http_port do
      Supervisor.child_spec(
        {Bandit,
         plug: Testor.Web.AcmeHttp,
         ip: Application.get_env(:testor, :ip, {0, 0, 0, 0}),
         port: cfg.http_port,
         startup_log: false},
        id: :acme_http
      )
    end
  end

  @doc false
  # :ssl's SNI callback: the installed certificate, or the listener's files until one is.
  def sni(_name) do
    case :persistent_term.get({__MODULE__, :served}, nil) do
      %{chain: chain, key: key} -> [certs_keys: [%{cert: chain, key: key}]]
      nil -> :undefined
    end
  end

  # A self-signed certificate for the first start, so the listener has something to serve.
  defp ensure_bootstrap(cfg) do
    if not (File.exists?(cert_file()) and File.exists?(key_file())) do
      %{cert: cert, key: key} =
        :public_key.pkix_test_root_cert(~c"testor (waiting for #{hd(cfg.domains)})", [
          {:key, {:namedCurve, :secp256r1}},
          {:digest, :sha256}
        ])

      write_files(:public_key.pem_encode([{:Certificate, cert, :not_encrypted}]), key)
      Logger.info("acme: a self-signed certificate serves until #{Enum.join(cfg.domains, ", ")} is issued")
    end
  end

  # --- challenges ----------------------------------------------------------------------------

  @doc "The key authorization of `token` while its order is in progress, else nil."
  def challenge(token) do
    with true <- is_binary(token) and Regex.match?(~r/^[A-Za-z0-9_-]{1,128}$/, token),
         path = Path.join(challenges_dir(), token),
         {:ok, %File.Stat{mtime: mtime}} <- File.stat(path, time: :posix),
         true <- System.os_time(:second) - mtime < @challenge_ttl,
         {:ok, text} <- File.read(path) do
      text
    else
      _ -> nil
    end
  end

  @doc false
  def publish(token, key_authorization) do
    File.mkdir_p!(challenges_dir())
    File.write!(Path.join(challenges_dir(), token), key_authorization)
  end

  @doc false
  def withdraw(token), do: File.rm(Path.join(challenges_dir(), token))

  # --- certificates --------------------------------------------------------------------------

  @doc """
  Checks a PEM chain for `cfg` and `key` (the key it must certify): `{:ok, info}` with its
  `chain` (DER), `key`, `serial`, `not_before`, `not_after` (Unix seconds) and `ari` (its
  renewal-information id), or `{:error, reason}`.
  """
  def check(pem, key, cfg, cacerts \\ nil) do
    chain = for {:Certificate, der, _} <- :public_key.pem_decode(pem), do: der

    with [leaf | _] <- chain,
         {:ok, tbs} <- decode(leaf),
         true <- public_key(tbs) == public_key_of(key) || {:error, :key_mismatch},
         true <-
           Enum.all?(cfg.domains, &:public_key.pkix_verify_hostname(leaf, dns_id: String.to_charlist(&1))) ||
             {:error, :name_mismatch},
         :ok <- chain_trusted(chain, cacerts || cacerts(cfg)) do
      {not_before, not_after} = validity(tbs)

      {:ok,
       %{
         chain: chain,
         key: key_entry(key),
         serial: serial(tbs),
         not_before: not_before,
         not_after: not_after,
         ari: ari_id(tbs)
       }}
    else
      [] -> {:error, :no_certificate}
      {:error, _} = error -> error
    end
  end

  defp decode(der) do
    {:ok, :public_key.pkix_decode_cert(der, :otp)}
  rescue
    _ -> {:error, :bad_certificate}
  end

  # OTPTBSCertificate: version, serial, signature, issuer, validity, subject, key info, ..., extensions.
  defp tbs({:OTPCertificate, tbs, _, _}), do: tbs
  defp serial(tbs), do: elem(tbs(tbs), 2)
  defp public_key(tbs), do: tbs |> tbs() |> elem(7) |> elem(2)
  defp extensions(tbs), do: tbs |> tbs() |> elem(10) |> List.wrap()

  defp validity(tbs) do
    {:Validity, from, to} = elem(tbs(tbs), 5)
    {posix(from), posix(to)}
  end

  @doc false
  def posix({:utcTime, t}) do
    <<yy::binary-2, rest::binary>> = to_string(t)
    year = String.to_integer(yy)
    posix({:generalTime, ~c"#{if year < 50, do: 2000 + year, else: 1900 + year}#{rest}"})
  end

  def posix({:generalTime, t}) do
    <<y::binary-4, mo::binary-2, d::binary-2, h::binary-2, mi::binary-2, s::binary-2, "Z">> = to_string(t)
    [y, mo, d, h, mi, s] = Enum.map([y, mo, d, h, mi, s], &String.to_integer/1)
    :calendar.datetime_to_gregorian_seconds({{y, mo, d}, {h, mi, s}}) - 62_167_219_200
  end

  defp public_key_of({:ECPrivateKey, _, _, _, public, _}), do: {:ECPoint, public}
  defp public_key_of({:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _}), do: {:RSAPublicKey, n, e}

  defp key_entry({:ECPrivateKey, _, _, _, _, _} = key),
    do: {:ECPrivateKey, :public_key.der_encode(:ECPrivateKey, key)}

  defp key_entry(key), do: {:RSAPrivateKey, :public_key.der_encode(:RSAPrivateKey, key)}

  # The chain ends at a certificate a trusted CA issued (or is one).
  defp chain_trusted(chain, cacerts) do
    last = List.last(chain)

    case Enum.find(cacerts, &(&1 == last or :public_key.pkix_is_issuer(last, &1))) do
      nil ->
        {:error, :untrusted}

      anchor ->
        path = chain |> Enum.reverse() |> Enum.reject(&(&1 == anchor))

        case :public_key.pkix_path_validation(anchor, path, []) do
          {:ok, _} -> :ok
          {:error, {:bad_cert, reason}} -> {:error, {:bad_chain, reason}}
        end
    end
  end

  @doc "The CAs trusted for the CA's API and the chains: `caBundle`'s, then the system's."
  def cacerts(cfg) do
    extra =
      with path when is_binary(path) <- cfg.ca_bundle,
           {:ok, pem} <- File.read(path) do
        for {:Certificate, der, _} <- :public_key.pem_decode(pem), do: der
      else
        _ -> []
      end

    extra ++ system_cacerts()
  end

  # The operating system's store (OTP raises when there is none: an order then fails, logged).
  defp system_cacerts, do: Enum.map(:public_key.cacerts_get(), fn {:cert, der, _} -> der end)

  # RFC 9773: base64url(the authority key identifier) "." base64url(the serial's DER bytes).
  defp ari_id(tbs) do
    aki =
      Enum.find_value(extensions(tbs), fn
        {:Extension, {2, 5, 29, 35}, _, {:AuthorityKeyIdentifier, id, _, _}} when is_binary(id) -> id
        _ -> nil
      end)

    if aki do
      bytes = :binary.encode_unsigned(serial(tbs))
      bytes = if :binary.first(bytes) >= 0x80, do: <<0>> <> bytes, else: bytes
      Client.b64(aki) <> "." <> Client.b64(bytes)
    end
  end

  @doc """
  When to renew `info` (Unix seconds): the start of the CA's suggested window (`ari`, a
  `{start, end}`) if given, else two thirds of the lifetime, and no later than `renew_before`
  ahead of expiry.
  """
  def renew_at(info, cfg, ari \\ nil)

  def renew_at(info, cfg, {start, finish})
      when is_integer(start) and is_integer(finish) and finish >= start do
    min(start + :rand.uniform(max(finish - start, 1)) - 1, latest(info, cfg))
  end

  def renew_at(info, cfg, _ari),
    do: min(info.not_before + div(2 * (info.not_after - info.not_before), 3), latest(info, cfg))

  defp latest(info, %{renew_before: before}) when is_integer(before), do: info.not_after - before
  defp latest(info, _cfg), do: info.not_after

  # --- installation --------------------------------------------------------------------------

  # Writes the chain and its key (mode 0600) through temporary files renamed over the old ones.
  defp write_files(pem, key) do
    File.mkdir_p!(dir())
    key_pem = :public_key.pem_encode([:public_key.pem_entry_encode(elem(key_entry(key), 0), key)])

    for {path, data} <- [{key_file(), key_pem}, {cert_file(), pem}] do
      tmp = path <> ".tmp"
      File.write!(tmp, data)
      _ = File.chmod(tmp, 0o600)
      File.rename!(tmp, path)
    end
  end

  @doc false
  def install(pem, key, info) do
    write_files(pem, key)
    serve(info)

    Logger.info("acme: installed certificate #{Integer.to_string(info.serial, 16)} (#{info.not_after})")
  end

  defp serve(info) do
    :persistent_term.put({__MODULE__, :served}, Map.take(info, [:chain, :key, :serial, :not_after]))
    # Connections without SNI read the files through :ssl's PEM cache.
    :ssl.clear_pem_cache()
  end

  @doc "The installed certificate's expiry (Unix seconds), or nil."
  def expiry do
    case :persistent_term.get({__MODULE__, :served}, nil) do
      %{not_after: not_after} -> not_after
      nil -> nil
    end
  end

  # The certificate on disk, checked: {:ok, info} or :none.
  defp installed(cfg) do
    with {:ok, pem} <- File.read(cert_file()),
         {:ok, key_pem} <- File.read(key_file()),
         [entry] <- :public_key.pem_decode(key_pem),
         key = :public_key.pem_entry_decode(entry),
         {:ok, info} <- check(pem, key, cfg) do
      {:ok, info}
    else
      _ -> :none
    end
  end

  defp account_key do
    path = account_file()

    with {:ok, pem} <- File.read(path),
         [entry] <- :public_key.pem_decode(pem) do
      :public_key.pem_entry_decode(entry)
    else
      _ ->
        key = Client.new_key()
        File.mkdir_p!(dir())
        File.write!(path, :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, key)]))
        _ = File.chmod(path, 0o600)
        Logger.info("acme: created the account key #{path}")
        key
    end
  end

  defp new_cert_key(%{key_type: "rsa"}), do: :public_key.generate_key({:rsa, 2048, 65_537})
  defp new_cert_key(_cfg), do: Client.new_key()

  @doc false
  # One order, start to end: {:ok, info} once installed, or {:error, reason}.
  def order(cfg) do
    key = new_cert_key(cfg)

    client = %{
      directory: cfg.directory,
      email: cfg.email,
      cacerts: cacerts(cfg),
      account_key: account_key(),
      publish: &publish/2,
      withdraw: &withdraw/1
    }

    with {:ok, pem} <- Client.order(client, cfg.domains, key),
         {:ok, info} <- check(pem, key, cfg, client.cacerts) do
      install(pem, key, info)
      {:ok, info}
    end
  end

  # The CA's renewal window for `info` (RFC 9773), or nil.
  defp ari(cfg, %{ari: id}) do
    client = %{cacerts: cacerts(cfg)}

    with true <- is_binary(id),
         {:ok, %{"renewalInfo" => base}} <- Client.directory(Map.put(client, :directory, cfg.directory)),
         {:ok, %{status: 200, json: %{"suggestedWindow" => %{"start" => s, "end" => e}}}} <-
           Client.request(client, :get, String.trim_trailing(base, "/") <> "/" <> id, [], nil),
         {:ok, s, _} <- DateTime.from_iso8601(s),
         {:ok, e, _} <- DateTime.from_iso8601(e) do
      {DateTime.to_unix(s), DateTime.to_unix(e)}
    else
      _ -> nil
    end
  end

  # --- the renewer ---------------------------------------------------------------------------

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Checks now (tests, and after a change of tls.acme)."
  def poke, do: send(__MODULE__, :check)

  @impl true
  def init(nil) do
    cfg = config()

    state = %{cfg: cfg, info: nil, mtime: nil, task: nil, failures: 0, timer: nil, renew_at: nil}

    if cfg do
      send(self(), :check)
      {:ok, state}
    else
      :ignore
    end
  end

  @impl true
  def handle_info(:check, %{task: nil} = state) do
    state = reload(state)
    now = System.os_time(:second)

    cond do
      state.info == nil or now >= state.renew_at ->
        # One order per certificate and ten minutes across testors; a retry after a failure
        # is this testor's own (its count is in the key).
        key = "#{state.info && state.info.serial}:#{div(now, 600)}:#{state.failures}"

        if Testor.Cluster.claim("acme", key) do
          Logger.info("acme: ordering a certificate for #{Enum.join(state.cfg.domains, ", ")}")
          {:noreply, %{state | task: run(fn -> order(state.cfg) end, :order)}}
        else
          # Another testor orders: its files are picked up at the next check.
          {:noreply, schedule(state, 30)}
        end

      true ->
        {:noreply, schedule(state, min(state.renew_at - now, div(@tick, 1000)))}
    end
  end

  def handle_info(:check, state), do: {:noreply, state}

  def handle_info({ref, {:order, result}}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | task: nil}

    case result do
      # Read back from the files, as another testor would.
      {:ok, _info} -> {:noreply, %{state | mtime: nil, failures: 0} |> reload() |> schedule(0)}
      {:error, reason} -> {:noreply, failed(state, reason)}
    end
  end

  def handle_info({ref, {:ari, window}}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | task: nil, renew_at: renew_at(state.info, state.cfg, window)}
    {:noreply, schedule(state, 0)}
  end

  # A task that crashed: as a failed order.
  def handle_info({:DOWN, ref, :process, _, reason}, %{task: %Task{ref: ref}} = state),
    do: {:noreply, failed(%{state | task: nil}, {:crashed, reason})}

  def handle_info(_message, state), do: {:noreply, state}

  defp failed(state, reason) do
    backoff = min(60 * Integer.pow(2, state.failures), @max_backoff)

    Logger.error(
      "acme: ordering a certificate for #{Enum.join(state.cfg.domains, ", ")} failed: #{inspect(reason)}; next attempt in #{backoff} s"
    )

    schedule(%{state | failures: state.failures + 1}, backoff)
  end

  defp run(fun, tag) do
    Task.Supervisor.async_nolink(Testor.TaskSupervisor, fn -> {tag, fun.()} end)
  end

  # The files on disk, read again when they changed (another testor renewed, or we did).
  defp reload(state) do
    mtime =
      case File.stat(cert_file(), time: :posix) do
        {:ok, %{mtime: mtime, size: size}} -> {mtime, size}
        _ -> nil
      end

    if mtime == state.mtime do
      state
    else
      case installed(state.cfg) do
        {:ok, info} ->
          serve(info)
          learn(%{state | mtime: mtime}, info)

        :none ->
          %{state | mtime: mtime, info: nil}
      end
    end
  end

  # A new certificate: renew at two thirds, then ask the CA's renewal information for a window.
  defp learn(state, info) do
    %{
      state
      | info: info,
        renew_at: renew_at(info, state.cfg),
        task: run(fn -> ari(state.cfg, info) end, :ari)
    }
  end

  defp schedule(state, seconds) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :check, max(seconds, 0) * 1000)}
  end
end
