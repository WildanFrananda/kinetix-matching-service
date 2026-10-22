defmodule FleetPulseWeb.SocketToken do
  @moduledoc """
  Where a socket's access token is read from: Phoenix's `auth_token` (the `Sec-WebSocket-Protocol`
  header) first, then the `token` query parameter older app builds send.
  """

  @spec from(map(), map()) :: {:ok, String.t()} | {:error, :missing_token}
  def from(_params, %{auth_token: token}) when is_binary(token) and token != "", do: {:ok, token}

  def from(%{"token" => token}, _connect_info) when is_binary(token) and token != "",
    do: {:ok, token}

  def from(_params, _connect_info), do: {:error, :missing_token}
end
