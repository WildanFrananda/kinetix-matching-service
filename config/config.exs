import Config

config :kinetix_matching, start_grpc_server: true

config :kinetix_matching,
  ecto_repos: [KinetixMatching.Repo],
  generators: [timestamp_type: :utc_datetime]

config :kinetix_matching, KinetixMatchingWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: KinetixMatchingWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: KinetixMatching.PubSub,
  http: [thousand_island_options: [shutdown_timeout: 10_000]]

config :kinetix_matching, KinetixMatching.GrpcDrain, budget_ms: 5_000

config :kinetix_matching, KinetixMatching.Tracking.PersistenceBatcher,
  enabled: true,
  interval_ms: 30_000,
  chunk_size: 1_000

config :kinetix_matching, KinetixMatching.Tracking.IdleReaper,
  enabled: true,
  interval_ms: 60_000,
  idle_after_ms: 900_000

config :kinetix_matching, KinetixMatching.Dispatch.ReDispatcher,
  enabled: true,
  debounce_ms: 1_000

config :kinetix_matching, KinetixMatching.Tracking.PingRetention,
  enabled: true,
  interval_ms: :timer.hours(24),
  retention_ms: :timer.hours(24 * 30)

config :kinetix_matching, KinetixMatchingWeb.DriverChannel,
  ping_window_ms: 10_000,
  ping_limit: 100,
  ping_batch_window_ms: 60_000,
  ping_batch_limit: 30

config :kinetix_matching, KinetixMatching.Mailer, adapter: Swoosh.Adapters.Local

config :logger, :default_formatter, metadata: :all

config :phoenix, :json_library, Jason

config :elixir, :time_zone_database, Tz.TimeZoneDatabase

import_config "#{config_env()}.exs"
