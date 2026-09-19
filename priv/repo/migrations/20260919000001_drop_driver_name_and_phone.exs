defmodule FleetPulse.Repo.Migrations.DropDriverNameAndPhone do
  @moduledoc """
  A driver's name and phone number belong to identity, which has held them in `profiles` all along.
  """

  use Ecto.Migration

  def up do
    drop_if_exists index(:drivers, [:phone])

    alter table(:drivers) do
      remove :name
      remove :phone
    end
  end

  def down do
    alter table(:drivers) do
      add :name, :string
      add :phone, :string
    end

    create unique_index(:drivers, [:phone])
  end
end
