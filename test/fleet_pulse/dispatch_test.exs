defmodule FleetPulse.DispatchTest do
  use FleetPulse.DataCase, async: false

  import FleetPulse.DeliveryProof
  import FleetPulse.TrackingFixtures

  alias FleetPulse.Dispatch
  alias FleetPulse.Dispatch.Events
  alias FleetPulse.Dispatch.Order
  alias FleetPulse.Dispatch.Unassignment
  alias FleetPulse.FakeStorage
  alias FleetPulse.Tracking
  alias FleetPulse.Tracking.DriverRegistry
  alias FleetPulse.Tracking.LocationPing
  alias FleetPulse.Tracking.StateCache

  @pickup {-6.1754, 106.8272}

  setup do
    Enum.each(StateCache.all(), &StateCache.delete(&1.driver_id))
    :ok
  end

  defp north({lat, lng}, km), do: {lat + km / 111.19492664455873, lng}

  defp online_driver(distance_km, capacity_kg) do
    {lat, lng} = north(@pickup, distance_km)
    driver = driver_fixture(%{capacity_kg: capacity_kg})
    on_exit(fn -> cleanup(driver.id) end)

    {:ok, _pid} = Tracking.start_tracking(driver.id)
    {:ok, _driver} = Tracking.set_status(driver.id, :online)
    :ok = Tracking.track_location(driver.id, telemetry_attrs(%{latitude: lat, longitude: lng}))
    {:ok, _state} = Tracking.fetch_state(driver.id)

    driver
  end

  defp cleanup(driver_id) do
    _ = Tracking.stop_tracking(driver_id)
    _ = StateCache.delete(driver_id)
    :ok
  end

  defp order!(overrides \\ %{}) do
    {:ok, order} = Dispatch.create_order(order_attrs(overrides))
    order
  end

  defp assigned_order! do
    {:ok, order} = Dispatch.assign_order(order!().id)
    order
  end

  defp order_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        pickup_latitude: elem(@pickup, 0),
        pickup_longitude: elem(@pickup, 1),
        dropoff_latitude: -6.9,
        dropoff_longitude: 107.6,
        weight_kg: 100
      },
      overrides
    )
  end

  describe "assign_order/2" do
    test "assigns the nearest eligible driver and marks it busy" do
      _far = online_driver(2.0, 100)
      near = online_driver(0.5, 100)

      order = order!()

      assert {:ok, assigned} = Dispatch.assign_order(order.id)
      assert assigned.status == :assigned
      assert assigned.driver_id == near.id
      assert assigned.assigned_at != nil

      assert {:ok, %{status: :busy}} = Tracking.fetch_state(near.id)
    end

    test "skips drivers that cannot carry the load" do
      _small = online_driver(0.5, 50)
      big = online_driver(2.0, 500)

      assert {:ok, assigned} = Dispatch.assign_order(order!(%{weight_kg: 200}).id)
      assert assigned.driver_id == big.id
    end

    test "fails when no driver is in range" do
      _far = online_driver(50.0, 100)

      assert {:error, :no_driver_available} = Dispatch.assign_order(order!().id)
    end

    test "refuses to assign an order that is not pending" do
      online_driver(0.5, 100)
      order = order!()
      {:ok, _} = Dispatch.assign_order(order.id)

      assert {:error, :already_assigned} = Dispatch.assign_order(order.id)
    end

    test "reports an order that does not exist" do
      assert {:error, :not_found} = Dispatch.assign_order(999_999_999)
    end

    test "does not claim a driver when assignment finds none" do
      near = online_driver(0.5, 50)
      assert {:error, :no_driver_available} = Dispatch.assign_order(order!(%{weight_kg: 500}).id)

      assert {:ok, %{status: :online}} = Tracking.fetch_state(near.id)
    end

    test "broadcasts the assignment on the driver's dispatch topic" do
      driver = online_driver(0.5, 100)
      :ok = Events.subscribe_driver(driver.id)

      order = order!()
      assert {:ok, _assigned} = Dispatch.assign_order(order.id)

      assert_receive {:order_assigned, %Order{id: id, driver_id: assigned_to}}
      assert id == order.id
      assert assigned_to == driver.id
    end
  end

  describe "concurrent assignment" do
    test "two orders racing for one driver get different drivers" do
      d1 = online_driver(0.5, 100)
      d2 = online_driver(0.5, 100)

      orders = [order!(), order!()]

      results =
        orders
        |> Task.async_stream(
          fn order -> Dispatch.assign_order(order.id) end,
          max_concurrency: 2,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({:ok, _}, &1))

      assigned_ids = Enum.map(results, fn {:ok, order} -> order.driver_id end)

      assert Enum.sort(assigned_ids) == Enum.sort([d1.id, d2.id])
    end

    test "many claims on ONE driver yield exactly one winner" do
      driver = online_driver(0.5, 100)

      orders = for _ <- 1..20, do: order!()

      results =
        orders
        |> Task.async_stream(
          fn order -> Dispatch.assign_order(order.id) end,
          max_concurrency: 20,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      winners = Enum.filter(results, &match?({:ok, _}, &1))
      losers = Enum.filter(results, &match?({:error, :no_driver_available}, &1))

      assert length(winners) == 1
      assert length(losers) == 19

      assert [{:ok, won}] = winners
      assert won.driver_id == driver.id
      assert {:ok, %{status: :busy}} = Tracking.fetch_state(driver.id)
    end
  end

  describe "order lifecycle" do
    test "advances assigned -> picked_up -> delivered with POD photo and signature, freeing the driver" do
      driver = online_driver(0.5, 100)
      order = assigned_order!()
      assert {:ok, %{status: :busy}} = Tracking.fetch_state(driver.id)

      assert {:ok, %{status: :picked_up}} = Dispatch.mark_picked_up(order.id, driver.id)

      signature = signature_uri(signature_png())
      pod_payload = Map.put(proof_for(order.id), "pod_signature", signature)

      assert {:ok, delivered_order} = Dispatch.mark_delivered(order.id, driver.id, pod_payload)
      assert delivered_order.status == :delivered
      assert delivered_order.pod_photo_url == pod_payload["pod_photo_url"]
      assert delivered_order.pod_signature == signature

      assert {:ok, %{status: :online}} = Tracking.fetch_state(driver.id)
    end

    test "refuses a proof of delivery that names nothing fetchable" do
      driver = online_driver(0.5, 100)
      order = assigned_order!()
      {:ok, _} = Dispatch.mark_picked_up(order.id, driver.id)

      assert {:error, :invalid_proof} =
               Dispatch.mark_delivered(
                 order.id,
                 driver.id,
                 signed(%{"pod_photo_url" => "the parcel was left by the gate"})
               )

      assert {:ok, %{status: :picked_up, pod_photo_url: nil}} = Dispatch.fetch_order(order.id)
    end

    test "refuses a signature that is not a PNG carried in a data URI" do
      driver = online_driver(0.5, 100)
      order = assigned_order!()
      {:ok, _} = Dispatch.mark_picked_up(order.id, driver.id)
      proof = proof_for(order.id)

      for signature <- [
            "Budi",
            "https://storage.kinetix.test/signatures/budi.png",
            "data:image/svg+xml;base64,PHN2Zz4=",
            "data:image/png;base64,not base64 at all",
            "data:image/png;base64," <> Base.encode64("a GIF, not a PNG")
          ] do
        assert {:error, :invalid_proof} =
                 Dispatch.mark_delivered(
                   order.id,
                   driver.id,
                   Map.put(proof, "pod_signature", signature)
                 )
      end

      assert {:ok, %{status: :picked_up}} = Dispatch.fetch_order(order.id)
    end

    test "refuses a photo uploaded for another job" do
      driver = online_driver(0.5, 100)
      order = assigned_order!()
      {:ok, _} = Dispatch.mark_picked_up(order.id, driver.id)

      assert {:error, :invalid_proof} =
               Dispatch.mark_delivered(order.id, driver.id, proof_for(order.id + 1))

      assert {:ok, %{status: :picked_up}} = Dispatch.fetch_order(order.id)
    end

    test "refuses a photo that was never uploaded" do
      driver = online_driver(0.5, 100)
      order = assigned_order!()
      {:ok, _} = Dispatch.mark_picked_up(order.id, driver.id)
      url = photo_url_for(order.id, photo_bytes())

      assert {:error, :invalid_proof} =
               Dispatch.mark_delivered(order.id, driver.id, signed(%{"pod_photo_url" => url}))
    end

    test "refuses a photo whose stored bytes are not the ones its name says" do
      driver = online_driver(0.5, 100)
      order = assigned_order!()
      {:ok, _} = Dispatch.mark_picked_up(order.id, driver.id)
      url = photo_url_for(order.id, photo_bytes())
      :ok = FakeStorage.uploaded(url, photo_bytes())

      assert {:error, :invalid_proof} =
               Dispatch.mark_delivered(order.id, driver.id, signed(%{"pod_photo_url" => url}))

      assert {:ok, %{status: :picked_up}} = Dispatch.fetch_order(order.id)
    end

    test "refuses a photo stored without the checksum its upload address required" do
      driver = online_driver(0.5, 100)
      order = assigned_order!()
      {:ok, _} = Dispatch.mark_picked_up(order.id, driver.id)
      url = photo_url_for(order.id, photo_bytes())
      :ok = FakeStorage.uploaded_without_checksum(url)

      assert {:error, :invalid_proof} =
               Dispatch.mark_delivered(order.id, driver.id, signed(%{"pod_photo_url" => url}))
    end

    test "refuses a photo under a name that is not a SHA-256" do
      driver = online_driver(0.5, 100)
      order = assigned_order!()
      {:ok, _} = Dispatch.mark_picked_up(order.id, driver.id)
      url = FakeStorage.object_url("pod/#{order.id}/#{Ecto.UUID.generate()}.jpg")
      :ok = FakeStorage.uploaded(url, photo_bytes())

      assert {:error, :invalid_proof} =
               Dispatch.mark_delivered(order.id, driver.id, signed(%{"pod_photo_url" => url}))
    end

    test "hands the courier carrying the job an upload address bound to the photo's SHA-256" do
      driver = online_driver(0.5, 100)
      order = assigned_order!()
      {:ok, _} = Dispatch.mark_picked_up(order.id, driver.id)
      digest = :crypto.hash(:sha256, photo_bytes())
      hex = Base.encode16(digest, case: :lower)

      assert {:ok, %{upload_url: upload_url, upload_headers: headers, photo_url: photo_url}} =
               Dispatch.pod_upload(order.id, driver.id, hex)

      assert {:ok, key} = FakeStorage.key_of(photo_url)
      assert key == "pod/#{order.id}/#{hex}.jpg"
      assert String.starts_with?(upload_url, photo_url <> "?")

      assert headers == %{
               "if-none-match" => "*",
               "x-amz-checksum-sha256" => Base.encode64(digest)
             }
    end

    test "hands out no upload address for a hash that is not a SHA-256" do
      driver = online_driver(0.5, 100)
      order = assigned_order!()
      {:ok, _} = Dispatch.mark_picked_up(order.id, driver.id)
      hex = Base.encode16(:crypto.hash(:sha256, photo_bytes()), case: :lower)

      for hash <- [nil, "", String.upcase(hex), String.slice(hex, 0, 63), hex <> "0", 42] do
        assert {:error, :invalid_photo_hash} = Dispatch.pod_upload(order.id, driver.id, hash)
      end
    end

    test "gives no upload address to another courier, or before the parcel is collected" do
      driver = online_driver(0.5, 100)
      order = assigned_order!()
      hex = Base.encode16(:crypto.hash(:sha256, photo_bytes()), case: :lower)

      assert {:error, :invalid_transition} = Dispatch.pod_upload(order.id, driver.id, hex)

      {:ok, _} = Dispatch.mark_picked_up(order.id, driver.id)

      assert {:error, :forbidden} = Dispatch.pod_upload(order.id, driver.id + 1_000, hex)
    end

    test "refuses a photo reference too long to be one" do
      driver = online_driver(0.5, 100)
      order = assigned_order!()
      {:ok, _} = Dispatch.mark_picked_up(order.id, driver.id)

      too_long = "https://storage.luxe.id/pod/" <> String.duplicate("a", 2_048) <> ".jpg"

      assert {:error, :invalid_proof} =
               Dispatch.mark_delivered(
                 order.id,
                 driver.id,
                 signed(%{"pod_photo_url" => too_long})
               )
    end

    test "an illegal transition still reads as an illegal transition" do
      driver = online_driver(0.5, 100)
      order = assigned_order!()

      assert {:error, :invalid_transition} = Dispatch.mark_delivered(order.id, driver.id, %{})
    end

    test "a delivery with no proof at all is still a delivery" do
      driver = online_driver(0.5, 100)
      order = assigned_order!()
      {:ok, _} = Dispatch.mark_picked_up(order.id, driver.id)

      assert {:ok, %{status: :delivered}} =
               Dispatch.mark_delivered(order.id, driver.id, proof_for(order.id))
    end

    test "refuses a pickup by a driver who does not own the order" do
      owner = online_driver(0.5, 100)
      intruder = online_driver(2.0, 100)

      {:ok, order} = Dispatch.assign_order(order!().id)
      assert order.driver_id == owner.id, "expected the nearer driver to be assigned"

      assert {:error, :forbidden} = Dispatch.mark_picked_up(order.id, intruder.id)
    end

    test "refuses delivery before pickup" do
      driver = online_driver(0.5, 100)
      order = assigned_order!()

      assert {:error, :invalid_transition} = Dispatch.mark_delivered(order.id, driver.id)
    end

    test "refuses a pickup on an order the driver was never assigned" do
      driver = online_driver(0.5, 100)
      {:ok, order} = Dispatch.create_order(order_attrs())

      assert {:error, :forbidden} = Dispatch.mark_picked_up(order.id, driver.id)
    end

    test "cancels an assigned order and frees the driver" do
      driver = online_driver(0.5, 100)
      order = assigned_order!()

      assert {:ok, %{status: :cancelled}} = Dispatch.cancel_order(order.id)
      assert {:ok, %{status: :online}} = Tracking.fetch_state(driver.id)
    end

    test "cancels a pending order that has no driver" do
      {:ok, order} = Dispatch.create_order(order_attrs())
      assert {:ok, %{status: :cancelled}} = Dispatch.cancel_order(order.id)
    end

    test "refuses to cancel a delivered order" do
      driver = online_driver(0.5, 100)
      order = assigned_order!()
      {:ok, _} = Dispatch.mark_picked_up(order.id, driver.id)
      {:ok, _} = Dispatch.mark_delivered(order.id, driver.id, proof_for(order.id))

      assert {:error, :invalid_transition} = Dispatch.cancel_order(order.id)
    end
  end

  describe "active_order_for_driver/1" do
    test "returns an assigned order" do
      driver = online_driver(0.5, 100)
      {:ok, order} = Dispatch.assign_order(order!().id)

      assert %{id: id} = Dispatch.active_order_for_driver(driver.id)
      assert id == order.id
    end

    test "returns a picked-up order" do
      driver = online_driver(0.5, 100)
      {:ok, order} = Dispatch.assign_order(order!().id)
      {:ok, _} = Dispatch.mark_picked_up(order.id, driver.id)

      assert %{status: :picked_up} = Dispatch.active_order_for_driver(driver.id)
    end

    test "returns nil once the order is delivered" do
      driver = online_driver(0.5, 100)
      {:ok, order} = Dispatch.assign_order(order!().id)
      {:ok, _} = Dispatch.mark_picked_up(order.id, driver.id)
      {:ok, _} = Dispatch.mark_delivered(order.id, driver.id, proof_for(order.id))

      assert Dispatch.active_order_for_driver(driver.id) == nil
    end

    test "returns nil for a driver with no order" do
      driver = online_driver(0.5, 100)
      assert Dispatch.active_order_for_driver(driver.id) == nil
    end
  end

  describe "list_active_orders/0" do
    test "lists non-terminal orders, excluding delivered and cancelled" do
      driver = online_driver(0.5, 100)

      {:ok, delivered} = Dispatch.assign_order(order!().id)
      {:ok, _} = Dispatch.mark_picked_up(delivered.id, driver.id)
      {:ok, _} = Dispatch.mark_delivered(delivered.id, driver.id, proof_for(delivered.id))

      {:ok, assigned} = Dispatch.assign_order(order!().id)

      {:ok, pending} = Dispatch.create_order(order_attrs())

      ids = Enum.map(Dispatch.list_active_orders(), & &1.id)

      assert assigned.id in ids
      assert pending.id in ids
      refute delivered.id in ids
    end
  end

  describe "order broadcasts" do
    test "every order change is announced on the fleet orders topic" do
      :ok = Dispatch.subscribe_orders()
      driver = online_driver(0.5, 100)

      {:ok, order} = Dispatch.create_order(order_attrs())
      assert_receive {:order_changed, %Order{status: :pending}}

      {:ok, _} = Dispatch.assign_order(order.id)
      assert_receive {:order_changed, %Order{status: :assigned}}

      {:ok, _} = Dispatch.mark_picked_up(order.id, driver.id)
      assert_receive {:order_changed, %Order{status: :picked_up}}

      {:ok, _} = Dispatch.mark_delivered(order.id, driver.id, proof_for(order.id))
      assert_receive {:order_changed, %Order{status: :delivered}}
    end
  end

  describe "count_delivered_today/0" do
    test "counts a delivered order" do
      driver = online_driver(0.5, 100)
      {:ok, order} = Dispatch.assign_order(order!().id)
      {:ok, _} = Dispatch.mark_picked_up(order.id, driver.id)
      {:ok, _} = Dispatch.mark_delivered(order.id, driver.id, proof_for(order.id))

      assert Dispatch.count_delivered_today() >= 1
    end
  end

  describe "list_orders/1" do
    test "filters by status, newest first" do
      driver = online_driver(0.5, 100)
      {:ok, delivered} = Dispatch.assign_order(order!().id)
      {:ok, _} = Dispatch.mark_picked_up(delivered.id, driver.id)
      {:ok, _} = Dispatch.mark_delivered(delivered.id, driver.id, proof_for(delivered.id))
      {:ok, pending} = Dispatch.create_order(order_attrs())

      delivered_ids = Enum.map(Dispatch.list_orders(status: :delivered).orders, & &1.id)
      assert delivered.id in delivered_ids
      refute pending.id in delivered_ids

      all_ids = Enum.map(Dispatch.list_orders(status: :all).orders, & &1.id)
      assert pending.id in all_ids
      assert delivered.id in all_ids
    end
  end

  describe "assign_order_to_driver/2" do
    test "assigns the chosen online driver" do
      driver = online_driver(0.5, 100)
      {:ok, order} = Dispatch.create_order(order_attrs())

      assert {:ok, assigned} = Dispatch.assign_order_to_driver(order.id, driver.id)
      assert assigned.driver_id == driver.id
      assert {:ok, %{status: :busy}} = Tracking.fetch_state(driver.id)
    end

    test "refuses a driver that is already busy" do
      driver = online_driver(0.5, 100)
      {:ok, first} = Dispatch.create_order(order_attrs())
      {:ok, _} = Dispatch.assign_order_to_driver(first.id, driver.id)

      {:ok, second} = Dispatch.create_order(order_attrs())

      assert {:error, :driver_unavailable} =
               Dispatch.assign_order_to_driver(second.id, driver.id)
    end

    test "says a driver who does not exist is not found, apart from a job that is not" do
      {:ok, order} = Dispatch.create_order(order_attrs())

      assert {:error, :driver_not_found} = Dispatch.assign_order_to_driver(order.id, 999_999_999)
      assert {:error, :not_found} = Dispatch.assign_order_to_driver(999_999_999, 999_999_999)
    end

    test "says a driver who exists but is not connected is not tracked" do
      driver = driver_fixture()
      {:ok, order} = Dispatch.create_order(order_attrs())

      assert {:error, :driver_not_tracked} = Dispatch.assign_order_to_driver(order.id, driver.id)
    end
  end

  describe "list_orders/1 paging" do
    test "pages newest first, and the cursor leads to the next page and no further" do
      orders = for _ <- 1..5, do: order!()
      ids = orders |> Enum.map(& &1.id) |> Enum.sort(:desc)
      newest = hd(ids)

      first = Dispatch.list_orders(limit: 2, before: newest + 1)
      assert Enum.map(first.orders, & &1.id) == Enum.take(ids, 2)
      assert first.next_cursor == Enum.at(ids, 1)

      second = Dispatch.list_orders(limit: 2, before: first.next_cursor)
      assert Enum.map(second.orders, & &1.id) == Enum.slice(ids, 2, 2)

      last = Dispatch.list_orders(limit: 2, before: Enum.at(ids, 3))
      assert Enum.map(last.orders, & &1.id) |> Enum.take(1) == [Enum.at(ids, 4)]
    end

    test "has no next page when everything fits" do
      order = order!()

      page = Dispatch.list_orders(limit: 200, before: order.id + 1)

      assert order.id in Enum.map(page.orders, & &1.id)
      assert page.next_cursor == nil
    end
  end

  describe "count_delivered_today/0 by delivery time" do
    test "a job delivered yesterday is not counted because its row was touched today" do
      driver = online_driver(0.5, 100)
      order = assigned_order!()
      {:ok, _} = Dispatch.mark_picked_up(order.id, driver.id)
      {:ok, _} = Dispatch.mark_delivered(order.id, driver.id, proof_for(order.id))
      before = Dispatch.count_delivered_today()

      yesterday = DateTime.add(DateTime.utc_now(), -2, :day)

      Order
      |> Ecto.Query.where([o], o.id == ^order.id)
      |> Repo.update_all(set: [delivered_at: yesterday, updated_at: DateTime.utc_now()])

      assert Dispatch.count_delivered_today() == before - 1
    end
  end

  describe "count_delivered_today/1 on the platform's clock" do
    defp delivered_at!(at) do
      order = assigned_order!()
      {:ok, _} = Dispatch.mark_picked_up(order.id, order.driver_id)
      {:ok, _} = Dispatch.mark_delivered(order.id, order.driver_id, proof_for(order.id))

      Order
      |> where([o], o.id == ^order.id)
      |> Repo.update_all(set: [delivered_at: at])

      order
    end

    test "the day begins at midnight in Jakarta, seven hours before UTC's" do
      online_driver(0.5, 100)
      _late_on_the_20th = delivered_at!(~U[2026-10-20 16:30:00.000000Z])
      _early_on_the_21st = delivered_at!(~U[2026-10-20 17:30:00.000000Z])

      assert Dispatch.count_delivered_today(~U[2026-10-21 03:00:00.000000Z]) == 1
      assert Dispatch.count_delivered_today(~U[2026-10-20 17:00:00.000000Z]) == 1
      assert Dispatch.count_delivered_today(~U[2026-10-20 16:59:59.000000Z]) == 2
    end
  end

  describe "proof of delivery" do
    test "refuses a delivery without the customer's signature" do
      driver = online_driver(0.5, 100)
      order = assigned_order!()
      {:ok, _} = Dispatch.mark_picked_up(order.id, driver.id)
      unsigned = Map.delete(proof_for(order.id), "pod_signature")

      assert {:error, :signature_required} =
               Dispatch.mark_delivered(order.id, driver.id, unsigned)

      assert {:error, :signature_required} =
               Dispatch.mark_delivered(
                 order.id,
                 driver.id,
                 Map.put(unsigned, "pod_signature", nil)
               )

      assert {:ok, %{status: :picked_up}} = Dispatch.fetch_order(order.id)
    end

    test "refuses a photo whose bytes are not a JPEG" do
      driver = online_driver(0.5, 100)
      order = assigned_order!()
      {:ok, _} = Dispatch.mark_picked_up(order.id, driver.id)
      png = signature_png()
      url = photo_url_for(order.id, png)
      :ok = FakeStorage.uploaded(url, png)

      assert {:error, :invalid_proof} =
               Dispatch.mark_delivered(order.id, driver.id, signed(%{"pod_photo_url" => url}))

      assert {:ok, %{status: :picked_up}} = Dispatch.fetch_order(order.id)
    end
  end

  describe "a repeated step by the courier who made it" do
    test "a repeated pickup answers what the first did and changes nothing" do
      driver = online_driver(0.5, 100)
      order = assigned_order!()
      :ok = Events.subscribe_driver(driver.id)

      assert {:ok, %{status: :picked_up}} = Dispatch.mark_picked_up(order.id, driver.id)
      assert_receive {:order_updated, %Order{status: :picked_up}}

      assert {:ok, %{status: :picked_up}} = Dispatch.mark_picked_up(order.id, driver.id)
      refute_receive {:order_updated, _order}, 50
    end

    test "a repeated delivery answers success and frees the courier once" do
      driver = online_driver(0.5, 100)
      {:ok, pid} = DriverRegistry.whereis(driver.id)
      :sys.replace_state(pid, fn state -> %{state | max_orders: 2} end)

      first = assigned_order!()
      second = assigned_order!()
      assert second.driver_id == driver.id

      {:ok, _} = Dispatch.mark_picked_up(first.id, driver.id)
      proof = proof_for(first.id)

      assert {:ok, %{status: :delivered}} = Dispatch.mark_delivered(first.id, driver.id, proof)
      assert {:ok, %{status: :delivered}} = Dispatch.mark_delivered(first.id, driver.id, proof)
      assert {:ok, %{status: :delivered}} = Dispatch.mark_delivered(first.id, driver.id, %{})

      assert {:ok, %{active_orders_count: 1}} = Tracking.fetch_state(driver.id)
    end

    test "another courier repeating it is still refused" do
      driver = online_driver(0.5, 100)
      order = assigned_order!()
      {:ok, _} = Dispatch.mark_picked_up(order.id, driver.id)
      {:ok, _} = Dispatch.mark_delivered(order.id, driver.id, proof_for(order.id))

      assert {:error, :forbidden} = Dispatch.mark_picked_up(order.id, driver.id + 1_000)
      assert {:error, :forbidden} = Dispatch.mark_delivered(order.id, driver.id + 1_000, %{})
    end
  end

  describe "unassign_order/2" do
    test "returns an assigned job to pending, frees the courier and records who did it" do
      driver = online_driver(0.5, 100)
      order = assigned_order!()
      :ok = Events.subscribe_driver(driver.id)

      assert {:ok, pending} = Dispatch.unassign_order(order.id, "admin-principal")
      assert pending.status == :pending
      assert pending.driver_id == nil
      assert pending.assigned_at == nil

      assert_receive {:order_unassigned, %Order{id: id}}
      assert id == order.id
      assert {:ok, %{status: :online, active_orders_count: 0}} = Tracking.fetch_state(driver.id)

      assert [%Unassignment{driver_id: taken_from, unassigned_by: "admin-principal"}] =
               Repo.all(Unassignment)

      assert taken_from == driver.id
    end

    test "offers the job again, but not to the courier it was taken from" do
      first = online_driver(0.5, 100)
      order = assigned_order!()
      assert order.driver_id == first.id

      {:ok, _} = Dispatch.unassign_order(order.id, "admin-principal")
      assert {:error, :no_driver_available} = Dispatch.assign_order(order.id)

      second = online_driver(1.0, 100)
      assert {:ok, reassigned} = Dispatch.assign_order(order.id)
      assert reassigned.driver_id == second.id
    end

    test "an administrator may still hand it back to that courier by name" do
      driver = online_driver(0.5, 100)
      order = assigned_order!()
      {:ok, _} = Dispatch.unassign_order(order.id, "admin-principal")

      assert {:ok, %{driver_id: id}} = Dispatch.assign_order_to_driver(order.id, driver.id)
      assert id == driver.id
    end

    test "order asking again for the job is offered a courier, not told it is finished" do
      online_driver(0.5, 100)
      number = "ORD-#{System.unique_integer([:positive])}"
      pickup = {elem(@pickup, 0), elem(@pickup, 1)}

      {:ok, order} = Dispatch.dispatch_for_order(number, "merchant-1", pickup, {-6.9, 107.6}, 0)
      {:ok, _} = Dispatch.unassign_order(order.id, "admin-principal")

      assert {:error, :no_driver_available} =
               Dispatch.dispatch_for_order(number, "merchant-1", pickup, {-6.9, 107.6}, 0)
    end

    test "refuses a job whose parcel the courier already holds" do
      driver = online_driver(0.5, 100)
      order = assigned_order!()
      {:ok, _} = Dispatch.mark_picked_up(order.id, driver.id)

      assert {:error, :invalid_transition} = Dispatch.unassign_order(order.id, "admin-principal")
      assert {:ok, %{status: :picked_up, driver_id: id}} = Dispatch.fetch_order(order.id)
      assert id == driver.id
    end

    test "refuses a job nobody carries, and one that does not exist" do
      order = order!()

      assert {:error, :not_assigned} = Dispatch.unassign_order(order.id, "admin-principal")
      assert {:error, :not_found} = Dispatch.unassign_order(999_999_999, "admin-principal")
    end
  end

  describe "cancel_order/1 limits" do
    test "refuses to cancel a parcel the courier already holds" do
      driver = online_driver(0.5, 100)
      order = assigned_order!()
      {:ok, _} = Dispatch.mark_picked_up(order.id, driver.id)

      assert {:error, :invalid_transition} = Dispatch.cancel_order(order.id)
      assert {:ok, %{status: :picked_up}} = Dispatch.fetch_order(order.id)
    end

    test "refuses to cancel a job that delivers a platform order, which order would never hear of" do
      online_driver(0.5, 100)
      number = "ORD-#{System.unique_integer([:positive])}"

      {:ok, order} =
        Dispatch.dispatch_for_order(number, "merchant-1", @pickup, {-6.9, 107.6}, 0)

      assert {:error, :bound_to_order} = Dispatch.cancel_order(order.id)
      assert {:ok, %{status: :assigned}} = Dispatch.fetch_order(order.id)
    end
  end

  describe "dispatch uses only positions sent while on duty" do
    test "a driver whose position came before going on duty is not dispatched until it pings" do
      {lat, lng} = north(@pickup, 0.5)
      driver = driver_fixture(%{capacity_kg: 100})
      on_exit(fn -> cleanup(driver.id) end)

      {:ok, _pid} = Tracking.start_tracking(driver.id)
      :ok = Tracking.track_location(driver.id, telemetry_attrs(%{latitude: lat, longitude: lng}))
      {:ok, _} = Tracking.set_status(driver.id, :online)
      order = order!()

      assert {:error, :no_driver_available} = Dispatch.assign_order(order.id)

      later = DateTime.add(DateTime.utc_now(), 1, :second)

      :ok =
        Tracking.track_location(
          driver.id,
          telemetry_attrs(%{latitude: lat, longitude: lng, recorded_at: later})
        )

      {:ok, _} = Tracking.fetch_state(driver.id)
      assert {:ok, %{driver_id: id}} = Dispatch.assign_order(order.id)
      assert id == driver.id
    end

    test "a position kept from before a cold restart is shown but not dispatched" do
      driver = online_driver(0.5, 100)
      {:ok, state} = Tracking.fetch_state(driver.id)

      Repo.insert!(%LocationPing{
        driver_id: driver.id,
        latitude: elem(state.coordinates, 0),
        longitude: elem(state.coordinates, 1),
        recorded_at: state.recorded_at,
        inserted_at: DateTime.utc_now()
      })

      :ok = Tracking.stop_tracking(driver.id)
      {:ok, _pid} = Tracking.start_tracking(driver.id)
      {:ok, _} = Tracking.set_status(driver.id, :online)

      assert {:ok, %{coordinates: {_lat, _lng}}} = Tracking.fetch_state(driver.id)
      assert {:error, :no_driver_available} = Dispatch.assign_order(order!().id)
    end
  end

  describe "multi-order queue per driver" do
    test "assigns multiple orders up to driver capacity limit (default 3)" do
      driver = online_driver(1.0, 500)

      {:ok, pid} = DriverRegistry.whereis(driver.id)
      :sys.replace_state(pid, fn state -> %{state | max_orders: 3} end)

      order1 = order!(%{weight_kg: 50})
      order2 = order!(%{weight_kg: 50})
      order3 = order!(%{weight_kg: 50})
      order4 = order!(%{weight_kg: 50})

      assert {:ok, _assigned1} = Dispatch.assign_order(order1.id)
      assert {:ok, %{status: :online, active_orders_count: 1}} = Tracking.fetch_state(driver.id)

      assert {:ok, _assigned2} = Dispatch.assign_order(order2.id)
      assert {:ok, %{status: :online, active_orders_count: 2}} = Tracking.fetch_state(driver.id)

      assert {:ok, _assigned3} = Dispatch.assign_order(order3.id)
      assert {:ok, %{status: :busy, active_orders_count: 3}} = Tracking.fetch_state(driver.id)

      assert {:error, :no_driver_available} = Dispatch.assign_order(order4.id)

      active_orders = Dispatch.active_orders_for_driver(driver.id)
      assert length(active_orders) == 3

      assert {:ok, _picked} = Dispatch.mark_picked_up(order1.id, driver.id)

      assert {:ok, _delivered} =
               Dispatch.mark_delivered(order1.id, driver.id, proof_for(order1.id))

      assert {:ok, %{status: :online, active_orders_count: 2}} = Tracking.fetch_state(driver.id)

      # Now 4th order can be assigned
      assert {:ok, _assigned4} = Dispatch.assign_order(order4.id)
      assert {:ok, %{status: :busy, active_orders_count: 3}} = Tracking.fetch_state(driver.id)
    end
  end
end
