defmodule KinetixMatching.Tracking.RedisPositionPublisherTest do
  use ExUnit.Case, async: true

  alias KinetixMatching.Tracking.RedisPositionPublisher

  test "encodes RESP2 commands cleanly" do
    encoded = RedisPositionPublisher.encode_command(["PUBLISH", "matching:position:ORD-1", "{}"])
    assert encoded == "*3\r\n$7\r\nPUBLISH\r\n$23\r\nmatching:position:ORD-1\r\n$2\r\n{}\r\n"
  end

  test "returns :ok as no-op when redis host is unconfigured" do
    {:ok, pid} = GenServer.start_link(RedisPositionPublisher, [])

    assert :ok =
             RedisPositionPublisher.publish_sync(pid, "ORD-1", %{
               event: "courier.location.updated"
             })

    GenServer.stop(pid)
  end

  test "authenticates with AUTH and publishes JSON envelope over RESP2" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    parent = self()

    server =
      Task.async(fn ->
        {:ok, conn} = :gen_tcp.accept(listen, 2_000)
        {:ok, auth_req} = :gen_tcp.recv(conn, 0, 2_000)
        send(parent, {:received_auth, auth_req})
        :ok = :gen_tcp.send(conn, "+OK\r\n")

        {:ok, pub_req} = :gen_tcp.recv(conn, 0, 2_000)
        send(parent, {:received_publish, pub_req})
        :ok = :gen_tcp.send(conn, ":1\r\n")

        :ok = :gen_tcp.close(conn)
        :ok = :gen_tcp.close(listen)
      end)

    {:ok, pid} =
      GenServer.start_link(RedisPositionPublisher,
        host: "127.0.0.1",
        port: port,
        username: "matching",
        password: "secret"
      )

    envelope = %{
      event: "courier.location.updated",
      orderId: "ORD-77",
      sequence: nil,
      data: %{latitude: -6.2, longitude: 106.8}
    }

    assert :ok = RedisPositionPublisher.publish_sync(pid, "ORD-77", envelope)
    assert_receive {:received_auth, auth_wire}, 1_000
    assert String.contains?(auth_wire, "AUTH")
    assert String.contains?(auth_wire, "matching")
    assert String.contains?(auth_wire, "secret")

    assert_receive {:received_publish, pub_wire}, 1_000
    assert String.contains?(pub_wire, "matching:position:ORD-77")
    assert String.contains?(pub_wire, "courier.location.updated")

    Task.await(server, 2_000)
    GenServer.stop(pid)
  end
end
