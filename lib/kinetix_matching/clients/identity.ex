defmodule KinetixMatching.Clients.Identity do
  @moduledoc """
  Identity's courier standing door — asks whether a principal has an approved vehicle and what it carries.
  """

  @type standing :: %{
          courier_principal_id: String.t(),
          vehicle_plate: String.t(),
          capacity_kg: non_neg_integer(),
          may_drive: boolean()
        }

  @type error :: :not_found | :unavailable

  @callback courier_standing(String.t()) :: {:ok, standing()} | {:error, error()}

  @spec courier_standing(String.t()) :: {:ok, standing()} | {:error, error()}
  def courier_standing(courier_principal_id) do
    impl().courier_standing(courier_principal_id)
  end

  @spec impl() :: module()
  defp impl do
    :kinetix_matching
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:impl, KinetixMatching.Clients.IdentityGrpc)
  end
end
