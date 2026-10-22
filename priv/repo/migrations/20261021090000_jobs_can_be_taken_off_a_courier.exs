defmodule FleetPulse.Repo.Migrations.JobsCanBeTakenOffACourier do
  use Ecto.Migration

  @moduledoc """
  An administrator may take an assigned job off a courier; the job goes back to pending, and is not
  offered again to the courier it was taken from.
  """

  def change do
    create table(:order_unassignments) do
      add :order_id, references(:orders, on_delete: :restrict), null: false
      add :driver_id, references(:drivers, on_delete: :restrict), null: false
      add :unassigned_by, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:order_unassignments, [:order_id])

    create constraint(:order_unassignments, :order_unassignments_unassigned_by_present,
             check: "unassigned_by <> ''"
           )
  end
end
