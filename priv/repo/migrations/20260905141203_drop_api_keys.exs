defmodule FleetPulse.Repo.Migrations.DropApiKeys do
  @moduledoc """
  Removes the partner API key table.

  Kinetix has no third-party integrations and will not have them: every caller on this service's
  API presents an identity-issued RS256 token. A second class of credential existed only as a
  second thing that could leak, and as a second answer to "who is this".

  Irreversible on purpose. `down` would recreate an empty table and the credentials it held are
  gone either way, so a rollback that looks like it restored something would be a lie.
  """
  use Ecto.Migration

  def up do
    drop table(:api_keys)
  end

  def down do
    raise Ecto.MigrationError, "the api_keys table is gone deliberately; it cannot be restored"
  end
end
