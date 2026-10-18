defmodule FleetPulse.Dispatch.DeliveryEvidenceTest do
  use FleetPulse.DataCase, async: false

  import FleetPulse.DeliveryProof
  import FleetPulse.TrackingFixtures

  alias FleetPulse.Dispatch
  alias FleetPulse.Dispatch.DeliveryEvidence
  alias FleetPulse.Dispatch.Order
  alias FleetPulse.FakeOrder
  alias FleetPulse.Tracking
  alias FleetPulse.Tracking.StateCache

  @pickup {-6.1754, 106.8272}

  setup do
    Enum.each(StateCache.all(), &StateCache.delete(&1.driver_id))
    :ok = FakeOrder.start()
    :ok = FakeOrder.reset()
    :ok
  end

  defp courier do
    principal = "principal-#{System.unique_integer([:positive])}"
    driver = active_driver_fixture(principal)

    on_exit(fn ->
      _ = Tracking.stop_tracking(driver.id)
      _ = StateCache.delete(driver.id)
    end)

    {:ok, _pid} = Tracking.start_tracking(driver.id)
    {:ok, _} = Tracking.set_status(driver.id, :online)

    :ok =
      Tracking.track_location(
        driver.id,
        telemetry_attrs(%{latitude: elem(@pickup, 0), longitude: elem(@pickup, 1)})
      )

    {:ok, _state} = Tracking.fetch_state(driver.id)
    {driver, principal}
  end

  defp picked_up do
    {driver, principal} = courier()
    number = "ORD-#{System.unique_integer([:positive])}"

    {:ok, order} =
      Dispatch.dispatch_for_order(number, "merchant-1", @pickup, {-6.2088, 106.8456}, 1_200)

    {:ok, order} = Dispatch.mark_picked_up(order.id, driver.id)
    {order, driver, principal}
  end

  defp mark_delivered_directly(order) do
    Repo.transaction(fn ->
      Repo.update_all(from(o in Order, where: o.id == ^order.id), set: [status: :delivered])
    end)
  end

  describe "a delivery" do
    test "writes what matching saw: the photo's and the signature's SHA-256, the courier, the time" do
      {order, driver, principal} = picked_up()
      photo = photo_bytes()
      url = photo_url_for(order.id, photo)
      :ok = FleetPulse.FakeStorage.uploaded(url, photo)
      png = signature_png()

      {:ok, delivered} =
        Dispatch.mark_delivered(order.id, driver.id, %{
          "pod_photo_url" => url,
          "pod_signature" => signature_uri(png)
        })

      assert [evidence] = Repo.all(DeliveryEvidence)
      assert evidence.order_id == order.id
      assert evidence.order_number == order.order_number
      assert evidence.driver_principal_id == principal
      assert evidence.photo_sha256 == :crypto.hash(:sha256, photo)
      assert evidence.signature_sha256 == :crypto.hash(:sha256, png)
      assert evidence.delivered_at == delivered.delivered_at
    end

    test "with no signature records none" do
      {order, driver, _principal} = picked_up()

      {:ok, _delivered} = Dispatch.mark_delivered(order.id, driver.id, proof_for(order.id))

      assert [%DeliveryEvidence{signature_sha256: nil}] = Repo.all(DeliveryEvidence)
    end

    test "that is refused writes nothing" do
      {order, driver, _principal} = picked_up()
      url = photo_url_for(order.id, photo_bytes())

      assert {:error, :invalid_proof} =
               Dispatch.mark_delivered(order.id, driver.id, %{"pod_photo_url" => url})

      assert Repo.all(DeliveryEvidence) == []
    end
  end

  describe "Postgres" do
    test "refuses to mark a job delivered with no evidence written before it" do
      {order, _driver, _principal} = picked_up()

      assert_raise Postgrex.Error, ~r/with no evidence written before it/, fn ->
        mark_delivered_directly(order)
      end

      assert Repo.get(Order, order.id).status == :picked_up
    end

    test "refuses a job inserted as delivered" do
      driver = driver_fixture()

      assert_raise Postgrex.Error, ~r/with no evidence written before it/, fn ->
        Repo.transaction(fn ->
          Repo.insert!(%Order{
            pickup_latitude: -6.2,
            pickup_longitude: 106.8,
            dropoff_latitude: -6.9,
            dropoff_longitude: 107.6,
            status: :delivered,
            driver_id: driver.id
          })
        end)
      end
    end

    test "accepts the delivery once its evidence is in the same transaction" do
      {order, _driver, principal} = picked_up()

      {:ok, _} =
        Repo.transaction(fn ->
          Repo.insert!(
            DeliveryEvidence.changeset(order, principal, <<1::256>>, nil, DateTime.utc_now())
          )

          Repo.update_all(from(o in Order, where: o.id == ^order.id), set: [status: :delivered])
        end)

      assert Repo.get(Order, order.id).status == :delivered
    end

    test "keeps one delivery per job" do
      {order, driver, principal} = picked_up()
      {:ok, _} = Dispatch.mark_delivered(order.id, driver.id, proof_for(order.id))

      assert {:error, changeset} =
               Repo.insert(
                 DeliveryEvidence.changeset(order, principal, <<2::256>>, nil, DateTime.utc_now())
               )

      assert {"has already been taken", _} = changeset.errors[:order_id]
    end

    test "refuses a digest that is not 32 bytes, and evidence that names no courier" do
      {order, _driver, principal} = picked_up()

      for {courier, photo, signature, field} <- [
            {principal, <<1::248>>, nil, :photo_sha256},
            {principal, <<1::256>>, <<1::264>>, :signature_sha256},
            {"", <<1::256>>, nil, :driver_principal_id}
          ] do
        assert {:error, changeset} =
                 Repo.insert(
                   DeliveryEvidence.changeset(
                     order,
                     courier,
                     photo,
                     signature,
                     DateTime.utc_now()
                   )
                 )

        assert {"is invalid", [constraint: :check, constraint_name: _]} =
                 changeset.errors[field]
      end
    end

    test "keeps the log append-only" do
      {order, driver, _principal} = picked_up()
      {:ok, _} = Dispatch.mark_delivered(order.id, driver.id, proof_for(order.id))

      for statement <- [
            "UPDATE delivery_evidence SET driver_principal_id = 'someone-else'",
            "DELETE FROM delivery_evidence",
            "TRUNCATE delivery_evidence"
          ] do
        assert_raise Postgrex.Error, ~r/delivery_evidence is append-only/, fn ->
          Repo.transaction(fn -> Repo.query!(statement) end)
        end
      end

      assert [_still_there] = Repo.all(DeliveryEvidence)
    end
  end
end
