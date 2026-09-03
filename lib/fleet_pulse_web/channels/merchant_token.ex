defmodule FleetPulseWeb.MerchantToken do
  @moduledoc """
  Signs and verifies the bearer token a merchant app presents when opening its socket.
  """

  alias FleetPulse.Types
  alias FleetPulseWeb.Endpoint
  alias Phoenix.Token

  @salt "merchant socket"
  @max_age_seconds 60 * 60 * 24 * 30

  @typedoc "Why a presented merchant token was refused."
  @type error :: :invalid_token | :expired_token

  @doc """
  Mints a token for a merchant ID. Valid for 30 days.
  """
  @spec sign(Types.id()) :: String.t()
  def sign(merchant_id) when is_integer(merchant_id) and merchant_id > 0 do
    Token.sign(Endpoint, @salt, merchant_id)
  end

  @doc """
  Verifies a presented token and returns the merchant_id it identifies.
  """
  @spec verify(term()) :: {:ok, Types.id()} | {:error, error()}
  def verify(token) when is_binary(token) do
    case Token.verify(Endpoint, @salt, token, max_age: @max_age_seconds) do
      {:ok, merchant_id} when is_integer(merchant_id) and merchant_id > 0 -> {:ok, merchant_id}
      {:error, :expired} -> {:error, :expired_token}
      _invalid -> {:error, :invalid_token}
    end
  end

  def verify(_token), do: {:error, :invalid_token}
end
