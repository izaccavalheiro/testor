defmodule Testor.Acme.Client do
  @moduledoc """
  An ACME client (RFC 8555) over `:httpc`, peers verified: an account, an order for a set of
  DNS names, their HTTP-01 challenges, the finalization with a CSR (`Testor.Acme.DER`), and
  the certificate chain. Requests are JWS signed with the account's P-256 key (ES256); a
  `badNonce` answer is retried with the fresh nonce it carries.

  `order/3` runs the whole exchange. The challenges are published with `publish` (a function
  of a token and its key authorization) and withdrawn with `withdraw` once the order ends,
  however it ends.
  """

  @max_body 1_048_576
  @timeout 30_000
  @attempts 60

  @doc "A new account key: an EC key on P-256."
  def new_key, do: :public_key.generate_key({:namedCurve, :secp256r1})

  @doc "The JWK of `key`'s public half."
  def jwk({:ECPrivateKey, _, _, _, <<4, x::binary-32, y::binary-32>>, _}),
    do: %{"crv" => "P-256", "kty" => "EC", "x" => b64(x), "y" => b64(y)}

  @doc "`key`'s JWK thumbprint (RFC 7638): its members in lexicographic order, no white space."
  def thumbprint(key) do
    %{"x" => x, "y" => y} = jwk(key)
    b64(:crypto.hash(:sha256, ~s({"crv":"P-256","kty":"EC","x":"#{x}","y":"#{y}"})))
  end

  @doc """
  Orders a certificate for `domains` with `cert_key`'s CSR: `{:ok, pem_chain}` or `{:error,
  reason}`. `cfg` holds `directory`, `email` (or nil), `cacerts` (to verify the CA's own
  HTTPS), `account_key`, `publish` and `withdraw`.
  """
  def order(cfg, domains, cert_key) do
    Process.put({__MODULE__, :tokens}, [])
    contact = if cfg.email, do: ["mailto:" <> cfg.email], else: []
    identifiers = Enum.map(domains, &%{"type" => "dns", "value" => &1})

    # newAccount with the key: a new account (201) or the one the key already has (200).
    with {:ok, dir} <- directory(cfg),
         {:ok, ctx} <- new_nonce(cfg, dir),
         {:ok, account, ctx} <-
           call(cfg, ctx, dir["newAccount"], %{"termsOfServiceAgreed" => true, "contact" => contact}, [
             200,
             201
           ]),
         ctx = %{ctx | kid: account.headers["location"]},
         {:ok, order, ctx} <- call(cfg, ctx, dir["newOrder"], %{"identifiers" => identifiers}, [201]),
         {:ok, ctx} <- authorize(cfg, ctx, order.json["authorizations"] || []) do
      finish(cfg, ctx, order.headers["location"], order.json, domains, cert_key)
    end
  after
    Enum.each(Process.delete({__MODULE__, :tokens}) || [], cfg.withdraw)
  end

  defp finish(cfg, ctx, order_url, order, domains, cert_key) do
    csr = Testor.Acme.DER.csr(domains, cert_key)

    with {:ok, order, ctx} <- poll(cfg, ctx, order_url, order, "ready", :order),
         {:ok, final, ctx} <- call(cfg, ctx, order["finalize"], %{"csr" => b64(csr)}, [200, 201]),
         {:ok, order, ctx} <- poll(cfg, ctx, order_url, final.json, "valid", :order),
         {:ok, cert, _ctx} <- call(cfg, ctx, order["certificate"], :get, [200]) do
      {:ok, cert.body}
    end
  end

  # Each authorization: valid already, or its HTTP-01 challenge published, answered and awaited.
  defp authorize(cfg, ctx, urls) do
    Enum.reduce_while(urls, {:ok, ctx}, fn url, {:ok, ctx} ->
      case authorize_one(cfg, ctx, url) do
        {:ok, ctx} -> {:cont, {:ok, ctx}}
        error -> {:halt, error}
      end
    end)
  end

  defp authorize_one(cfg, ctx, url) do
    with {:ok, %{json: authz}, ctx} <- call(cfg, ctx, url, :get, [200]) do
      challenge = Enum.find(authz["challenges"] || [], &(&1["type"] == "http-01")) || %{}
      token = challenge["token"]

      cond do
        authz["status"] == "valid" ->
          {:ok, ctx}

        authz["status"] != "pending" ->
          {:error, {:authorization, authz["status"], detail(authz)}}

        not is_binary(token) ->
          {:error, {:no_http01, get_in(authz, ["identifier", "value"])}}

        not Regex.match?(~r/^[A-Za-z0-9_-]{1,128}$/, token) ->
          {:error, :bad_token}

        true ->
          :ok = cfg.publish.(token, token <> "." <> thumbprint(cfg.account_key))
          Process.put({__MODULE__, :tokens}, [token | Process.get({__MODULE__, :tokens}, [])])

          with {:ok, _, ctx} <- call(cfg, ctx, challenge["url"], %{}, [200]),
               {:ok, _, ctx} <- poll(cfg, ctx, url, %{"status" => "pending"}, "valid", :authorization),
               do: {:ok, ctx}
      end
    end
  end

  # Fetches `url` until its status is `done`: {:ok, json, ctx}; a status that will not change
  # (invalid, or valid when `done` is ready), or @attempts passed ("timeout"), is an error.
  defp poll(cfg, ctx, url, current, done, kind, attempt \\ 0) do
    status = current["status"]

    cond do
      status == done ->
        {:ok, current, ctx}

      status in ["pending", "processing", "ready"] and attempt < @attempts ->
        if attempt > 0, do: Process.sleep(Application.get_env(:testor, :acme_poll_ms, 1000))

        with {:ok, %{json: json}, ctx} <- call(cfg, ctx, url, :get, [200]),
             do: poll(cfg, ctx, url, json, done, kind, attempt + 1)

      true ->
        {:error, {kind, if(attempt >= @attempts, do: "timeout", else: status), detail(current)}}
    end
  end

  defp detail(json) do
    get_in(json, ["error", "detail"]) ||
      Enum.find_value(json["challenges"] || [], &get_in(&1, ["error", "detail"]))
  end

  # --- requests ------------------------------------------------------------------------------

  @doc "The CA's directory."
  def directory(cfg) do
    with {:ok, resp} <- request(cfg, :get, cfg.directory, [], nil) do
      case resp do
        %{status: 200, json: %{"newNonce" => _, "newAccount" => _, "newOrder" => _} = dir} -> {:ok, dir}
        _ -> {:error, {:directory, resp.status}}
      end
    end
  end

  defp new_nonce(cfg, dir) do
    with {:ok, resp} <- request(cfg, :head, dir["newNonce"], [], nil) do
      if nonce = resp.headers["replay-nonce"], do: {:ok, %{nonce: nonce, kid: nil}}, else: {:error, :no_nonce}
    end
  end

  # A JWS POST whose answer has one of `statuses`: {:ok, resp, ctx}, else the CA's problem.
  defp call(cfg, ctx, url, payload, statuses) do
    with {:ok, resp, ctx} <- post(cfg, ctx, url, payload) do
      if resp.status in statuses,
        do: {:ok, resp, ctx},
        else: {:error, {:acme, resp.status, resp.json["type"], resp.json["detail"]}}
    end
  end

  @doc false
  # A JWS POST (payload `:get` for POST-as-GET), retried on badNonce: {:ok, resp, ctx}.
  def post(cfg, ctx, url, payload, retries \\ 3) do
    body = jws(cfg.account_key, ctx, url, payload)

    with {:ok, resp} <- request(cfg, :post, url, [], body) do
      ctx = %{ctx | nonce: resp.headers["replay-nonce"] || ctx.nonce}

      if resp.status == 400 and resp.json["type"] == "urn:ietf:params:acme:error:badNonce" and retries > 0,
        do: post(cfg, ctx, url, payload, retries - 1),
        else: {:ok, resp, ctx}
    end
  end

  defp jws(key, ctx, url, payload) do
    protected =
      %{"alg" => "ES256", "nonce" => ctx.nonce, "url" => url}
      |> then(&if ctx.kid, do: Map.put(&1, "kid", ctx.kid), else: Map.put(&1, "jwk", jwk(key)))
      |> JSON.encode!()
      |> b64()

    payload = if payload == :get, do: "", else: b64(JSON.encode!(payload))
    der = :public_key.sign(protected <> "." <> payload, :sha256, key)
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    JSON.encode!(%{"protected" => protected, "payload" => payload, "signature" => b64(<<r::256, s::256>>)})
  end

  @doc "An HTTPS request to the CA, its peer verified against `cfg.cacerts`: `{:ok, resp}`."
  def request(cfg, method, url, headers, body) when is_binary(url) do
    if String.starts_with?(url, "https://") do
      do_request(cfg, method, url, headers, body)
    else
      {:error, {:not_https, url}}
    end
  end

  def request(_cfg, _method, url, _headers, _body), do: {:error, {:bad_url, url}}

  defp do_request(cfg, method, url, headers, body) do
    headers = [{~c"user-agent", ~c"testor-acme"} | headers]

    req =
      case body do
        nil -> {String.to_charlist(url), headers}
        body -> {String.to_charlist(url), headers, ~c"application/jose+json", body}
      end

    ssl = [
      verify: :verify_peer,
      cacerts: cfg.cacerts,
      depth: 4,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    http = [ssl: ssl, timeout: @timeout, connect_timeout: 10_000, autoredirect: false]

    case :httpc.request(method, req, http, body_format: :binary) do
      {:ok, {{_, status, _}, headers, body}} when byte_size(body) <= @max_body ->
        headers = Map.new(headers, fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end)
        {:ok, %{status: status, headers: headers, body: body, json: decode(body)}}

      {:ok, _} ->
        {:error, :too_large}

      {:error, reason} ->
        {:error, {:http, reason}}
    end
  end

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  @doc false
  def b64(bytes), do: Base.url_encode64(bytes, padding: false)
end
