defmodule KinetixMatchingWeb.Router do
  use KinetixMatchingWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :authenticated_api do
    plug :accepts, ["json"]
    plug KinetixMatchingWeb.Plugs.IdentityAuth
  end

  scope "/", KinetixMatchingWeb do
    get "/health", HealthController, :live
    get "/health/ready", HealthController, :ready
    get "/metrics", MetricsController, :index
  end

  scope "/api/v1", KinetixMatchingWeb do
    pipe_through :authenticated_api
    get "/driver/me", Api.V1.DriverProfileController, :show
  end

  pipeline :fleet_operator do
    plug KinetixMatchingWeb.Plugs.RequireRole, ["admin"]
    plug KinetixMatchingWeb.Plugs.AdminAudit
  end

  scope "/api/v1", KinetixMatchingWeb.Api.V1, as: :api_v1 do
    pipe_through [:authenticated_api, :fleet_operator]

    get "/drivers", DriverController, :index, metadata: %{admin_action: "matching.drivers_list"}

    get "/drivers/nearby", DriverController, :nearby,
      metadata: %{admin_action: "matching.drivers_nearby"}

    get "/drivers/:id", DriverController, :show, metadata: %{admin_action: "matching.driver_read"}
  end

  scope "/api/v1/backoffice", KinetixMatchingWeb.Api.V1, as: :api_v1_backoffice do
    pipe_through [:authenticated_api, :fleet_operator]

    get "/dispatches", DispatchController, :index,
      metadata: %{admin_action: "matching.dispatches_list"}

    get "/dispatches/summary", DispatchController, :summary,
      metadata: %{admin_action: "matching.dispatches_summary"}

    get "/dispatches/:id", DispatchController, :show,
      metadata: %{admin_action: "matching.dispatch_read"}

    post "/dispatches/:id/assign", DispatchController, :assign,
      metadata: %{admin_action: "matching.assign"}

    post "/dispatches/:id/unassign", DispatchController, :unassign,
      metadata: %{admin_action: "matching.unassign"}

    post "/dispatches/:id/cancel", DispatchController, :cancel,
      metadata: %{admin_action: "matching.cancel"}

    get "/drivers/:driver_id/dispatches", DispatchController, :for_driver,
      metadata: %{admin_action: "matching.driver_dispatches_list"}
  end
end
