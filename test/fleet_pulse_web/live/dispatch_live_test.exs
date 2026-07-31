defmodule FleetPulseWeb.DispatchLiveTest do
  use FleetPulseWeb.ConnCase

  import FleetPulse.TrackingFixtures
  import FleetPulse.AccountsFixtures

  alias FleetPulse.Tracking
  alias FleetPulse.Tracking.StateCache

  setup %{conn: conn} do
    Enum.each(StateCache.all(), &StateCache.delete(&1.driver_id))
    %{conn: log_in_admin(conn, admin_fixture())}
  end

  defp place!(latitude) do
    driver = driver_fixture()
    on_exit(fn -> cleanup(driver.id) end)

    {:ok, _pid} = Tracking.start_tracking(driver.id)
    {:ok, _driver} = Tracking.set_status(driver.id, :online)
    :ok = Tracking.track_location(driver.id, telemetry_attrs(%{latitude: latitude}))
    {:ok, _state} = Tracking.fetch_state(driver.id)

    driver
  end

  defp cleanup(driver_id) do
    _ = Tracking.stop_tracking(driver_id)
    _ = StateCache.delete(driver_id)
    :ok
  end

  test "redirects an anonymous visitor to login" do
    assert {:error, {:redirect, %{to: path}}} = live(build_conn(), ~p"/dispatch")
    assert path == ~p"/admin/log_in"
  end

  test "an authenticated admin reaches the console", %{conn: conn} do
    assert {:ok, _view, html} = live(conn, ~p"/dispatch")
    assert html =~ "Dispatch"
  end

  test "renders the fleet already in memory at mount", %{conn: conn} do
    driver = place!(-6.2)

    {:ok, _view, html} = live(conn, ~p"/dispatch")

    assert html =~ "Dispatch"
    assert html =~ to_string(driver.id)
    assert html =~ "-6.2"
  end

  test "buffers a live update until the next flush", %{conn: conn} do
    driver = place!(-6.2)
    {:ok, view, _html} = live(conn, ~p"/dispatch")

    :ok = Tracking.track_location(driver.id, telemetry_attrs(%{latitude: -6.9}))
    {:ok, _state} = Tracking.fetch_state(driver.id)

    refute render(view) =~ "-6.9"

    send(view.pid, :flush)
    assert render(view) =~ "-6.9"
  end

  test "collapses repeated pings into one rendered update", %{conn: conn} do
    driver = place!(-6.2)
    {:ok, view, _html} = live(conn, ~p"/dispatch")

    for latitude <- [-6.3, -6.4, -6.5] do
      :ok = Tracking.track_location(driver.id, telemetry_attrs(%{latitude: latitude}))
    end

    {:ok, _state} = Tracking.fetch_state(driver.id)
    send(view.pid, :flush)

    html = render(view)
    assert html =~ "-6.5"
    refute html =~ "-6.3"
    refute html =~ "-6.4"
  end

  test "drops a driver from the table when it stops", %{conn: conn} do
    driver = place!(-6.2)
    {:ok, view, html} = live(conn, ~p"/dispatch")
    assert html =~ "-6.2"

    :ok = Tracking.stop_tracking(driver.id)

    assert render(view) =~ "0 driver(s) tracked"
    refute render(view) =~ "-6.2"
  end

  describe "order management" do
    test "creating an order adds it to the board", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dispatch")

      view
      |> form("#order-form",
        order: %{
          pickup_latitude: "-6.2",
          pickup_longitude: "106.8",
          dropoff_latitude: "-6.9",
          dropoff_longitude: "107.6",
          weight_kg: "50"
        }
      )
      |> render_submit()

      assert render(view) =~ "pending"
    end

    test "assigning a pending order dispatches it to a nearby driver", %{conn: conn} do
      driver = FleetPulse.TrackingFixtures.driver_fixture()
      {:ok, _} = FleetPulse.Tracking.start_tracking(driver.id)
      {:ok, _} = FleetPulse.Tracking.set_status(driver.id, :online)

      :ok =
        FleetPulse.Tracking.track_location(driver.id, %{
          latitude: -6.2,
          longitude: 106.8,
          recorded_at: DateTime.utc_now()
        })

      {:ok, _} = FleetPulse.Tracking.fetch_state(driver.id)
      on_exit(fn -> FleetPulse.Tracking.stop_tracking(driver.id) end)

      {:ok, order} =
        FleetPulse.Dispatch.create_order(%{
          pickup_latitude: -6.2,
          pickup_longitude: 106.8,
          dropoff_latitude: -6.9,
          dropoff_longitude: 107.6,
          weight_kg: 50
        })

      {:ok, view, _html} = live(conn, ~p"/dispatch")

      view
      |> element("button[phx-value-id='#{order.id}'][phx-click='assign_order']")
      |> render_click()

      assert render(view) =~ "assigned"
      assert {:ok, %{status: :busy}} = FleetPulse.Tracking.fetch_state(driver.id)
    end

    test "cancelling an order removes it from the board", %{conn: conn} do
      {:ok, order} =
        FleetPulse.Dispatch.create_order(%{
          pickup_latitude: -6.2,
          pickup_longitude: 106.8,
          dropoff_latitude: -6.9,
          dropoff_longitude: 107.6,
          weight_kg: 50
        })

      {:ok, view, _html} = live(conn, ~p"/dispatch")

      selector = "button[phx-value-id='#{order.id}'][phx-click='cancel_order']"
      assert has_element?(view, selector)

      view |> element(selector) |> render_click()

      refute has_element?(view, selector)
    end

    test "reflects an order change made elsewhere, with no dispatcher action", %{conn: conn} do
      {:ok, order} =
        FleetPulse.Dispatch.create_order(%{
          pickup_latitude: -6.2,
          pickup_longitude: 106.8,
          dropoff_latitude: -6.9,
          dropoff_longitude: 107.6,
          weight_kg: 50
        })

      {:ok, view, _html} = live(conn, ~p"/dispatch")
      selector = "button[phx-value-id='#{order.id}'][phx-click='cancel_order']"
      assert has_element?(view, selector)

      {:ok, _} = FleetPulse.Dispatch.cancel_order(order.id)

      refute has_element?(view, selector)
    end

    test "renders the KPI row", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dispatch")

      assert html =~ "Drivers online"
      assert html =~ "Active orders"
      assert html =~ "Delivered today"
    end
  end

  test "order history filters by status", %{conn: conn} do
    driver = FleetPulse.TrackingFixtures.driver_fixture()
    {:ok, _} = FleetPulse.Tracking.start_tracking(driver.id)
    {:ok, _} = FleetPulse.Tracking.set_status(driver.id, :online)

    :ok =
      FleetPulse.Tracking.track_location(driver.id, %{
        latitude: -6.2,
        longitude: 106.8,
        recorded_at: DateTime.utc_now()
      })

    {:ok, _} = FleetPulse.Tracking.fetch_state(driver.id)
    on_exit(fn -> FleetPulse.Tracking.stop_tracking(driver.id) end)

    {:ok, order} =
      FleetPulse.Dispatch.create_order(%{
        pickup_latitude: -6.2,
        pickup_longitude: 106.8,
        dropoff_latitude: -6.9,
        dropoff_longitude: 107.6,
        weight_kg: 50
      })

    {:ok, _} = FleetPulse.Dispatch.assign_order(order.id)
    {:ok, _} = FleetPulse.Dispatch.mark_picked_up(order.id, driver.id)
    {:ok, _} = FleetPulse.Dispatch.mark_delivered(order.id, driver.id)

    {:ok, view, _html} = live(conn, ~p"/dispatch")

    view
    |> form("#history-form", %{status: "delivered"})
    |> render_change()

    assert has_element?(view, "#history td", to_string(order.id))
  end
end
