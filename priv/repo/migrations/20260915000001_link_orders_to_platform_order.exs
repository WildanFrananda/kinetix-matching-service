defmodule FleetPulse.Repo.Migrations.LinkOrdersToPlatformOrder do
  @moduledoc """
  Gives a fleet job the order number it is delivering.
  """

  use Ecto.Migration

  def change do
    alter table(:orders) do
      add :order_number, :string
    end

    create unique_index(:orders, [:order_number])
  end
end
