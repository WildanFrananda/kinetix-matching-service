defmodule FleetPulseWeb.MerchantSocket do
  @moduledoc """
  The websocket a merchant application connects to for real-time order and telemetry updates.
  """

  use Phoenix.Socket

  alias FleetPulseWeb.MerchantToken

  channel "merchant:*", FleetPulseWeb.MerchantChannel

  @impl Phoenix.Socket
  @spec connect(map(), Phoenix.Socket.t(), map()) ::
          {:ok, Phoenix.Socket.t()} | {:error, MerchantToken.error() | :missing_token}
  def connect(%{"token" => token}, socket, _connect_info) do
    case MerchantToken.verify(token) do
      {:ok, merchant_id} -> {:ok, assign(socket, :merchant_id, merchant_id)}
      {:error, reason} -> {:error, reason}
    end
  end

  def connect(_params, _socket, _connect_info), do: {:error, :missing_token}

  @impl Phoenix.Socket
  @spec id(Phoenix.Socket.t()) :: String.t()
  def id(socket), do: "merchant_socket:#{socket.assigns.merchant_id}"
end
