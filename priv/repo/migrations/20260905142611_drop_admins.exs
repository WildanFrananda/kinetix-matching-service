defmodule FleetPulse.Repo.Migrations.DropAdmins do
  @moduledoc """
  Removes the local operator account table.

  Identity is the only service on this platform that holds a credential. A second password store
  meant a second bcrypt cost to tune, a second reset flow that was never written, and two answers
  to the question of who somebody is. Dispatch operators are identity accounts with the `admin`
  role; this service verifies their token and keeps the session.

  Irreversible on purpose. `down` would recreate an empty table, and the password hashes it held
  are gone either way — a rollback that looked like it restored something would be a lie.
  """
  use Ecto.Migration

  def up do
    drop table(:admins)
  end

  def down do
    raise Ecto.MigrationError, "the admins table is gone deliberately; operators live in identity"
  end
end
