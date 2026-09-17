defmodule FleetPulse.Repo.Migrations.CreateGeocodedAddresses do
  @moduledoc """
  Remembers what an address resolved to, so the platform asks a stranger once.
  """

  use Ecto.Migration

  def change do
    create table(:geocoded_addresses) do
      add :query, :string, null: false
      add :latitude, :float, null: false
      add :longitude, :float, null: false
      add :provider, :string, null: false
      add :display_name, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:geocoded_addresses, [:query])
  end
end
