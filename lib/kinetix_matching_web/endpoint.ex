defmodule KinetixMatchingWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :kinetix_matching

  @before_compile KinetixMatchingWeb.HttpMetrics
  @before_compile KinetixMatchingWeb.RequestTrace

  plug KinetixMatchingWeb.EventSocketPlug

  if code_reloading? do
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :kinetix_matching
  end

  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug KinetixMatchingWeb.Router
end
