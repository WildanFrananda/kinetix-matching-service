defmodule FleetPulseWeb.Plugs.AdminAuditTest do
  use FleetPulseWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import FleetPulse.TrackingFixtures

  alias FleetPulse.Dispatch
  alias FleetPulse.FailingAssignment
  alias FleetPulse.Observability.Metrics
  alias FleetPulse.Tracking
  alias FleetPulse.Tracking.StateCache
  alias FleetPulseWeb.AdminActionsSeed

  @admin "9d0c7a52-3f1e-4b8a-a6d2-5e4f3c2b1a09"
  @family "kinetix_admin_actions_total"
  @registry :admin_actions_seed_test

  @expected_actions [
    "matching.drivers_list",
    "matching.drivers_nearby",
    "matching.driver_read",
    "matching.dispatches_list",
    "matching.dispatches_summary",
    "matching.dispatch_read",
    "matching.assign",
    "matching.unassign",
    "matching.cancel",
    "matching.driver_dispatches_list"
  ]

  setup %{conn: conn} do
    Enum.each(StateCache.all(), &StateCache.delete(&1.driver_id))

    test = self()
    handler = "admin-audit-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      Metrics.admin_action_event(),
      fn _event, measurements, labels, _config ->
        send(test, {:audited, measurements, labels})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    admin =
      conn
      |> authenticate(role: "admin", sub: @admin)
      |> put_req_header("accept", "application/json")

    %{conn: admin}
  end

  defp audited do
    receive do
      {:audited, %{count: 1}, labels} -> labels
    after
      0 -> flunk("the request was answered and no admin action was counted")
    end
  end

  defp nothing_audited do
    receive do
      {:audited, _measurements, labels} -> flunk("counted #{inspect(labels)}")
    after
      0 -> :ok
    end
  end

  defp at_info(fun) do
    previous = Logger.level()
    Logger.configure(level: :info)

    try do
      with_log([level: :info], fun)
    after
      Logger.configure(level: previous)
    end
  end

  defp admin_lines(log) do
    log
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&decoded/1)
    |> Enum.filter(&(&1["message"] == "admin_action"))
  end

  defp decoded(line) do
    case Jason.decode(line) do
      {:ok, %{} = body} -> [body]
      _not_json -> []
    end
  end

  defp verb(route), do: route.verb |> Atom.to_string() |> String.upcase()

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

  defp dispatch! do
    {:ok, order} =
      Dispatch.create_order(%{
        pickup_latitude: -6.2,
        pickup_longitude: 106.8,
        dropoff_latitude: -6.9,
        dropoff_longitude: 107.6,
        weight_kg: 10,
        order_number: "ORD-#{System.unique_integer([:positive])}"
      })

    order
  end

  test "every route only an admin may call names the action it is audited under" do
    audited_routes =
      FleetPulseWeb.Router.__routes__()
      |> Enum.map(
        &Phoenix.Router.route_info(FleetPulseWeb.Router, verb(&1), &1.path, "localhost")
      )
      |> Enum.filter(&(:fleet_operator in &1.pipe_through))

    assert length(audited_routes) == length(@expected_actions)

    for route <- audited_routes do
      assert route[:admin_action] in @expected_actions, route.route
    end

    assert Enum.sort(AdminActionsSeed.actions(FleetPulseWeb.Router)) ==
             Enum.sort(@expected_actions)
  end

  test "an assign is one line naming the actor, the action, the target and the request",
       %{conn: conn} do
    driver = tracked_driver!()
    order = dispatch!()

    {conn, log} =
      at_info(fn ->
        post(conn, ~p"/api/v1/backoffice/dispatches/#{order.id}/assign", %{
          "driver_id" => driver.id
        })
      end)

    assert json_response(conn, 200)
    assert [line] = admin_lines(log)
    assert line["level"] == "info"
    assert line["event"] == "admin_action"
    assert line["actor"] == @admin
    assert line["action"] == "matching.assign"
    assert line["target"] == Integer.to_string(order.id)
    assert line["outcome"] == "done"
    assert [line["request_id"]] == get_resp_header(conn, "x-request-id")
    assert %{action: "matching.assign", outcome: "done"} = audited()
  end

  test "the line carries no token", %{conn: conn} do
    [authorization] = get_req_header(conn, "authorization")
    "Bearer " <> token = authorization

    {_conn, log} = at_info(fn -> get(conn, ~p"/api/v1/drivers") end)

    assert [_line] = admin_lines(log)
    refute log =~ token
  end

  test "a request the route refuses is recorded as refused", %{conn: conn} do
    order = dispatch!()

    conn |> post(~p"/api/v1/backoffice/dispatches/#{order.id}/unassign") |> json_response(409)

    assert %{action: "matching.unassign", outcome: "refused"} = audited()
  end

  test "a database failure is recorded as failed", %{conn: conn} do
    driver = tracked_driver!()
    order = dispatch!()
    :ok = FailingAssignment.refuse!()

    capture_log(fn ->
      assert_error_sent 500, fn ->
        post(conn, ~p"/api/v1/backoffice/dispatches/#{order.id}/assign", %{
          "driver_id" => driver.id
        })
      end
    end)

    assert %{action: "matching.assign", outcome: "failed"} = audited()
  end

  test "a read names its target; a list and a nearby search name none", %{conn: conn} do
    order = dispatch!()

    {_conn, log} =
      at_info(fn ->
        conn |> get(~p"/api/v1/backoffice/dispatches") |> json_response(200)

        conn
        |> get(~p"/api/v1/drivers/nearby?latitude=-6.2&longitude=106.8")
        |> json_response(200)

        conn |> get(~p"/api/v1/backoffice/dispatches/#{order.id}") |> json_response(200)
      end)

    assert [list, nearby, read] = admin_lines(log)
    assert {list["action"], list["target"]} == {"matching.dispatches_list", nil}
    assert {nearby["action"], nearby["target"]} == {"matching.drivers_nearby", nil}
    assert {read["action"], read["target"]} == {"matching.dispatch_read", "#{order.id}"}
  end

  test "a courier's dispatches name the courier as the target", %{conn: conn} do
    driver = tracked_driver!()

    {_conn, log} =
      at_info(fn ->
        conn
        |> get(~p"/api/v1/backoffice/drivers/#{driver.id}/dispatches")
        |> json_response(200)
      end)

    assert [line] = admin_lines(log)
    assert line["action"] == "matching.driver_dispatches_list"
    assert line["target"] == Integer.to_string(driver.id)
  end

  test "a seller turned away by role is no admin action", %{conn: conn} do
    conn
    |> recycle()
    |> authenticate(role: "seller")
    |> get(~p"/api/v1/drivers")
    |> json_response(403)

    nothing_audited()
  end

  describe "the seed" do
    setup do
      start_supervised!(
        {TelemetryMetricsPrometheus.Core,
         name: @registry, metrics: Metrics.definitions(), start_async: false}
      )

      :ok
    end

    defp series do
      @registry
      |> TelemetryMetricsPrometheus.Core.scrape()
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, @family <> "{"))
    end

    test "publishes every action and every outcome at zero before anything happened" do
      AdminActionsSeed.seed(FleetPulseWeb.Router)

      lines = series()

      assert length(lines) == length(@expected_actions) * 3

      for action <- @expected_actions, outcome <- ["done", "refused", "failed"] do
        assert Enum.any?(
                 lines,
                 &(&1 =~ ~s(action="#{action}") and &1 =~ ~s(outcome="#{outcome}"))
               ),
               "#{action} #{outcome} was not published"
      end

      for line <- lines do
        assert String.ends_with?(line, "} 0"), line
      end
    end
  end
end
