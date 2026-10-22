defmodule FleetPulseWeb.MerchantSocket do
  @moduledoc """
  The websocket a merchant application connects to for real-time updates of its own fleet jobs.
  """

  use Phoenix.Socket

  alias FleetPulse.Security.AccessClaims
  alias FleetPulse.Security.TokenVerifier
  alias FleetPulseWeb.SocketToken

  channel "merchant:*", FleetPulseWeb.MerchantChannel

  @type error ::
          :invalid_token
          | :malformed_claims
          | :not_a_merchant
          | :missing_token
          | :identity_unavailable

  @impl Phoenix.Socket
  @spec connect(map(), Phoenix.Socket.t(), map()) ::
          {:ok, Phoenix.Socket.t()} | {:error, error()}
  def connect(params, socket, connect_info) do
    with {:ok, token} <- SocketToken.from(params, connect_info),
         {:ok, %AccessClaims{} = claims} <- TokenVerifier.verify_access(token),
         :ok <- merchant?(claims) do
      {:ok, assign(socket, :merchant_principal_id, claims.principal_id)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec handle_error(Plug.Conn.t(), error()) :: Plug.Conn.t()
  def handle_error(conn, :identity_unavailable), do: Plug.Conn.send_resp(conn, 503, "")
  def handle_error(conn, _reason), do: Plug.Conn.send_resp(conn, 403, "")

  @impl Phoenix.Socket
  @spec id(Phoenix.Socket.t()) :: String.t()
  def id(socket), do: "merchant_socket:#{socket.assigns.merchant_principal_id}"

  @spec merchant?(AccessClaims.t()) :: :ok | {:error, :not_a_merchant}
  defp merchant?(%AccessClaims{role: "seller"}), do: :ok
  defp merchant?(%AccessClaims{role: "admin"}), do: :ok
  defp merchant?(_claims), do: {:error, :not_a_merchant}
end
