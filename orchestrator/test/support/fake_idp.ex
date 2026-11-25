defmodule Testor.Test.FakeIdP do
  @moduledoc """
  An OpenID Connect provider for tests, on a loopback port: discovery, a JWKS, and a token
  endpoint that answers the codes a test registers (`code/3`) with an ID token signed with
  RS256, ES256 or EdDSA. It records the token requests, so tests can check PKCE and the
  client's authentication.
  """
  use Plug.Router

  @p256 {1, 2, 840, 10045, 3, 1, 7}

  plug(:match)
  plug(:dispatch)

  @doc "Starts it under the test's supervisor: returns its issuer URL."
  def start do
    keys = %{"RS256" => key("RS256"), "ES256" => key("ES256"), "EdDSA" => key("EdDSA")}
    ExUnit.Callbacks.start_supervised!(%{id: __MODULE__.State, start: {Agent, :start_link, [fn -> %{} end, [name: __MODULE__.State]]}})
    pid = ExUnit.Callbacks.start_supervised!({Bandit, plug: __MODULE__, ip: :loopback, port: 0, startup_log: false})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    issuer = "http://127.0.0.1:#{port}"

    Agent.update(__MODULE__.State, fn _ ->
      %{issuer: issuer, keys: keys, published: Map.keys(keys), meta: %{}, codes: %{}, requests: [], token: nil}
    end)

    issuer
  end

  @doc "A new key for `alg`: `{kid, private, jwk}`."
  def key(alg) do
    kid = "#{alg}-#{System.unique_integer([:positive])}"

    case alg do
      "RS256" ->
        {:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _} = private = :public_key.generate_key({:rsa, 2048, 65_537})
        {kid, private, %{"kty" => "RSA", "n" => b64(:binary.encode_unsigned(n)), "e" => b64(:binary.encode_unsigned(e))}}

      "ES256" ->
        {:ECPrivateKey, _, _, _, <<4, x::binary-32, y::binary-32>>, _} = private = :public_key.generate_key({:namedCurve, @p256})
        {kid, private, %{"kty" => "EC", "crv" => "P-256", "x" => b64(x), "y" => b64(y)}}

      "EdDSA" ->
        {public, seed} = :crypto.generate_key(:eddsa, :ed25519)
        {kid, seed, %{"kty" => "OKP", "crv" => "Ed25519", "x" => b64(public)}}
    end
  end

  def state, do: Agent.get(__MODULE__.State, & &1)
  def update(fun), do: Agent.update(__MODULE__.State, fun)

  @doc "Merges `meta` into the discovery document."
  def meta(meta), do: update(&%{&1 | meta: meta})

  @doc "Replaces the key of `alg` (the provider rolled its keys)."
  def roll(alg), do: update(&put_in(&1, [:keys, alg], key(alg)))

  @doc "The JWKS publishes only these algorithms' keys."
  def publish(algs), do: update(&%{&1 | published: algs})

  @doc "The next token response, instead of an ID token: `{status, body}`."
  def token_response(response), do: update(&%{&1 | token: response})

  @doc "Registers `code`: its ID token holds `claims`, signed with `alg`; its PKCE `challenge`."
  def code(code, claims, challenge, alg \\ "RS256", header \\ %{}) do
    update(&put_in(&1, [:codes, code], %{claims: claims, challenge: challenge, alg: alg, header: header}))
  end

  @doc "An ID token: `claims` signed with the provider's key for `alg`."
  def sign(claims, alg, header \\ %{}) do
    {kid, private, _jwk} = state().keys[alg]
    header = Map.merge(%{"alg" => alg, "typ" => "JWT", "kid" => kid}, header)
    input = b64(JSON.encode!(header)) <> "." <> b64(JSON.encode!(claims))
    input <> "." <> b64(signature(alg, input, private))
  end

  defp signature("RS256", input, private), do: :public_key.sign(input, :sha256, private)

  defp signature("ES256", input, private) do
    der = :public_key.sign(input, :sha256, private)
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    <<r::unsigned-256, s::unsigned-256>>
  end

  defp signature("EdDSA", input, seed), do: :crypto.sign(:eddsa, :none, input, [seed, :ed25519])

  get "/.well-known/openid-configuration" do
    %{issuer: issuer, meta: meta} = state()

    json(
      conn,
      200,
      Map.merge(
        %{
          "issuer" => issuer,
          "authorization_endpoint" => issuer <> "/authorize",
          "token_endpoint" => issuer <> "/token",
          "jwks_uri" => issuer <> "/jwks"
        },
        meta
      )
    )
  end

  get "/jwks" do
    %{keys: keys, published: published} = state()

    jwks =
      for alg <- published, {kid, _, jwk} <- [keys[alg]], do: Map.merge(jwk, %{"kid" => kid, "alg" => alg, "use" => "sig"})

    json(conn, 200, %{"keys" => jwks})
  end

  post "/token" do
    {:ok, body, conn} = read_body(conn)
    form = URI.decode_query(body)
    authorization = get_req_header(conn, "authorization") |> List.first()
    update(&%{&1 | requests: [%{form: form, authorization: authorization} | &1.requests]})
    %{codes: codes, token: token} = state()

    case {token, codes[form["code"]]} do
      {{status, body}, _} ->
        conn |> put_resp_content_type("application/json") |> send_resp(status, body)

      {nil, %{claims: claims, challenge: challenge, alg: alg, header: header}} ->
        verifier = form["code_verifier"] || ""

        if Testor.Auth.OIDC.challenge(verifier) == challenge,
          do: json(conn, 200, %{"id_token" => sign(claims, alg, header), "token_type" => "Bearer"}),
          else: json(conn, 400, %{"error" => "invalid_grant"})

      {nil, nil} ->
        json(conn, 400, %{"error" => "invalid_grant"})
    end
  end

  match _ do
    send_resp(conn, 404, "")
  end

  defp json(conn, status, data) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, JSON.encode!(data))
  end

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)
end
