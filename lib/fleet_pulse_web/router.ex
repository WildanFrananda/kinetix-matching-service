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

  pipeline :authenticated_api do
    plug :accepts, ["json"]
    plug FleetPulseWeb.Plugs.IdentityAuth
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

  # `POST /driver/session` is gone. It exchanged a phone and a password for a token this service
  # signed itself — a second credential store and a second minter. A driver logs in at identity
  # like every other account and presents that token to open its socket.

  scope "/", FleetPulseWeb do
    pipe_through [:api, :throttle_register]
    post "/driver/register", DriverRegistrationController, :create
  end

  pipeline :throttle_register do
    plug FleetPulseWeb.Plugs.RateLimit, bucket: :register
  end

  # The fleet is dispatch data: who is on shift, where they are, and what they are carrying.
  # A customer's token is a valid token and still has no business reading it.
  pipeline :fleet_reader do
    plug FleetPulseWeb.Plugs.RequireRole, ["seller", "admin"]
  end

  scope "/api/v1", FleetPulseWeb.Api.V1, as: :api_v1 do
    pipe_through [:authenticated_api, :fleet_reader]

    get "/drivers", DriverController, :index
    get "/drivers/nearby", DriverController, :nearby
    get "/drivers/:id", DriverController, :show
    get "/orders/:id", OrderController, :show
    post "/merchant/orders", MerchantOrderController, :create
  end

  # Shipping quotes are priced from an origin, a destination and a weight. Any authenticated
  # account may ask for one — a customer comparing options at checkout is the main caller.
  scope "/api/v1", FleetPulseWeb.Api.V1, as: :api_v1 do
    pipe_through :authenticated_api

    post "/shipping/options", ShippingController, :options
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
