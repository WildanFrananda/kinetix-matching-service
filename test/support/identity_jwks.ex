defmodule FleetPulse.IdentityJwks do
  @moduledoc """
  Serves a JWKS the way identity does, and mints the RS256 tokens identity mints.

  A real HTTP server on a loopback port rather than a stubbed fetch: `TokenVerifier` then runs
  exactly as it does in production — the same `Req` call, the same JWK import, the same RS256
  pin, `iss`, `aud`, `exp` and `token_use` checks, the same `AccessClaims` narrowing. A token this
  helper builds wrong fails the same way a forged one would.

  What this replaces: nothing. Before this, matching had no way to exercise its own
  authentication, because its authentication was an API key looked up in its own table.
  """

  use Agent

  @doc "The signing key, generated once for the whole suite."
  @spec key() :: JOSE.JWK.t()
  def key, do: Agent.get(__MODULE__, & &1.key)

  @doc "The `kid` the JWKS publishes and every minted token names."
  @spec kid() :: String.t()
  def kid, do: Agent.get(__MODULE__, & &1.kid)

  @doc """
  Generates the signing key and serves it at the port `config/test.exs` names.
  """
  @spec start!() :: :ok
  def start! do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_meta, public} = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    kid = public |> JOSE.JWK.thumbprint() |> to_string()
    document = %{"keys" => [Map.merge(public, %{"kid" => kid, "alg" => "RS256", "use" => "sig"})]}

    {:ok, _agent} = Agent.start_link(fn -> %{key: jwk, kid: kid} end, name: __MODULE__)

    {:ok, server} =
      Bandit.start_link(
        plug: {__MODULE__.Plug, document},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: Application.get_env(:fleet_pulse, __MODULE__)[:port],
        startup_log: false
      )

    _ = server
    :ok
  end

  @doc """
  Mints an access token.

  `overrides` exists so a test can build a token that is wrong in exactly one way — a different
  issuer, a `token_use` of `refresh`, an `exp` in the past.
  """
  @spec token(keyword()) :: String.t()
  def token(overrides \\ []) do
    claims =
      %{
        "sub" => Keyword.get(overrides, :sub, "11111111-2222-3333-4444-555555555555"),
        "uid" => Keyword.get(overrides, :uid, 1),
        "email" => Keyword.get(overrides, :email, "someone@kinetix.test"),
        "role" => Keyword.get(overrides, :role, "seller"),
        "token_use" => Keyword.get(overrides, :token_use, "access"),
        "iss" => Keyword.get(overrides, :iss, System.fetch_env!("JWT_ISSUER")),
        "aud" => Keyword.get(overrides, :aud, System.fetch_env!("JWT_AUDIENCE")),
        "iat" => System.system_time(:second),
        "exp" => Keyword.get(overrides, :exp, System.system_time(:second) + 900)
      }

    signer = Keyword.get(overrides, :key, key())
    header = %{"alg" => "RS256", "typ" => "JWT", "kid" => Keyword.get(overrides, :kid, kid())}

    {_meta, jwt} = JOSE.JWT.sign(signer, header, claims) |> JOSE.JWS.compact()
    jwt
  end

  @doc "An `Authorization` header carrying `token`."
  @spec bearer(String.t()) :: {String.t(), String.t()}
  def bearer(token), do: {"authorization", "Bearer " <> token}

  defmodule Plug do
    @moduledoc false
    @behaviour Elixir.Plug

    @impl Elixir.Plug
    def init(document), do: document

    @impl Elixir.Plug
    def call(conn, document) do
      conn
      |> Elixir.Plug.Conn.put_resp_content_type("application/json")
      |> Elixir.Plug.Conn.send_resp(200, Jason.encode!(document))
    end
  end
end
