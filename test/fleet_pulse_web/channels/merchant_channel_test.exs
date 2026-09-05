defmodule FleetPulseWeb.MerchantChannelTest do
  use FleetPulseWeb.ChannelCase, async: true

  alias FleetPulse.Dispatch
  alias FleetPulse.IdentityJwks
  alias FleetPulseWeb.MerchantSocket

  defp merchant_socket(merchant_id) do
    {:ok, socket} =
      connect(MerchantSocket, %{
        "token" => IdentityJwks.token(role: "seller", uid: merchant_id)
      })

    socket
  end

  setup do
    merchant_id = 101
    %{socket: merchant_socket(merchant_id), merchant_id: merchant_id}
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

      assert_push "order_updated", payload, 500
      assert payload.id == order.id
      assert payload.merchant_id == merchant_id
      assert payload.status == :pending
    end

    test "ignores order updates belonging to other merchants" do
      merchant_id = 202
      socket = merchant_socket(merchant_id)
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

      refute_push "order_updated", _payload, 200
    end
  end

  describe "connect/3" do
    test "refuses a customer, whose token is valid and carries no merchant authority" do
      assert {:error, :not_a_merchant} =
               connect(MerchantSocket, %{"token" => IdentityJwks.token(role: "customer")})
    end

    test "refuses a token this service did not get from identity" do
      assert {:error, :invalid_token} = connect(MerchantSocket, %{"token" => "nope"})
    end

    test "refuses a connection carrying no token" do
      assert {:error, :missing_token} = connect(MerchantSocket, %{})
    end
  end
end
