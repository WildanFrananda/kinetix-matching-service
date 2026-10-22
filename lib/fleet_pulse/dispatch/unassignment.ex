defmodule FleetPulse.Dispatch.Unassignment do
  @moduledoc """
  An administrator taking an assigned job off a courier: which job, which courier, who did it and when.
  The courier is not offered that job again by automatic dispatch.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias FleetPulse.Dispatch.Order
  alias FleetPulse.Tracking.Driver
  alias FleetPulse.Types

  @type t :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: Types.id() | nil,
          order_id: Types.id() | nil,
          order: Order.t() | Ecto.Association.NotLoaded.t() | nil,
          driver_id: Types.id() | nil,
          driver: Driver.t() | Ecto.Association.NotLoaded.t() | nil,
          unassigned_by: String.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  @type changeset :: Ecto.Changeset.t(t())

  schema "order_unassignments" do
    belongs_to :order, Order
    belongs_to :driver, Driver
    field :unassigned_by, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @spec changeset(Order.t(), Types.id(), String.t()) :: changeset()
  def changeset(%Order{} = order, driver_id, unassigned_by) do
    %__MODULE__{}
    |> change(order_id: order.id, driver_id: driver_id, unassigned_by: unassigned_by)
    |> validate_required([:order_id, :driver_id, :unassigned_by])
    |> foreign_key_constraint(:order_id)
    |> foreign_key_constraint(:driver_id)
    |> check_constraint(:unassigned_by, name: :order_unassignments_unassigned_by_present)
  end
end
