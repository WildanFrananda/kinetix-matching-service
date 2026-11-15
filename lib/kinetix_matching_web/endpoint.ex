defmodule KinetixMatchingWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :kinetix_matching

  @before_compile KinetixMatchingWeb.SocketAuthToken
  @before_compile KinetixMatchingWeb.HttpMetrics
  @before_compile KinetixMatchingWeb.RequestTrace

  @drainer [batch_size: 1_000, batch_interval: 1_000, shutdown: 8_000]

  socket "/driver", KinetixMatchingWeb.DriverSocket,
    auth_token: true,
    websocket: [
      connect_info: [:peer_data, :user_agent],
      error_handler: {KinetixMatchingWeb.DriverSocket, :handle_error, []}
    ],
    longpoll: false,
    drainer: @drainer

  socket "/merchant", KinetixMatchingWeb.MerchantSocket,
    auth_token: true,
    websocket: [
      connect_info: [:peer_data, :user_agent],
      error_handler: {KinetixMatchingWeb.MerchantSocket, :handle_error, []}
    ],
    longpoll: false,
    drainer: @drainer

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
