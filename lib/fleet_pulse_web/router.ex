defmodule FleetPulseWeb.Router do
  use FleetPulseWeb, :router

  import FleetPulseWeb.AdminAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {FleetPulseWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_admin
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :partner_api do
    plug :accepts, ["json"]
    plug FleetPulseWeb.Plugs.ApiKeyAuth
  end

  scope "/", FleetPulseWeb do
    get "/health", HealthController, :live
    get "/health/ready", HealthController, :ready
  end

  scope "/", FleetPulseWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/admin/log_in", AdminSessionController, :new
    post "/admin/log_in", AdminSessionController, :create
    delete "/admin/log_out", AdminSessionController, :delete
  end

  scope "/", FleetPulseWeb do
    pipe_through [:browser, :require_authenticated_admin]

    live_session :require_authenticated_admin,
      on_mount: [{FleetPulseWeb.AdminAuth, :ensure_authenticated}] do
      live "/dispatch", DispatchLive
    end
  end

  scope "/", FleetPulseWeb do
    pipe_through [:api, :throttle_login]
    post "/driver/session", DriverSessionController, :create
  end

  scope "/", FleetPulseWeb do
    pipe_through [:api, :throttle_register]
    post "/driver/register", DriverRegistrationController, :create
  end

  pipeline :throttle_login do
    plug FleetPulseWeb.Plugs.RateLimit, bucket: :login
  end

  pipeline :throttle_register do
    plug FleetPulseWeb.Plugs.RateLimit, bucket: :register
  end

  scope "/api/v1", FleetPulseWeb.Api.V1, as: :api_v1 do
    pipe_through :partner_api

    get "/drivers", DriverController, :index
    get "/drivers/nearby", DriverController, :nearby
    get "/drivers/:id", DriverController, :show
    get "/orders/:id", OrderController, :show
    post "/merchant/orders", MerchantOrderController, :create
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:fleet_pulse, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: FleetPulseWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
