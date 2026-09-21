defmodule FleetPulse.Repo.Migrations.DispatchesCarryTheAwb do
  use Ecto.Migration

  @moduledoc """
  The tracking number on the parcel, issued where the parcel is carried.
  """

  def change do
    alter table(:orders) do
      add :awb_number, :string
    end

    create unique_index(:orders, [:awb_number])
  end
end
