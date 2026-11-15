import Config

config :kinetix_matching, KinetixMatching.Repo,
  username: System.fetch_env!("DB_USERNAME"),
  password: System.fetch_env!("DB_PASSWORD"),
  hostname: System.get_env("DB_HOST") || "localhost",
  port: String.to_integer(System.get_env("DB_PORT") || "5432"),
  database:
    (System.get_env("TEST_DB_NAME") || "kinetix_matching_test") <>
      (System.get_env("MIX_TEST_PARTITION") || ""),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :kinetix_matching, KinetixMatchingWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base:
    System.get_env("SECRET_KEY_BASE") ||
      String.duplicate("test_only_not_a_secret_", 4),
  server: false

# In test we don't send emails
config :kinetix_matching, KinetixMatching.Mailer, adapter: Swoosh.Adapters.Test

config :kinetix_matching, KinetixMatching.Tracking.PersistenceBatcher, enabled: false

config :kinetix_matching, KinetixMatching.Tracking.IdleReaper, enabled: false

config :kinetix_matching, KinetixMatching.Tracking.PingRetention, enabled: false

config :kinetix_matching, KinetixMatching.Dispatch.ReDispatcher,
  enabled: false,
  debounce_ms: 60_000

config :kinetix_matching, KinetixMatching.Dispatch.DeliveryReporter, enabled: false

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# See config/config.exs — the gRPC server does not bind a port under test.
config :kinetix_matching, KinetixMatching.IdentityJwks, port: 4444

System.put_env("JWT_ISSUER", System.get_env("JWT_ISSUER") || "https://identity.kinetix.local")
System.put_env("JWT_AUDIENCE", System.get_env("JWT_AUDIENCE") || "kinetix")
System.put_env("IDENTITY_JWKS_URL", "http://127.0.0.1:4444/.well-known/jwks.json")
System.put_env("IDENTITY_HTTP_URL", System.get_env("IDENTITY_HTTP_URL") || "http://127.0.0.1:1")

config :kinetix_matching, start_grpc_server: false

config :swoosh, :api_client, false

config :kinetix_matching, KinetixMatching.Clients.Order, impl: KinetixMatching.FakeOrder
config :kinetix_matching, :time_zone, "Asia/Jakarta"
config :kinetix_matching, KinetixMatching.Storage, impl: KinetixMatching.FakeStorage
