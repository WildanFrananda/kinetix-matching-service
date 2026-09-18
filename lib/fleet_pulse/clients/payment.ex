defmodule FleetPulse.Clients.Payment do
  @moduledoc """
  The one thing this service needs to tell payment: a driver delivered an order and is owed the
  shipping fee.
  """

  @type error :: :unavailable | :refused | :not_configured

  @callback settle_shipping_fee(order_number :: String.t(), driver_principal_id :: String.t()) ::
              :ok | {:error, error()}

  @spec impl() :: module()
  def impl do
    Application.get_env(:fleet_pulse, __MODULE__, [])
    |> Keyword.get(:impl, FleetPulse.Clients.PaymentGrpc)
  end

  @spec settle_shipping_fee(String.t(), String.t()) :: :ok | {:error, error()}
  def settle_shipping_fee(order_number, driver_principal_id) do
    impl().settle_shipping_fee(order_number, driver_principal_id)
  end
end
