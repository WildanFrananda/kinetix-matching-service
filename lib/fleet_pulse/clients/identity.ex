defmodule FleetPulse.Clients.Identity do
  @moduledoc """
  Who a driver is, asked of the service that owns the answer.
  """

  @type error :: :unavailable | :not_found | :not_configured

  @type profile :: %{full_name: String.t(), phone_number: String.t()}

  @callback profile_of(principal_id :: String.t()) :: {:ok, profile()} | {:error, error()}

  @spec impl() :: module()
  def impl do
    Application.get_env(:fleet_pulse, __MODULE__, [])
    |> Keyword.get(:impl, FleetPulse.Clients.IdentityGrpc)
  end

  @spec profile_of(String.t()) :: {:ok, profile()} | {:error, error()}
  def profile_of(principal_id) do
    impl().profile_of(principal_id)
  end
end
