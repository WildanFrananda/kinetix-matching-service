defmodule FleetPulse.Dispatch.EvidenceFeedTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias FleetPulse.Dispatch.DeliveryEvidence
  alias FleetPulse.Dispatch.EvidenceFeed
  alias FleetPulse.Dispatch.Order
  alias FleetPulse.Proto.Common.V1.LogCursor
  alias FleetPulse.Proto.Fulfillment.V1.DeliveriesSinceRequest
  alias FleetPulse.Proto.Fulfillment.V1.DeliveriesSinceResponse
  alias FleetPulse.Proto.Fulfillment.V1.DeliveryEvidence, as: WireEvidence
  alias FleetPulse.Repo
  alias FleetPulse.ScratchDatabase
  alias FleetPulse.Servers.DeliveryEvidenceServer
  alias FleetPulse.Tracking.Driver

  setup_all do
    database = ScratchDatabase.start!()
    on_exit(fn -> ScratchDatabase.stop!(database) end)
    %{database: database}
  end

  setup %{database: database} do
    ScratchDatabase.use!(database)
  end

  defp courier! do
    unique = System.unique_integer([:positive])

    Repo.insert!(%Driver{
      vehicle_plate: "B #{unique} EV",
      capacity_kg: 100,
      principal_id: "courier-#{unique}"
    })
  end

  defp job!(order_number) do
    Repo.insert!(%Order{
      pickup_latitude: -6.2,
      pickup_longitude: 106.8,
      dropoff_latitude: -6.9,
      dropoff_longitude: 107.6,
      status: :picked_up,
      order_number: order_number,
      driver_id: courier!().id
    })
  end

  defp record_delivery!(order, signature \\ nil) do
    photo = :crypto.hash(:sha256, "photo of #{order.id}")

    Repo.insert!(
      DeliveryEvidence.changeset(order, "courier-of-#{order.id}", photo, signature, now())
    )

    {1, _} =
      Repo.update_all(from(o in Order, where: o.id == ^order.id), set: [status: :delivered])

    order
  end

  defp deliver!(order_number \\ number()) do
    {:ok, order} = Repo.transaction(fn -> order_number |> job!() |> record_delivery!() end)
    order
  end

  defp number, do: "ORD-#{System.unique_integer([:positive])}"

  defp now, do: DateTime.utc_now()

  defp tail(position \\ {0, 0}) do
    case EvidenceFeed.since(position, 500) do
      %{has_more: true, next: next} -> tail(next)
      %{next: next} -> next
    end
  end

  defp numbers(page), do: Enum.map(page.deliveries, & &1.order_number)

  test "serves deliveries in commit order, a page at a time" do
    start = tail()
    delivered = for _ <- 1..5, do: deliver!().order_number

    first = EvidenceFeed.since(start, 2)
    second = EvidenceFeed.since(first.next, 2)
    third = EvidenceFeed.since(second.next, 2)
    after_all = EvidenceFeed.since(third.next, 2)

    assert numbers(first) ++ numbers(second) ++ numbers(third) == delivered
    assert {first.has_more, second.has_more, third.has_more} == {true, true, false}
    assert after_all == %{deliveries: [], next: third.next, has_more: false}
  end

  test "a delivery whose transaction commits after a later one's is served, not skipped", %{
    database: database
  } do
    start = tail()
    parent = self()
    early = number()
    late = number()

    holder =
      Task.async(fn ->
        ScratchDatabase.use!(database)

        {:ok, _} =
          Repo.transaction(fn ->
            early |> job!() |> record_delivery!()
            send(parent, :written)

            receive do
              :commit -> :ok
            end
          end)
      end)

    assert_receive :written, 5_000
    deliver!(late)

    while_open = EvidenceFeed.since(start, 100)
    send(holder.pid, :commit)
    Task.await(holder)
    once_committed = EvidenceFeed.since(while_open.next, 100)

    assert numbers(while_open) ++ numbers(once_committed) == [early, late]
  end

  test "evidence written in an earlier transaction does not cover a later delivery" do
    order = job!(number())

    Repo.insert!(DeliveryEvidence.changeset(order, "courier", <<7::256>>, nil, now()))

    assert_raise Postgrex.Error, ~r/with no evidence written before it/, fn ->
      Repo.update_all(from(o in Order, where: o.id == ^order.id), set: [status: :delivered])
    end
  end

  describe "DeliveriesSince" do
    defp ask(request), do: DeliveryEvidenceServer.deliveries_since(request, nil)

    test "puts each delivery on the wire as the log holds it" do
      start = tail()
      signed = :crypto.hash(:sha256, "a signature")

      {:ok, unnumbered} =
        Repo.transaction(fn -> nil |> job!() |> record_delivery!(signed) end)

      {transaction_id, sequence} = start

      assert %DeliveriesSinceResponse{deliveries: [wire], has_more: false, next: next} =
               ask(%DeliveriesSinceRequest{
                 after: %LogCursor{transaction_id: transaction_id, sequence: sequence}
               })

      assert %WireEvidence{
               order_number: "",
               driver_principal_id: driver,
               photo_sha256: photo,
               signature_sha256: ^signed,
               delivered_at: %Google.Protobuf.Timestamp{seconds: seconds}
             } = wire

      assert driver == "courier-of-#{unnumbered.id}"
      assert photo == :crypto.hash(:sha256, "photo of #{unnumbered.id}")
      assert seconds > 0
      assert wire.position == next
      assert {next.transaction_id, next.sequence} == tail()
    end

    test "sends an empty signature when the courier drew none" do
      start = tail()
      deliver!()
      {transaction_id, sequence} = start

      assert %DeliveriesSinceResponse{deliveries: [%WireEvidence{signature_sha256: ""}]} =
               ask(%DeliveriesSinceRequest{
                 after: %LogCursor{transaction_id: transaction_id, sequence: sequence}
               })
    end

    test "reads from the start of the log when no cursor is given" do
      deliver!()

      assert %DeliveriesSinceResponse{deliveries: [_ | _]} = ask(%DeliveriesSinceRequest{})
    end

    test "serves a hundred by default and never more than five hundred" do
      start = tail()

      {:ok, _} =
        Repo.transaction(fn ->
          for _ <- 1..501, do: number() |> job!() |> record_delivery!()
        end)

      {transaction_id, sequence} = start
      after_start = %LogCursor{transaction_id: transaction_id, sequence: sequence}

      default = ask(%DeliveriesSinceRequest{after: after_start, limit: 0})
      capped = ask(%DeliveriesSinceRequest{after: after_start, limit: 10_000})

      assert {length(default.deliveries), default.has_more} == {100, true}
      assert {length(capped.deliveries), capped.has_more} == {500, true}
    end

    test "refuses a cursor whose sequence no row can have" do
      error =
        assert_raise GRPC.RPCError, fn ->
          ask(%DeliveriesSinceRequest{
            after: %LogCursor{transaction_id: 1, sequence: 9_223_372_036_854_775_808}
          })
        end

      assert error.status == GRPC.Status.invalid_argument()
    end
  end

  test "the migration's down removes the log and its guards, and up restores them" do
    database = ScratchDatabase.start!()
    on_exit(fn -> ScratchDatabase.stop!(database) end)
    ScratchDatabase.use!(database)

    _ =
      Ecto.Migrator.run(Repo, :down,
        to: 20_261_016_160_000,
        dynamic_repo: database.repo,
        log: false
      )

    assert %{rows: [[nil]]} = Repo.query!("SELECT to_regclass('delivery_evidence')::text")

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*)::int FROM pg_proc WHERE proname IN " <>
                 "('delivery_evidence_is_append_only', 'order_delivery_is_logged')"
             )

    order = job!(number())

    assert {1, _} =
             Repo.update_all(from(o in Order, where: o.id == ^order.id),
               set: [status: :delivered]
             )

    _ = Ecto.Migrator.run(Repo, :up, all: true, dynamic_repo: database.repo, log: false)

    assert_raise Postgrex.Error, ~r/with no evidence written before it/, fn ->
      Repo.insert!(%Order{
        pickup_latitude: -6.2,
        pickup_longitude: 106.8,
        dropoff_latitude: -6.9,
        dropoff_longitude: 107.6,
        status: :delivered,
        driver_id: courier!().id
      })
    end
  end
end
