defmodule FleetPulseWeb.DriverChannelTest do
  use FleetPulseWeb.ChannelCase

  import FleetPulse.DeliveryProof
  import FleetPulse.TrackingFixtures

  alias FleetPulse.Dispatch
  alias FleetPulse.FakeStorage
  alias FleetPulse.IdentityJwks
  alias FleetPulse.Repo
  alias FleetPulse.Tracking
  alias FleetPulse.Tracking.Driver
  alias FleetPulse.Tracking.IdleReaper
  alias FleetPulse.Tracking.StateCache
  alias FleetPulseWeb.DriverSocket

  defp linked_driver(overrides \\ %{}) do
    principal = "principal-#{System.unique_integer([:positive])}"
    {active_driver_fixture(principal, overrides), principal}
  end

  defp driver_socket(principal) do
    {:ok, socket} =
      connect(DriverSocket, %{"token" => IdentityJwks.token(role: "courier", sub: principal)})

    socket
  end

  setup do
    {driver, principal} = linked_driver()
    on_exit(fn -> cleanup(driver.id) end)

    %{driver: driver, principal: principal, socket: driver_socket(principal)}
  end

  defp cleanup(driver_id) do
    _ = Tracking.stop_tracking(driver_id)
    _ = StateCache.delete(driver_id)
    :ok
  end

  defp join!(socket, driver_id) do
    {:ok, _reply, channel} = subscribe_and_join(socket, "driver:#{driver_id}")

    on_exit(fn ->
      if Process.alive?(channel.channel_pid), do: close(channel)
    end)

    channel
  end

  defp on_duty!(channel) do
    ref = push(channel, "status", %{"status" => "online"})
    assert_reply ref, :ok, %{status: :online}
    channel
  end

  defp ping!(channel, overrides \\ %{}) do
    ref = push(channel, "ping", ping_params(overrides))
    assert_reply ref, :ok
    channel
  end

  defp ping_params(overrides) do
    Map.merge(
      %{
        "latitude" => -6.1754,
        "longitude" => 106.8272,
        "recorded_at" => DateTime.to_iso8601(DateTime.utc_now())
      },
      overrides
    )
  end

  defp job_at_pickup! do
    {:ok, order} =
      Dispatch.create_order(%{
        pickup_latitude: -6.1754,
        pickup_longitude: 106.8272,
        dropoff_latitude: -6.9,
        dropoff_longitude: 107.6,
        weight_kg: 50
      })

    order
  end

  describe "connect/3" do
    test "accepts a valid token and assigns the driver", %{driver: driver, principal: principal} do
      assert socket = driver_socket(principal)
      assert socket.assigns.driver_id == driver.id
    end

    test "refuses a forged token" do
      assert {:error, :invalid_token} = connect(DriverSocket, %{"token" => "nope"})
    end

    test "refuses a connection carrying no token" do
      assert {:error, :missing_token} = connect(DriverSocket, %{})
    end

    test "refuses a valid token whose principal is linked to no driver here" do
      assert {:error, :unlinked} =
               connect(DriverSocket, %{
                 "token" => IdentityJwks.token(role: "courier", sub: "principal-nobody")
               })
    end

    test "refuses a customer, whose token is valid and carries no courier authority" do
      assert {:error, :not_a_courier} =
               connect(DriverSocket, %{"token" => IdentityJwks.token(role: "customer")})
    end

    test "takes the token from the Sec-WebSocket-Protocol header, where no access log keeps it",
         %{driver: driver, principal: principal} do
      token = IdentityJwks.token(role: "courier", sub: principal)

      assert {:ok, socket} = connect(DriverSocket, %{}, connect_info: %{auth_token: token})
      assert socket.assigns.driver_id == driver.id
    end

    test "refuses a forged token in the header too" do
      assert {:error, :invalid_token} =
               connect(DriverSocket, %{}, connect_info: %{auth_token: "nope"})
    end
  end

  describe "handle_error/2" do
    test "answers 503 when identity could not be reached to check the token" do
      conn =
        DriverSocket.handle_error(
          Plug.Test.conn(:get, "/driver/websocket"),
          :identity_unavailable
        )

      assert conn.status == 503
    end

    test "answers 403 to a token that was actually refused" do
      conn = DriverSocket.handle_error(Plug.Test.conn(:get, "/driver/websocket"), :invalid_token)

      assert conn.status == 403
    end
  end

  describe "join/3 authorisation" do
    test "a driver may join its own topic", %{driver: driver, socket: socket} do
      assert {:ok, _reply, _channel} = subscribe_and_join(socket, "driver:#{driver.id}")
    end

    test "a driver may NOT join another driver's topic", %{socket: socket} do
      victim = driver_fixture()
      on_exit(fn -> cleanup(victim.id) end)

      assert {:error, %{reason: "forbidden"}} = subscribe_and_join(socket, "driver:#{victim.id}")

      assert {:error, :not_found} = Tracking.fetch_state(victim.id)
    end

    test "rejects a topic id that is not a bare positive integer", %{socket: socket} do
      for bad <- ["abc", "7abc", "7.0", "0", "-1", ""] do
        assert {:error, %{reason: "invalid_topic"}} =
                 subscribe_and_join(socket, "driver:#{bad}"),
               "expected #{inspect(bad)} to be rejected"
      end
    end

    test "rejects a topic naming a driver the socket is not", %{socket: socket} do
      assert {:error, %{reason: reason}} = subscribe_and_join(socket, "driver:999999999")
      assert reason in ["forbidden", "not_found"]
    end

    test "joining does not put the driver on duty, and says so", %{driver: driver, socket: socket} do
      assert {:ok, %{status: :offline}, _channel} =
               subscribe_and_join(socket, "driver:#{driver.id}")

      assert {:ok, %{status: :offline}} = Tracking.fetch_driver(driver.id)
      assert {:ok, %{status: :offline}} = Tracking.fetch_state(driver.id)
    end

    test "a courier whose approval was withdrawn cannot join again", %{
      driver: driver,
      socket: socket
    } do
      {:ok, _} = driver |> Driver.changeset(%{active: false}) |> Repo.update()

      assert {:error, %{reason: "pending_approval"}} =
               subscribe_and_join(socket, "driver:#{driver.id}")
    end
  end

  describe "handle_in ping" do
    setup %{driver: driver, socket: socket} do
      %{channel: join!(socket, driver.id)}
    end

    test "accepts a well formed ping and updates live state", %{channel: channel, driver: driver} do
      ref =
        push(channel, "ping", %{
          "latitude" => -6.2,
          "longitude" => 106.816666,
          "recorded_at" => "2026-07-21T10:00:00Z",
          "speed_kmh" => 42
        })

      assert_reply ref, :ok

      assert {:ok, state} = Tracking.fetch_state(driver.id)
      assert state.coordinates == {-6.2, 106.816666}
      assert state.speed_kmh === 42.0
    end

    test "refuses telemetry outside the CHECK constraint bounds", %{channel: channel} do
      ref =
        push(channel, "ping", %{
          "latitude" => 999.0,
          "longitude" => 0.0,
          "recorded_at" => "2026-07-21T10:00:00Z"
        })

      assert_reply ref, :error, %{reason: "invalid_telemetry"}
    end

    test "refuses an unparseable timestamp", %{channel: channel} do
      ref =
        push(channel, "ping", %{
          "latitude" => -6.2,
          "longitude" => 106.8,
          "recorded_at" => "yesterday"
        })

      assert_reply ref, :error, %{reason: "invalid_telemetry"}
    end

    test "refuses an unknown event", %{channel: channel} do
      ref = push(channel, "teleport", %{})
      assert_reply ref, :error, %{reason: "unknown_event"}
    end

    test "refuses a fix stamped further ahead than a phone clock drifts", %{channel: channel} do
      ahead = DateTime.add(DateTime.utc_now(), 3_600, :second)
      ref = push(channel, "ping", ping_params(%{"recorded_at" => DateTime.to_iso8601(ahead)}))

      assert_reply ref, :error, %{reason: "invalid_telemetry"}
    end

    test "a queued older fix does not move the driver back", %{channel: channel, driver: driver} do
      now = DateTime.utc_now()
      ping!(channel, %{"latitude" => -6.2, "recorded_at" => DateTime.to_iso8601(now)})

      ping!(channel, %{
        "latitude" => -6.3,
        "recorded_at" => DateTime.to_iso8601(DateTime.add(now, -60, :second))
      })

      assert {:ok, %{coordinates: {-6.2, _lng}}} = Tracking.fetch_state(driver.id)
    end

    test "refuses pings beyond the channel's budget", %{channel: channel} do
      previous = Application.fetch_env!(:fleet_pulse, FleetPulseWeb.DriverChannel)

      Application.put_env(:fleet_pulse, FleetPulseWeb.DriverChannel,
        ping_window_ms: 60_000,
        ping_limit: 2
      )

      on_exit(fn -> Application.put_env(:fleet_pulse, FleetPulseWeb.DriverChannel, previous) end)

      ping!(channel)
      ping!(channel)

      ref = push(channel, "ping", ping_params(%{}))
      assert_reply ref, :error, %{reason: "rate_limited"}
    end
  end

  describe "handle_in ping_batch" do
    setup %{driver: driver, socket: socket} do
      %{channel: socket |> join!(driver.id) |> on_duty!()}
    end

    defp offline_fix(recorded_at, latitude) do
      %{
        "latitude" => latitude,
        "longitude" => 106.8,
        "recorded_at" => DateTime.to_iso8601(recorded_at)
      }
    end

    test "stores the positions as history and answers what became of each", %{channel: channel} do
      now = DateTime.utc_now()

      batch = [
        offline_fix(DateTime.add(now, -120, :second), -6.2),
        offline_fix(DateTime.add(now, -120, :second), -6.2),
        offline_fix(DateTime.add(now, 3_600, :second), -6.2)
      ]

      ref = push(channel, "ping_batch", %{"pings" => batch})

      assert_reply ref, :ok, %{
        stored: [0],
        duplicates: [1],
        refused: [%{index: 2, reason: :ahead_of_server_clock}]
      }
    end

    test "never moves the courier or makes its position fresh for dispatch", %{
      channel: channel,
      driver: driver
    } do
      now = DateTime.utc_now()
      ping!(channel, %{"latitude" => -6.1754, "recorded_at" => DateTime.to_iso8601(now)})
      {:ok, before} = Tracking.fetch_state(driver.id)

      ref =
        push(channel, "ping_batch", %{
          "pings" => [offline_fix(DateTime.add(now, 60, :second), -7.5)]
        })

      assert_reply ref, :ok, %{stored: [0]}

      assert {:ok, after_batch} = Tracking.fetch_state(driver.id)
      assert after_batch.coordinates == before.coordinates
      assert after_batch.located_at == before.located_at
      assert after_batch.recorded_at == before.recorded_at
    end

    test "has a budget of its own, which neither spends nor blocks the live pings", %{
      channel: channel
    } do
      previous = Application.fetch_env!(:fleet_pulse, FleetPulseWeb.DriverChannel)

      Application.put_env(
        :fleet_pulse,
        FleetPulseWeb.DriverChannel,
        Keyword.merge(previous, ping_limit: 2, ping_batch_limit: 1)
      )

      on_exit(fn -> Application.put_env(:fleet_pulse, FleetPulseWeb.DriverChannel, previous) end)

      batch = %{"pings" => [offline_fix(DateTime.add(DateTime.utc_now(), -60, :second), -6.2)]}

      ref = push(channel, "ping_batch", batch)
      assert_reply ref, :ok, %{stored: [0]}

      ref = push(channel, "ping_batch", batch)
      assert_reply ref, :error, %{reason: "rate_limited"}

      ping!(channel)
      ping!(channel)
    end

    test "refuses a batch it cannot read", %{channel: channel} do
      for payload <- [%{}, %{"pings" => "lots"}] do
        ref = push(channel, "ping_batch", payload)
        assert_reply ref, :error, %{reason: "invalid_batch"}
      end

      too_many =
        for second <- 1..101, do: offline_fix(DateTime.add(DateTime.utc_now(), -second), -6.2)

      ref = push(channel, "ping_batch", %{"pings" => too_many})
      assert_reply ref, :error, %{reason: "batch_too_large"}
    end
  end

  describe "handle_in with a malformed job id" do
    setup %{driver: driver, socket: socket} do
      %{channel: join!(socket, driver.id)}
    end

    test "names the bad id instead of calling the event unknown", %{channel: channel} do
      for event <- ["pickup", "pod_upload", "delivered"],
          payload <- [%{"order_id" => "12"}, %{"order_id" => 0}, %{}] do
        ref = push(channel, event, payload)
        assert_reply ref, :error, %{reason: "invalid_order_id"}
      end
    end
  end

  describe "handle_in status" do
    setup %{driver: driver, socket: socket} do
      %{channel: join!(socket, driver.id)}
    end

    test "goes on duty and answers the status it is in", %{channel: channel, driver: driver} do
      ref = push(channel, "status", %{"status" => "online"})

      assert_reply ref, :ok, %{status: :online}
      assert {:ok, %{status: :online}} = Tracking.fetch_driver(driver.id)
      assert {:ok, %{status: :online}} = Tracking.fetch_state(driver.id)
    end

    test "refuses busy from a driver carrying nothing", %{channel: channel, driver: driver} do
      on_duty!(channel)
      ref = push(channel, "status", %{"status" => "busy"})

      assert_reply ref, :error, %{reason: "no_active_job"}
      assert {:ok, %{status: :online}} = Tracking.fetch_state(driver.id)
    end

    test "a driver carrying a job who asks for online is busy, and is offered no second job",
         %{channel: channel, driver: driver} do
      channel |> on_duty!() |> ping!()
      {:ok, _} = Dispatch.assign_order(job_at_pickup!().id)

      ref = push(channel, "status", %{"status" => "offline"})
      assert_reply ref, :ok, %{status: :offline}

      ref = push(channel, "status", %{"status" => "online"})
      assert_reply ref, :ok, %{status: :busy}

      ping!(channel)
      assert {:error, :no_driver_available} = Dispatch.assign_order(job_at_pickup!().id)
      assert {:ok, %{status: :busy, active_orders_count: 1}} = Tracking.fetch_state(driver.id)
    end

    test "a driver carrying a job may say busy, and may always go offline", %{channel: channel} do
      channel |> on_duty!() |> ping!()
      {:ok, _} = Dispatch.assign_order(job_at_pickup!().id)

      ref = push(channel, "status", %{"status" => "busy"})
      assert_reply ref, :ok, %{status: :busy}

      ref = push(channel, "status", %{"status" => "offline"})
      assert_reply ref, :ok, %{status: :offline}
    end

    test "refuses a status message without a status", %{channel: channel} do
      ref = push(channel, "status", %{})
      assert_reply ref, :error, %{reason: "invalid_status"}
    end

    test "refuses an unknown status without minting an atom for it", %{channel: channel} do
      status = "napping_#{System.unique_integer([:positive])}"
      ref = push(channel, "status", %{"status" => status})

      assert_reply ref, :error, %{reason: "invalid_status"}
      assert_raise ArgumentError, fn -> String.to_existing_atom(status) end
    end
  end

  describe "terminate/2" do
    test "marks the driver offline but keeps its process warm", %{driver: driver, socket: socket} do
      channel = join!(socket, driver.id)
      :ok = Tracking.track_location(driver.id, telemetry_attrs())
      {:ok, before} = Tracking.fetch_state(driver.id)

      Process.unlink(channel.channel_pid)
      :ok = close(channel)

      assert {:ok, %{status: :offline}} = Tracking.fetch_driver(driver.id)

      assert {:ok, warm} = Tracking.fetch_state(driver.id)
      assert warm.coordinates == before.coordinates
    end

    test "a refused join must not knock the authenticated driver offline",
         %{driver: driver, socket: socket} do
      socket |> join!(driver.id) |> on_duty!()
      assert {:ok, %{status: :online}} = Tracking.fetch_driver(driver.id)

      victim = driver_fixture()
      on_exit(fn -> cleanup(victim.id) end)

      :ok = Tracking.subscribe_driver(driver.id)

      assert {:error, %{reason: "forbidden"}} = subscribe_and_join(socket, "driver:#{victim.id}")

      refute_receive {:driver_updated, %{status: :offline}}, 200
      assert {:ok, %{status: :online}} = Tracking.fetch_driver(driver.id)
    end
  end

  describe "a channel replaced by a reconnect" do
    test "dying late does not take the driver off duty", %{driver: driver, principal: principal} do
      old = driver_socket(principal) |> join!(driver.id) |> on_duty!()
      _new = driver_socket(principal) |> join!(driver.id) |> on_duty!()

      Process.unlink(old.channel_pid)
      :ok = close(old)

      assert {:ok, %{status: :online}} = Tracking.fetch_state(driver.id)
      assert {:ok, %{status: :online}} = Tracking.fetch_driver(driver.id)
    end

    test "the channel serving the driver dying takes it off duty", %{
      driver: driver,
      socket: socket
    } do
      channel = socket |> join!(driver.id) |> on_duty!()

      Process.unlink(channel.channel_pid)
      Process.exit(channel.channel_pid, :kill)

      assert eventually(fn ->
               match?({:ok, %{status: :offline}}, Tracking.fetch_state(driver.id))
             end)

      assert Repo.get!(Driver, driver.id).status == :offline
    end
  end

  describe "the idle reaper and a connected driver" do
    setup do
      Application.put_env(:fleet_pulse, IdleReaper,
        enabled: true,
        interval_ms: 60_000,
        idle_after_ms: 1
      )

      on_exit(fn -> Application.put_env(:fleet_pulse, IdleReaper, enabled: false) end)
      start_supervised!(IdleReaper)
      :ok
    end

    test "never stops a driver whose channel is open, however long it has been off duty",
         %{driver: driver, socket: socket} do
      channel = join!(socket, driver.id)
      Process.sleep(10)

      assert {:ok, 0} = IdleReaper.reap_now()

      channel |> on_duty!() |> ping!()

      assert {:ok, %{status: :online, coordinates: {_lat, _lng}}} =
               Tracking.fetch_state(driver.id)
    end
  end

  describe "assignment push" do
    setup %{driver: driver, socket: socket} do
      channel = socket |> join!(driver.id) |> on_duty!()

      :ok =
        Tracking.track_location(
          driver.id,
          telemetry_attrs(%{latitude: -6.1754, longitude: 106.8272})
        )

      {:ok, _state} = Tracking.fetch_state(driver.id)
      %{channel: channel}
    end

    test "advances the order through pickup and delivery from the device", %{
      driver: driver,
      channel: channel
    } do
      {:ok, order} =
        Dispatch.create_order(%{
          pickup_latitude: -6.1754,
          pickup_longitude: 106.8272,
          dropoff_latitude: -6.9,
          dropoff_longitude: 107.6,
          weight_kg: 50
        })

      {:ok, _} = Dispatch.assign_order(order.id)
      assert_push "order_assigned", _payload

      ref = push(channel, "pickup", %{"order_id" => order.id})
      assert_reply ref, :ok
      assert {:ok, %{status: :picked_up}} = Dispatch.fetch_order(order.id)

      photo = photo_bytes()
      digest = :crypto.hash(:sha256, photo)

      ref =
        push(channel, "pod_upload", %{
          "order_id" => order.id,
          "photo_sha256" => Base.encode16(digest, case: :lower)
        })

      assert_reply ref, :ok, %{
        upload_url: upload_url,
        upload_headers: headers,
        photo_url: photo_url
      }

      assert String.starts_with?(upload_url, photo_url)

      assert headers == %{
               "if-none-match" => "*",
               "x-amz-checksum-sha256" => Base.encode64(digest)
             }

      :ok = FakeStorage.uploaded(photo_url, photo)

      delivered = signed(%{"order_id" => order.id, "pod_photo_url" => photo_url})

      ref = push(channel, "delivered", delivered)

      assert_reply ref, :ok
      assert {:ok, %{status: :delivered}} = Dispatch.fetch_order(order.id)

      assert {:ok, %{status: :online}} = Tracking.fetch_state(driver.id)

      ref = push(channel, "delivered", delivered)
      assert_reply ref, :ok

      ref = push(channel, "pickup", %{"order_id" => order.id})
      assert_reply ref, :error, %{reason: "invalid_transition"}
    end

    test "a retried pickup whose reply was lost answers success", %{channel: channel} do
      {:ok, order} = Dispatch.assign_order(job_at_pickup!().id)
      assert_push "order_assigned", _payload

      for _attempt <- 1..2 do
        ref = push(channel, "pickup", %{"order_id" => order.id})
        assert_reply ref, :ok
      end
    end

    test "refuses a delivery without the customer's signature", %{channel: channel} do
      {:ok, order} = Dispatch.assign_order(job_at_pickup!().id)
      assert_push "order_assigned", _payload

      ref = push(channel, "pickup", %{"order_id" => order.id})
      assert_reply ref, :ok

      unsigned =
        proof_for(order.id) |> Map.delete("pod_signature") |> Map.put("order_id", order.id)

      ref = push(channel, "delivered", unsigned)

      assert_reply ref, :error, %{reason: "signature_required"}
      assert {:ok, %{status: :picked_up}} = Dispatch.fetch_order(order.id)
    end

    test "tells the courier a job was taken off it", %{channel: channel, driver: driver} do
      {:ok, order} = Dispatch.assign_order(job_at_pickup!().id)
      assert_push "order_assigned", _payload

      {:ok, _} = Dispatch.unassign_order(order.id, "admin-principal")

      assert_push "order_unassigned", %{id: id}
      assert id == order.id
      assert_push "active_order", %{order: nil}
      assert {:ok, %{status: :online}} = Tracking.fetch_state(driver.id)

      ref = push(channel, "pickup", %{"order_id" => order.id})
      assert_reply ref, :error, %{reason: "forbidden"}
    end

    test "hands out no upload address without the photo's SHA-256", %{channel: channel} do
      {:ok, order} =
        Dispatch.create_order(%{
          pickup_latitude: -6.1754,
          pickup_longitude: 106.8272,
          dropoff_latitude: -6.9,
          dropoff_longitude: 107.6,
          weight_kg: 50
        })

      {:ok, _} = Dispatch.assign_order(order.id)
      assert_push "order_assigned", _payload

      ref = push(channel, "pickup", %{"order_id" => order.id})
      assert_reply ref, :ok

      ref = push(channel, "pod_upload", %{"order_id" => order.id})
      assert_reply ref, :error, %{reason: "invalid_photo_hash"}

      ref =
        push(channel, "pod_upload", %{"order_id" => order.id, "photo_sha256" => "not-a-digest"})

      assert_reply ref, :error, %{reason: "invalid_photo_hash"}
    end

    test "refuses a delivery with no photo and leaves the parcel picked up", %{channel: channel} do
      {:ok, order} =
        Dispatch.create_order(%{
          pickup_latitude: -6.1754,
          pickup_longitude: 106.8272,
          dropoff_latitude: -6.9,
          dropoff_longitude: 107.6,
          weight_kg: 50
        })

      {:ok, _} = Dispatch.assign_order(order.id)
      assert_push "order_assigned", _payload

      ref = push(channel, "pickup", %{"order_id" => order.id})
      assert_reply ref, :ok

      ref = push(channel, "delivered", signed(%{"order_id" => order.id}))
      assert_reply ref, :error, %{reason: "invalid_proof"}
      assert {:ok, %{status: :picked_up}} = Dispatch.fetch_order(order.id)
    end

    test "refuses to advance an order the driver does not own", %{
      channel: channel,
      driver: driver
    } do
      intruder = driver_fixture(%{capacity_kg: 500})
      on_exit(fn -> cleanup(intruder.id) end)
      {:ok, _pid} = Tracking.start_tracking(intruder.id)
      {:ok, _} = Tracking.set_status(intruder.id, :online)

      :ok =
        Tracking.track_location(
          intruder.id,
          telemetry_attrs(%{latitude: -6.1754, longitude: 106.8272})
        )

      {:ok, _} = Tracking.fetch_state(intruder.id)
      {:ok, _} = Tracking.set_status(driver.id, :offline)

      {:ok, order} =
        Dispatch.create_order(%{
          pickup_latitude: -6.1754,
          pickup_longitude: 106.8272,
          dropoff_latitude: -6.9,
          dropoff_longitude: 107.6,
          weight_kg: 200
        })

      {:ok, assigned} = Dispatch.assign_order(order.id)
      assert assigned.driver_id == intruder.id

      ref = push(channel, "pickup", %{"order_id" => order.id})
      assert_reply ref, :error, %{reason: "forbidden"}
    end

    test "pushes an assigned order to the driver's device" do
      {:ok, order} =
        Dispatch.create_order(%{
          pickup_latitude: -6.1754,
          pickup_longitude: 106.8272,
          dropoff_latitude: -6.9,
          dropoff_longitude: 107.6,
          weight_kg: 50
        })

      assert {:ok, _assigned} = Dispatch.assign_order(order.id)

      assert_push "order_assigned", payload
      assert payload.id == order.id
      assert payload.status == :assigned
      assert payload.pickup == %{latitude: -6.1754, longitude: 106.8272}
    end
  end

  describe "active order on join" do
    test "a driver with no order is told so on join", %{driver: driver, socket: socket} do
      {:ok, _reply, chan} = subscribe_and_join(socket, "driver:#{driver.id}")
      on_exit(fn -> if Process.alive?(chan.channel_pid), do: close(chan) end)

      assert_push "active_order", %{order: nil}
    end

    test "a reconnecting driver receives their in-flight order and stays busy",
         %{driver: driver, socket: socket} do
      {:ok, _pid} = Tracking.start_tracking(driver.id)
      {:ok, _} = Tracking.set_status(driver.id, :online)

      :ok =
        Tracking.track_location(
          driver.id,
          telemetry_attrs(%{latitude: -6.1754, longitude: 106.8272})
        )

      {:ok, _} = Tracking.fetch_state(driver.id)

      {:ok, order} =
        Dispatch.create_order(%{
          pickup_latitude: -6.1754,
          pickup_longitude: 106.8272,
          dropoff_latitude: -6.9,
          dropoff_longitude: 107.6,
          weight_kg: 50
        })

      {:ok, _} = Dispatch.assign_order(order.id)

      {:ok, _reply, chan} = subscribe_and_join(socket, "driver:#{driver.id}")
      on_exit(fn -> if Process.alive?(chan.channel_pid), do: close(chan) end)

      assert_push "active_order", %{order: %{id: id}}
      assert id == order.id

      assert {:ok, %{status: :busy}} = Tracking.fetch_state(driver.id)
    end
  end

  defp eventually(fun, retries \\ 50) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> Process.sleep(10) && eventually(fun, retries - 1)
    end
  end
end
