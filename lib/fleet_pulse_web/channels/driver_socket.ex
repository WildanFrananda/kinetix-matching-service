defmodule FleetPulseWeb.DriverSocket do
  @moduledoc """
  The websocket a driver's mobile app connects to.

  Authentication happens once, here, at connect time — not per message. The resolved driver id is
  stashed in socket assigns and is the ONLY identity the channel trusts afterwards.

  What this replaces: `FleetPulseWeb.DriverToken`, a token this service signed itself with the
  endpoint's `secret_key_base`. That made matching a second token minter, and identity is meant
  to be the only one. The device now presents the same access token it presents everywhere else,
  and the driver row is found by the principal that token names.
  """

  use Phoenix.Socket

  alias FleetPulse.Security.AccessClaims
  alias FleetPulse.Security.TokenVerifier
  alias FleetPulse.Tracking

  channel "driver:*", FleetPulseWeb.DriverChannel

  @type error :: :invalid_token | :malformed_claims | :not_a_courier | :unlinked | :missing_token

  @impl Phoenix.Socket
  @spec connect(map(), Phoenix.Socket.t(), map()) ::
          {:ok, Phoenix.Socket.t()} | {:error, error()}
  def connect(%{"token" => token}, socket, _connect_info) when is_binary(token) do
    with {:ok, %AccessClaims{} = claims} <- TokenVerifier.verify_access(token),
         :ok <- courier?(claims),
         {:ok, driver} <- Tracking.driver_for_principal(claims.principal_id) do
      {:ok, assign(socket, :driver_id, driver.id)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def connect(_params, _socket, _connect_info), do: {:error, :missing_token}

  @doc """
  Identifies every socket belonging to one driver.

  A stable id lets the server force-disconnect a driver from anywhere —
  `FleetPulseWeb.Endpoint.broadcast("driver_socket:7", "disconnect", %{})` — which is what you
  reach for when identity revokes a token.
  """
  @impl Phoenix.Socket
  @spec id(Phoenix.Socket.t()) :: String.t()
  def id(socket), do: "driver_socket:#{socket.assigns.driver_id}"

  @spec courier?(AccessClaims.t()) :: :ok | {:error, :not_a_courier}
  defp courier?(%AccessClaims{role: "courier"}), do: :ok
  defp courier?(%AccessClaims{role: "admin"}), do: :ok
  defp courier?(_claims), do: {:error, :not_a_courier}
end
