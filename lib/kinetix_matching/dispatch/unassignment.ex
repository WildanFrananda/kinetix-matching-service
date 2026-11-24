defmodule KinetixMatching.Dispatch.Unassignment do
  @moduledoc """
  An administrator taking an assigned job off a courier: which job, which courier, who did it and when.
  The courier is not offered that job again by automatic dispatch.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias KinetixMatching.Dispatch.Delivery
  alias KinetixMatching.Types

  @type t :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: Types.id() | nil,
          delivery_id: Types.id() | nil,
          delivery: Delivery.t() | Ecto.Association.NotLoaded.t() | nil,
          courier_principal_id: Types.principal_id() | nil,
          unassigned_by: String.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  @type changeset :: Ecto.Changeset.t(t())

  schema "order_unassignments" do
    belongs_to(:delivery, Delivery)
    field(:courier_principal_id, :string)
    field(:unassigned_by, :string)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @spec changeset(Delivery.t(), Types.principal_id(), String.t()) :: changeset()
  def changeset(%Delivery{} = delivery, courier_principal_id, unassigned_by)
      when is_binary(courier_principal_id) and is_binary(unassigned_by) do
    %__MODULE__{}
    |> change(
      delivery_id: delivery.id,
      courier_principal_id: courier_principal_id,
      unassigned_by: unassigned_by
    )
    |> validate_required([:delivery_id, :courier_principal_id, :unassigned_by])
    |> foreign_key_constraint(:delivery_id)
    |> check_constraint(:courier_principal_id,
      name: :order_unassignments_courier_principal_id_present
    )
    |> check_constraint(:unassigned_by, name: :order_unassignments_unassigned_by_present)
  end
end
