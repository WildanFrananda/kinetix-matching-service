defmodule FleetPulseWeb.Api.V1.DispatchControllerTest do
  use FleetPulseWeb.ConnCase, async: false

  import FleetPulse.TrackingFixtures

  alias FleetPulse.Dispatch
  alias FleetPulse.Tracking
  alias FleetPulse.Tracking.StateCache

  setup %{conn: conn} do
    Enum.each(StateCache.all(), &StateCache.delete(&1.driver_id))

    %{conn: conn |> authenticate(role: "admin") |> put_req_header("accept", "application/json")}
  end

  defp tracked_driver! do
    driver = driver_fixture()
    {:ok, _} = Tracking.start_tracking(driver.id)
    {:ok, _} = Tracking.set_status(driver.id, :online)

    :ok =
      Tracking.track_location(driver.id, %{
        latitude: -6.2,
        longitude: 106.8,
        recorded_at: DateTime.utc_now()
      })

    on_exit(fn ->
      _ = Tracking.stop_tracking(driver.id)
      StateCache.delete(driver.id)
    end)

    driver
  end

  defp dispatch!(overrides \\ %{}) do
    {:ok, order} =
      Dispatch.create_order(
        Map.merge(
          %{
            pickup_latitude: -6.2,
            pickup_longitude: 106.8,
            dropoff_latitude: -6.9,
            dropoff_longitude: 107.6,
            weight_kg: 10,
            order_number: "ORD-#{System.unique_integer([:positive])}"
          },
          overrides
        )
      )

    order
  end

  describe "the routes this replaced" do
    defp routed?(method, path) do
      Phoenix.Router.route_info(FleetPulseWeb.Router, method, path, "example.com") != :error
    end

    test "a merchant can no longer file an order into the fleet" do
      refute routed?("POST", "/api/v1/merchant/orders")
    end

    test "and cannot read one back out of it either" do
      refute routed?("GET", "/api/v1/orders/1")
    end

    test "the shipping quote is not on the HTTP surface" do
      refute routed?("POST", "/api/v1/shipping/options")
    end

    test "the board that replaced them is" do
      assert routed?("GET", "/api/v1/backoffice/dispatches")
      assert routed?("POST", "/api/v1/backoffice/dispatches/1/cancel")
    end
  end

  describe "who may use the board" do
    test "a seller may not", %{conn: conn} do
      body =
        conn
        |> authenticate(role: "seller")
        |> get(~p"/api/v1/backoffice/dispatches")
        |> json_response(403)

      assert body["error"] == "forbidden"
    end

    test "an unauthenticated caller may not" do
      body =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("accept", "application/json")
        |> get(~p"/api/v1/backoffice/dispatches")
        |> json_response(401)

      assert body["error"]
    end
  end

  describe "GET /backoffice/dispatches" do
    test "lists every dispatch by default", %{conn: conn} do
      order = dispatch!()

      body = conn |> get(~p"/api/v1/backoffice/dispatches") |> json_response(200)

      assert order.id in Enum.map(body["data"], & &1["id"])
    end

    test "filters by status", %{conn: conn} do
      order = dispatch!()

      pending =
        conn |> get(~p"/api/v1/backoffice/dispatches?status=pending") |> json_response(200)

      delivered =
        conn |> get(~p"/api/v1/backoffice/dispatches?status=delivered") |> json_response(200)

      assert order.id in Enum.map(pending["data"], & &1["id"])
      refute order.id in Enum.map(delivered["data"], & &1["id"])
    end

    test "refuses a status it does not have", %{conn: conn} do
      body = conn |> get(~p"/api/v1/backoffice/dispatches?status=lost") |> json_response(400)

      assert body["error"] == "invalid_status"
    end
  end

  describe "GET /backoffice/dispatches/summary" do
    test "counts what is waiting and what landed", %{conn: conn} do
      _pending = dispatch!()

      body = conn |> get(~p"/api/v1/backoffice/dispatches/summary") |> json_response(200)

      assert body["data"]["pending"] >= 1
      assert is_integer(body["data"]["active"])
      assert is_integer(body["data"]["delivered_today"])
    end

    test "is not parsed as a dispatch id", %{conn: conn} do
      body = conn |> get(~p"/api/v1/backoffice/dispatches/summary") |> json_response(200)

      refute Map.has_key?(body["data"], "status")
    end
  end

  describe "GET /backoffice/dispatches/:id" do
    test "shows the proof of delivery, which nothing else ever read", %{conn: conn} do
      driver = tracked_driver!()
      order = dispatch!()
      {:ok, order} = Dispatch.assign_order_to_driver(order.id, driver.id)
      {:ok, _} = Dispatch.mark_picked_up(order.id, driver.id)

      {:ok, _} =
        Dispatch.mark_delivered(order.id, driver.id, %{
          "pod_photo_url" => "https://storage.kinetix.test/pod/#{order.id}.jpg",
          "pod_signature" => "data:image/svg+xml;base64,PHN2Zz4="
        })

      body = conn |> get(~p"/api/v1/backoffice/dispatches/#{order.id}") |> json_response(200)

      assert body["data"]["proof_of_delivery"]["photo_url"] ==
               "https://storage.kinetix.test/pod/#{order.id}.jpg"

      assert body["data"]["proof_of_delivery"]["signature"] ==
               "data:image/svg+xml;base64,PHN2Zz4="
    end

    test "says not found rather than inventing one", %{conn: conn} do
      body = conn |> get(~p"/api/v1/backoffice/dispatches/99999999") |> json_response(404)

      assert body["error"] == "not_found"
    end

    test "refuses an id that is not one", %{conn: conn} do
      body = conn |> get(~p"/api/v1/backoffice/dispatches/abc") |> json_response(400)

      assert body["error"] == "invalid_id"
    end
  end

  describe "POST /backoffice/dispatches/:id/assign" do
    test "places the job on the driver a dispatcher named", %{conn: conn} do
      driver = tracked_driver!()
      order = dispatch!()

      body =
        conn
        |> post(~p"/api/v1/backoffice/dispatches/#{order.id}/assign", %{"driver_id" => driver.id})
        |> json_response(200)

      assert body["data"]["driver_id"] == driver.id
      assert body["data"]["status"] == "assigned"
    end

    test "will not move a job that is already on someone", %{conn: conn} do
      first = tracked_driver!()
      second = tracked_driver!()
      order = dispatch!()
      {:ok, _} = Dispatch.assign_order_to_driver(order.id, first.id)

      body =
        conn
        |> post(~p"/api/v1/backoffice/dispatches/#{order.id}/assign", %{"driver_id" => second.id})
        |> json_response(409)

      assert body["error"] == "already_assigned"
    end

    test "needs a driver to assign to", %{conn: conn} do
      order = dispatch!()

      body =
        conn
        |> post(~p"/api/v1/backoffice/dispatches/#{order.id}/assign", %{})
        |> json_response(400)

      assert body["error"] == "driver_id_required"
    end
  end

  describe "POST /backoffice/dispatches/:id/cancel" do
    test "calls off a pending job", %{conn: conn} do
      order = dispatch!()

      body =
        conn
        |> post(~p"/api/v1/backoffice/dispatches/#{order.id}/cancel")
        |> json_response(200)

      assert body["data"]["status"] == "cancelled"
    end

    test "refuses to cancel one that has already finished", %{conn: conn} do
      driver = tracked_driver!()
      order = dispatch!()
      {:ok, _} = Dispatch.assign_order_to_driver(order.id, driver.id)
      {:ok, _} = Dispatch.mark_picked_up(order.id, driver.id)
      {:ok, _} = Dispatch.mark_delivered(order.id, driver.id, %{})

      body =
        conn
        |> post(~p"/api/v1/backoffice/dispatches/#{order.id}/cancel")
        |> json_response(409)

      assert body["error"] == "invalid_transition"
    end
  end

  describe "GET /backoffice/drivers/:driver_id/dispatches" do
    test "lists what one driver is carrying", %{conn: conn} do
      driver = tracked_driver!()
      order = dispatch!()
      {:ok, _} = Dispatch.assign_order_to_driver(order.id, driver.id)

      body =
        conn
        |> get(~p"/api/v1/backoffice/drivers/#{driver.id}/dispatches")
        |> json_response(200)

      assert order.id in Enum.map(body["data"], & &1["id"])
    end
  end
end
