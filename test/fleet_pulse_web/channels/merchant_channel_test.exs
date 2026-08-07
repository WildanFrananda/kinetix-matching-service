defmodule FleetPulseWeb.MerchantChannelTest do
  use FleetPulseWeb.ChannelCase, async: true

  alias FleetPulse.Dispatch
  alias FleetPulseWeb.MerchantSocket
  alias FleetPulseWeb.MerchantToken

  setup do
    merchant_id = 101
    token = MerchantToken.sign(merchant_id)

    {:ok, socket} = connect(MerchantSocket, %{"token" => token})

    %{socket: socket, merchant_id: merchant_id}
  end

  describe "joining merchant channel" do
    test "succeeds when joining own merchant topic", %{socket: socket, merchant_id: merchant_id} do
      assert {:ok, _reply, _socket} = subscribe_and_join(socket, "merchant:#{merchant_id}", %{})
    end

    test "refuses join when topic merchant_id does not match socket", %{socket: socket} do
      assert {:error, %{reason: "forbidden"}} = subscribe_and_join(socket, "merchant:999", %{})
    end
  end

  describe "real-time order updates" do
    test "pushes order_updated event to connected merchant when their order changes", %{
      socket: socket,
      merchant_id: merchant_id
    } do
      {:ok, _reply, _socket} = subscribe_and_join(socket, "merchant:#{merchant_id}", %{})

      {:ok, order} =
        Dispatch.create_order(%{
          pickup_latitude: -6.2000,
          pickup_longitude: 106.8100,
          dropoff_latitude: -6.2100,
          dropoff_longitude: 106.8200,
          weight_kg: 10,
          merchant_id: merchant_id
        })

      assert_push "order_updated", payload
      assert payload.id == order.id
      assert payload.merchant_id == merchant_id
      assert payload.status == :pending
    end

    test "ignores order updates belonging to other merchants" do
      merchant_id = 202
      token = MerchantToken.sign(merchant_id)
      {:ok, socket} = connect(MerchantSocket, %{"token" => token})
      {:ok, _reply, _socket} = subscribe_and_join(socket, "merchant:#{merchant_id}", %{})

      {:ok, _other_order} =
        Dispatch.create_order(%{
          pickup_latitude: -6.2000,
          pickup_longitude: 106.8100,
          dropoff_latitude: -6.2100,
          dropoff_longitude: 106.8200,
          weight_kg: 5,
          merchant_id: 888
        })

      refute_push "order_updated", _payload
    end
  end
end
