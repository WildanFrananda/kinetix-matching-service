alias FleetPulse.Accounts
alias FleetPulse.Accounts.Admin
alias FleetPulse.Repo


if Mix.env() == :prod do
  raise """
  Refusing to seed in prod. Create the bootstrap administrator explicitly instead.
  """
end

admin_email = System.get_env("ADMIN_BOOTSTRAP_EMAIL", "admin@fleetpulse.local")

admin_password =
  System.get_env("ADMIN_BOOTSTRAP_PASSWORD") ||
    raise """
    ADMIN_BOOTSTRAP_PASSWORD is required and has no default.

    Generate one and pass it in, for example:
      ADMIN_BOOTSTRAP_PASSWORD=$(head -c 24 /dev/urandom | base64) mix run priv/repo/seeds.exs

    Store it in your password manager. It is not printed here.
    """

if byte_size(admin_password) < 12 do
  raise "ADMIN_BOOTSTRAP_PASSWORD must be at least 12 characters."
end

unless Repo.get_by(Admin, email: admin_email) do
  {:ok, _admin} = Accounts.create_admin(%{email: admin_email, password: admin_password})
  IO.puts("Seeded admin #{admin_email}. Password was supplied via environment and is not echoed.")
end
