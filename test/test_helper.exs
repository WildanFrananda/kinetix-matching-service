KinetixMatching.IdentityJwks.start!()
:ok = KinetixMatching.FakeStorage.start()
:ok = KinetixMatching.FakePositionPublisher.start()

ExUnit.start(
  exclude: if(System.get_env("OBJECT_STORE_TEST_ENDPOINT"), do: [], else: [:object_store])
)

Ecto.Adapters.SQL.Sandbox.mode(KinetixMatching.Repo, :manual)
