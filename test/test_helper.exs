FleetPulse.IdentityJwks.start!()
:ok = FleetPulse.FakeStorage.start()

ExUnit.start(exclude: if(System.get_env("MINIO_TEST_ENDPOINT"), do: [], else: [:minio]))
Ecto.Adapters.SQL.Sandbox.mode(FleetPulse.Repo, :manual)
