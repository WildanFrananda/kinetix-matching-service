defmodule FleetPulse.Clients.Order do
  @moduledoc """
  Tells the order service that a courier finished a delivery.
  """

  @type error :: :unavailable | :refused | :not_configured

  @callback delivered(
              order_number :: String.t(),
              driver_principal_id :: String.t(),
              delivered_at :: DateTime.t()
            ) :: :ok | {:error, error()}

  @spec impl() :: module()
  def impl do
    Application.get_env(:fleet_pulse, __MODULE__, [])
    |> Keyword.get(:impl, FleetPulse.Clients.OrderGrpc)
  end

  @spec delivered(String.t(), String.t(), DateTime.t()) :: :ok | {:error, error()}
  def delivered(order_number, driver_principal_id, delivered_at) do
    impl().delivered(order_number, driver_principal_id, delivered_at)
  end
end
