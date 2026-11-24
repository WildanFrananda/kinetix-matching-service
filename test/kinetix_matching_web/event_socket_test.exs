defmodule KinetixMatchingWeb.EventSocketTest do
  use KinetixMatching.DataCase, async: false

  import KinetixMatching.TrackingFixtures

  alias KinetixMatching.DeliveryProof
  alias KinetixMatching.Dispatch
  alias KinetixMatching.FailingAssignment
  alias KinetixMatching.FakePositionPublisher
  alias KinetixMatching.Tracking
  alias KinetixMatching.Tracking.DriverState
  alias KinetixMatching.Tracking.LocationPing
  alias KinetixMatchingWeb.EventSocket

  defp encode(event, data, request_id) do
    Jason.encode!(%{
      event: event,
      requestId: request_id,
      schemaVersion: 1,
      sentAt: DateTime.to_iso8601(DateTime.utc_now()),
      data: data
    })
  end

  defp push_command(state, event, data, request_id \\ "req-#{System.unique_integer([:positive])}") do
    {:push, {:text, raw}, next_state} =
      EventSocket.handle_in({encode(event, data, request_id), opcode: :text}, state)

    {Jason.decode!(raw), next_state}
  end

  defp cleanup(driver_id) do
    _ = Tracking.stop_tracking(driver_id)
  end

  setup do
    FakePositionPublisher.reset()
    principal = "principal-#{System.unique_integer([:positive])}"
    driver = active_driver_fixture(principal)
    on_exit(fn -> cleanup(driver.id) end)

    {:push, {:text, snapshot_raw}, state} =
      EventSocket.init(%{role: :courier, courier_principal_id: driver.id})

    on_exit(fn -> EventSocket.terminate(:normal, state) end)

    %{driver: driver, state: state, snapshot: Jason.decode!(snapshot_raw)}
  end

  describe "courier initialization and snapshot" do
    test "connects in offline duty with null activeOrder", %{driver: driver, snapshot: snapshot} do
      assert snapshot["event"] == "matching.job.snapshot"
      assert snapshot["orderId"] == nil
      assert snapshot["data"]["dutyStatus"] == "offline"
      assert snapshot["data"]["activeOrder"] == nil
      assert {:ok, %{status: :offline}} = Tracking.fetch_state(driver.id)
    end

    test "reconnecting driver receives their in-flight order with monotonic sequence" do
      driver = driver_fixture(%{capacity_kg: 100})
      on_exit(fn -> cleanup(driver.id) end)

      {:ok, _} = Tracking.start_tracking(driver.id)
      {:ok, _} = Tracking.set_status(driver.id, :online)

      :ok =
        Tracking.track_location(
          driver.id,
          telemetry_attrs(%{latitude: -6.1754, longitude: 106.8272})
        )

      order_number = "ORD-#{System.unique_integer([:positive])}"

      {:ok, order} =
        Dispatch.create_order(%{
          pickup_latitude: -6.1754,
          pickup_longitude: 106.8272,
          dropoff_latitude: -6.9,
          dropoff_longitude: 107.6,
          weight_kg: 50,
          order_number: order_number
        })

      assert order.event_sequence == 1

      {:ok, assigned} = Dispatch.assign_order(order.id)
      assert assigned.event_sequence == 2

      {:push, {:text, snap_raw}, state} =
        EventSocket.init(%{role: :courier, courier_principal_id: driver.id})

      on_exit(fn -> EventSocket.terminate(:normal, state) end)

      snapshot = Jason.decode!(snap_raw)
      assert snapshot["event"] == "matching.job.snapshot"
      assert snapshot["orderId"] == order_number
      assert snapshot["sequence"] == 2
      assert snapshot["data"]["dutyStatus"] == "busy"
      assert snapshot["data"]["activeOrder"]["id"] == order.id
      assert snapshot["data"]["activeOrder"]["orderNumber"] == order_number
      assert snapshot["data"]["activeOrder"]["courierPrincipalId"] == driver.id
    end
  end

  describe "courier.location.ping and live Redis position broadcast" do
    test "accepts ping, updates live state, and publishes courier.location.updated for active order",
         %{driver: driver, state: state} do
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      {reply, state} =
        push_command(state, "courier.duty.set", %{"status" => "online"})

      assert reply["event"] == "command.ack"
      assert reply["data"]["status"] == "online"

      {ping_reply, state} =
        push_command(state, "courier.location.ping", %{
          "latitude" => -6.1754,
          "longitude" => 106.8272,
          "bearingDeg" => 90.0,
          "speedKmh" => 35.0,
          "recordedAt" => now
        })

      assert ping_reply["event"] == "command.ack"
      assert ping_reply["data"]["accepted"] == true
      assert [] = FakePositionPublisher.published()

      order_number = "ORD-#{System.unique_integer([:positive])}"

      {:ok, order} =
        Dispatch.create_order(%{
          pickup_latitude: -6.1754,
          pickup_longitude: 106.8272,
          dropoff_latitude: -6.21,
          dropoff_longitude: 106.82,
          weight_kg: 10,
          order_number: order_number
        })

      {:ok, assigned} = Dispatch.assign_order(order.id)
      assert_receive {:order_assigned, ^assigned}

      {:push, [_assigned_frame], state} =
        EventSocket.handle_info({:order_assigned, assigned}, state)

      later = DateTime.utc_now() |> DateTime.add(2, :second) |> DateTime.to_iso8601()

      {active_ping_reply, _state} =
        push_command(state, "courier.location.ping", %{
          "latitude" => -6.18,
          "longitude" => 106.83,
          "bearingDeg" => 120.0,
          "speedKmh" => 40.5,
          "recordedAt" => later
        })

      assert active_ping_reply["event"] == "command.ack"
      assert [{^order_number, pos_env}] = FakePositionPublisher.published()
      assert pos_env.event == "courier.location.updated"
      assert pos_env.orderId == order_number
      assert pos_env.sequence == nil
      assert pos_env.data.courierPrincipalId == driver.id
      assert pos_env.data.latitude == -6.18
      assert pos_env.data.longitude == 106.83
      assert pos_env.data.bearingDeg == 120.0
      assert pos_env.data.speedKmh == 40.5
    end

    test "rejects invalid telemetry and future clock skew", %{state: state} do
      {bad_coords, _state} =
        push_command(state, "courier.location.ping", %{
          "latitude" => 120.0,
          "longitude" => 106.8,
          "recordedAt" => DateTime.to_iso8601(DateTime.utc_now())
        })

      assert bad_coords["event"] == "command.error"
      assert bad_coords["error"]["code"] == "INVALID_TELEMETRY"
      assert bad_coords["error"]["reason"] == "invalid_telemetry"
      assert bad_coords["error"]["retryable"] == false

      future = DateTime.utc_now() |> DateTime.add(360, :second) |> DateTime.to_iso8601()

      {ahead_reply, _state} =
        push_command(state, "courier.location.ping", %{
          "latitude" => -6.2,
          "longitude" => 106.8,
          "recordedAt" => future
        })

      assert ahead_reply["event"] == "command.error"
      assert ahead_reply["error"]["reason"] == "invalid_telemetry"
    end

    test "enforces per-driver ping rate limit", %{driver: driver, state: state} do
      previous = Application.fetch_env!(:kinetix_matching, EventSocket)
      Application.put_env(:kinetix_matching, EventSocket, Keyword.put(previous, :ping_limit, 1))
      on_exit(fn -> Application.put_env(:kinetix_matching, EventSocket, previous) end)

      t1 = DateTime.to_iso8601(DateTime.utc_now())

      {ok_reply, state} =
        push_command(state, "courier.location.ping", %{
          "latitude" => -6.2,
          "longitude" => 106.8,
          "recordedAt" => t1
        })

      assert ok_reply["event"] == "command.ack"

      {limited_reply, _state} =
        push_command(state, "courier.location.ping", %{
          "latitude" => -6.21,
          "longitude" => 106.81,
          "recordedAt" => t1
        })

      assert limited_reply["event"] == "command.error"
      assert limited_reply["error"]["code"] == "RATE_LIMITED"
      assert limited_reply["error"]["reason"] == "rate_limited"
      assert limited_reply["error"]["retryable"] == true
      assert driver.id == state.courier_principal_id
    end
  end

  describe "courier.location.batch" do
    test "stores offline pings without moving live state or publishing live position", %{
      driver: driver,
      state: state
    } do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      t1 = DateTime.add(now, -120, :second) |> DateTime.to_iso8601()
      t2 = DateTime.add(now, -60, :second) |> DateTime.to_iso8601()

      {reply, _state} =
        push_command(state, "courier.location.batch", %{
          "pings" => [
            %{"latitude" => -6.2, "longitude" => 106.8, "recordedAt" => t1},
            %{"latitude" => -6.21, "longitude" => 106.81, "recordedAt" => t2}
          ]
        })

      assert reply["event"] == "command.ack"
      assert reply["data"]["stored"] == [0, 1]
      assert reply["data"]["duplicates"] == []
      assert reply["data"]["refused"] == []
      assert [] = FakePositionPublisher.published()
      assert Repo.aggregate(LocationPing, :count) == 2
      assert {:ok, %{coordinates: nil}} = Tracking.fetch_state(driver.id)
    end
  end

  describe "courier.duty.set and idle reaper" do
    test "transitions duty, enforces no_active_job for busy, and propagates assignment errors", %{
      driver: driver,
      state: state
    } do
      {busy_err, state} = push_command(state, "courier.duty.set", %{"status" => "busy"})
      assert busy_err["event"] == "command.error"
      assert busy_err["error"]["code"] == "NO_ACTIVE_JOB"

      {bad_err, state} = push_command(state, "courier.duty.set", %{"status" => "teleporting"})
      assert bad_err["event"] == "command.error"
      assert bad_err["error"]["code"] == "INVALID_STATUS"

      {:ok, _} = Tracking.set_status(driver.id, :offline)

      :ok =
        Tracking.track_location(
          driver.id,
          telemetry_attrs(%{latitude: -6.1754, longitude: 106.8272})
        )

      {:ok, order} =
        Dispatch.create_order(%{
          pickup_latitude: -6.1754,
          pickup_longitude: 106.8272,
          dropoff_latitude: -6.2,
          dropoff_longitude: 106.81,
          weight_kg: 10
        })

      :ok = FailingAssignment.refuse!()
      {reply, _state} = push_command(state, "courier.duty.set", %{"status" => "online"})
      assert reply["event"] == "command.ack"
      assert reply["data"]["status"] == "online"

      assert {:ok, %{status: :pending}} = Dispatch.fetch_order(order.id)
    end

    test "keeps driver alive while idle reaper sweeps connected socket", %{
      driver: driver
    } do
      assert {:ok, _} = Tracking.fetch_state(driver.id)
      future = DateTime.add(DateTime.utc_now(), 60, :second)
      assert :active = DriverState.stop_if_idle(driver.id, future)
      assert {:ok, _} = Tracking.fetch_state(driver.id)
    end
  end

  describe "matching.job.* lifecycle and sequence monotonicity" do
    test "advances order through assigned -> picked_up -> podUpload -> delivered with monotonic sequence",
         %{driver: driver, state: state} do
      {:ok, _} = Tracking.set_status(driver.id, :online)

      :ok =
        Tracking.track_location(
          driver.id,
          telemetry_attrs(%{latitude: -6.1754, longitude: 106.8272})
        )

      order_number = "ORD-#{System.unique_integer([:positive])}"

      {:ok, order} =
        Dispatch.create_order(%{
          pickup_latitude: -6.1754,
          pickup_longitude: 106.8272,
          dropoff_latitude: -6.22,
          dropoff_longitude: 106.85,
          weight_kg: 25,
          order_number: order_number
        })

      assert order.event_sequence == 1

      {:ok, assigned} = Dispatch.assign_order(order.id)
      assert assigned.event_sequence == 2

      {:push, [assigned_frame], state} =
        EventSocket.handle_info({:order_assigned, assigned}, state)

      assigned_json = Jason.decode!(elem(assigned_frame, 1))
      assert assigned_json["event"] == "matching.job.assigned"
      assert assigned_json["orderId"] == order_number
      assert assigned_json["sequence"] == 2
      assert assigned_json["data"]["order"]["status"] == "assigned"

      {pickup_reply, state} =
        push_command(state, "matching.job.pickup", %{"orderId" => order.id})

      assert pickup_reply["event"] == "command.ack"
      assert pickup_reply["data"]["order"]["status"] == "picked_up"
      assert pickup_reply["data"]["order"]["eventSequence"] == 3

      photo_bytes = DeliveryProof.photo_bytes()
      photo_sha256 = :crypto.hash(:sha256, photo_bytes) |> Base.encode16(case: :lower)

      {upload_reply, state} =
        push_command(state, "matching.job.podUpload", %{
          "orderId" => order.id,
          "photoSha256" => photo_sha256
        })

      assert upload_reply["event"] == "command.ack"
      photo_url = upload_reply["data"]["photoUrl"]
      assert is_binary(upload_reply["data"]["uploadUrl"])
      assert is_binary(photo_url)

      :ok = KinetixMatching.FakeStorage.uploaded(photo_url, photo_bytes)
      sig = DeliveryProof.signature_uri(DeliveryProof.signature_png())

      {delivered_reply, state} =
        push_command(state, "matching.job.delivered", %{
          "orderId" => order.id,
          "podPhotoUrl" => photo_url,
          "podSignature" => sig
        })

      assert delivered_reply["event"] == "command.ack"
      assert delivered_reply["data"]["order"]["status"] == "delivered"
      assert delivered_reply["data"]["order"]["eventSequence"] == 4
      assert state.active_order == nil
    end

    test "emits matching.job.unassigned and bumps sequence when unassigned", %{
      driver: driver,
      state: state
    } do
      {:ok, _} = Tracking.set_status(driver.id, :online)

      :ok =
        Tracking.track_location(
          driver.id,
          telemetry_attrs(%{latitude: -6.1754, longitude: 106.8272})
        )

      {:ok, order} =
        Dispatch.create_order(%{
          pickup_latitude: -6.1754,
          pickup_longitude: 106.8272,
          dropoff_latitude: -6.22,
          dropoff_longitude: 106.85,
          weight_kg: 10,
          order_number: "ORD-#{System.unique_integer([:positive])}"
        })

      {:ok, assigned} = Dispatch.assign_order(order.id)
      {:ok, unassigned} = Dispatch.unassign_order(assigned.id, "admin-1")
      assert unassigned.event_sequence == 3

      {:push, [unassigned_frame, snapshot_frame], _state} =
        EventSocket.handle_info({:order_unassigned, unassigned}, state)

      unassigned_json = Jason.decode!(elem(unassigned_frame, 1))
      assert unassigned_json["event"] == "matching.job.unassigned"
      assert unassigned_json["sequence"] == 3
      assert unassigned_json["data"]["id"] == order.id

      snapshot_json = Jason.decode!(elem(snapshot_frame, 1))
      assert snapshot_json["event"] == "matching.job.snapshot"
      assert snapshot_json["data"]["activeOrder"] == nil
    end
  end

  describe "seller role events and command refusal" do
    test "pushes only the merchant's own order updates and refuses client mutations" do
      merchant_id = "merchant-#{System.unique_integer([:positive])}"
      other_id = "merchant-#{System.unique_integer([:positive])}"

      {:push, {:text, _snap}, seller_state} =
        EventSocket.init(%{role: :seller, merchant_principal_id: merchant_id})

      {err_reply, seller_state} =
        push_command(seller_state, "courier.duty.set", %{"status" => "online"})

      assert err_reply["event"] == "command.error"
      assert err_reply["error"]["code"] == "FORBIDDEN"

      {pong_reply, seller_state} = push_command(seller_state, "system.ping", %{})
      assert pong_reply["event"] == "system.pong"

      {:ok, own_order} =
        Dispatch.create_order(%{
          pickup_latitude: -6.2,
          pickup_longitude: 106.8,
          dropoff_latitude: -6.21,
          dropoff_longitude: 106.81,
          merchant_principal_id: merchant_id,
          order_number: "ORD-#{System.unique_integer([:positive])}"
        })

      {:ok, other_order} =
        Dispatch.create_order(%{
          pickup_latitude: -6.2,
          pickup_longitude: 106.8,
          dropoff_latitude: -6.21,
          dropoff_longitude: 106.81,
          merchant_principal_id: other_id
        })

      assert {:ok, _} = EventSocket.handle_info({:order_changed, other_order}, seller_state)

      assert {:push, [{:text, raw}], _seller_state} =
               EventSocket.handle_info({:order_changed, own_order}, seller_state)

      decoded = Jason.decode!(raw)
      assert decoded["event"] == "matching.job.updated"
      assert decoded["orderId"] == own_order.order_number
      assert decoded["sequence"] == 1
      assert decoded["data"]["order"]["merchantPrincipalId"] == merchant_id
    end
  end

  describe "unsupported frames" do
    test "returns INVALID_PAYLOAD, UNSUPPORTED_SCHEMA_VERSION, and UNKNOWN_EVENT", %{state: state} do
      {:push, {:text, bad_json}, state} = EventSocket.handle_in({"{broken", opcode: :text}, state)
      assert Jason.decode!(bad_json)["error"]["code"] == "INVALID_PAYLOAD"

      bad_ver =
        Jason.encode!(%{event: "system.ping", requestId: "r-ver", schemaVersion: 2, data: %{}})

      {:push, {:text, ver_reply}, state} = EventSocket.handle_in({bad_ver, opcode: :text}, state)
      ver_json = Jason.decode!(ver_reply)
      assert ver_json["requestId"] == "r-ver"
      assert ver_json["error"]["code"] == "UNSUPPORTED_SCHEMA_VERSION"

      {unknown_reply, _state} = push_command(state, "legacy.unknown", %{}, "r-unk")
      assert unknown_reply["requestId"] == "r-unk"
      assert unknown_reply["error"]["code"] == "UNKNOWN_EVENT"
    end
  end
end
