defmodule FleetPulseWeb.Router do
  use FleetPulseWeb, :router

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
    get "/metrics", MetricsController, :index
  end

  scope "/api/v1", FleetPulseWeb do
    pipe_through :authenticated_api
    get "/driver/me", Api.V1.DriverProfileController, :show
  end

  pipeline :fleet_reader do
    plug FleetPulseWeb.Plugs.RequireRole, ["seller", "admin"]
  end

  scope "/api/v1", FleetPulseWeb.Api.V1, as: :api_v1 do
    pipe_through [:authenticated_api, :fleet_reader]

    get "/drivers", DriverController, :index
    get "/drivers/nearby", DriverController, :nearby
    get "/drivers/:id", DriverController, :show
  end

  pipeline :fleet_operator do
    plug FleetPulseWeb.Plugs.RequireRole, ["admin"]
  end

  scope "/api/v1/backoffice", FleetPulseWeb.Api.V1, as: :api_v1_backoffice do
    pipe_through [:authenticated_api, :fleet_operator]

    get "/dispatches", DispatchController, :index
    get "/dispatches/summary", DispatchController, :summary
    get "/dispatches/:id", DispatchController, :show
    post "/dispatches/:id/assign", DispatchController, :assign
    post "/dispatches/:id/cancel", DispatchController, :cancel
    get "/drivers/:driver_id/dispatches", DispatchController, :for_driver
  end
end
