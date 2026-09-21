defmodule FleetPulse.Repo.Migrations.DropGeocodedAddresses do
  @moduledoc """
  The fleet stops remembering where people live.
  """

  use Ecto.Migration

  def up do
    drop table(:geocoded_addresses)
  end

  def down do
    raise Ecto.MigrationError,
      message:
        "geocoded_addresses held addresses that belong to identity. It is not recreated here; " <>
          "geo.v1.GeocodingService is served by kinetix-identity-service."
  end
end
