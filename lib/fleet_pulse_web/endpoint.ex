defmodule FleetPulseWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :fleet_pulse

  @before_compile FleetPulseWeb.HttpMetrics

  @drainer [batch_size: 1_000, batch_interval: 1_000, shutdown: 8_000]

  socket "/driver", FleetPulseWeb.DriverSocket,
    websocket: [
      connect_info: [:peer_data, :user_agent],
      error_handler: {FleetPulseWeb.DriverSocket, :handle_error, []}
    ],
    longpoll: false,
    drainer: @drainer

  socket "/merchant", FleetPulseWeb.MerchantSocket,
    websocket: [
      connect_info: [:peer_data, :user_agent],
      error_handler: {FleetPulseWeb.MerchantSocket, :handle_error, []}
    ],
    longpoll: false,
    drainer: @drainer

  if code_reloading? do
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :fleet_pulse
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug FleetPulseWeb.Router
end
