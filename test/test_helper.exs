FleetPulse.IdentityJwks.start!()
:ok = FleetPulse.FakeStorage.start()

ExUnit.start(
  exclude: if(System.get_env("OBJECT_STORE_TEST_ENDPOINT"), do: [], else: [:object_store])
)

Ecto.Adapters.SQL.Sandbox.mode(FleetPulse.Repo, :manual)
