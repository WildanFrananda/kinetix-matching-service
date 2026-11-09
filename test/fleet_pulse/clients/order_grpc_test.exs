defmodule FleetPulse.Clients.OrderGrpcTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FleetPulse.Clients.OrderGrpc
  alias FleetPulse.OrderServiceDouble
  alias FleetPulse.OrderServiceDoubleEndpoint
  alias FleetPulse.Proto.Order.V1.OrderDeliveredRequest

  @delivered_at ~U[2026-11-08 17:48:38Z]
  @order_name "kinetix-order-double"

  setup do
    dir = Path.join(System.tmp_dir!(), "order-grpc-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    previous_dir = System.get_env("KINETIX_PKI_DIR")
    previous_config = Application.get_env(:fleet_pulse, OrderGrpc)

    System.put_env("KINETIX_PKI_DIR", dir)
    lookup = name_order_double()

    on_exit(fn ->
      forget_order_double(lookup)
      restore_dir(previous_dir)
      restore_config(previous_config)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  test "a delivery reaches order by its service name over mutual TLS and order's acceptance is the answer",
       %{dir: dir} do
    port = serve_order(dir, @order_name)
    dial("#{@order_name}:#{port}")
    OrderServiceDouble.listen()

    assert OrderGrpc.delivered("ORD-TEST-1", "courier-principal", @delivered_at) == :ok

    assert_receive {:order_delivered,
                    %OrderDeliveredRequest{
                      order_number: "ORD-TEST-1",
                      driver_principal_id: "courier-principal",
                      delivered_at: "2026-11-08T17:48:38Z"
                    }}
  end

  test "order presenting a certificate for another name is not told", %{dir: dir} do
    port = serve_order(dir, "kinetix-somebody-else")
    dial("#{@order_name}:#{port}")
    OrderServiceDouble.listen()

    log =
      capture_log(fn ->
        assert OrderGrpc.delivered("ORD-TEST-2", "courier-principal", @delivered_at) ==
                 {:error, :unavailable}
      end)

    assert log =~ "could not reach #{@order_name}:#{port} to report ORD-TEST-2"
    refute_received {:order_delivered, _request}
  end

  test "order that cannot be reached is unavailable within the connect timeout", %{dir: dir} do
    write_client_pki(dir, chain([@order_name]))
    dial("#{@order_name}:#{closed_port()}")

    {micros, result} =
      :timer.tc(fn ->
        with_log(fn -> OrderGrpc.delivered("ORD-TEST-3", "courier-principal", @delivered_at) end)
      end)

    assert {{:error, :unavailable}, _log} = result
    assert div(micros, 1_000) < 6_000
  end

  test "an order host that does not resolve is unavailable", %{dir: dir} do
    write_client_pki(dir, chain([@order_name]))
    dial("kinetix-nowhere.invalid:50055")

    log =
      capture_log(fn ->
        assert OrderGrpc.delivered("ORD-TEST-4", "courier-principal", @delivered_at) ==
                 {:error, :unavailable}
      end)

    assert log =~ "could not reach kinetix-nowhere.invalid:50055 to report ORD-TEST-4"
  end

  defp serve_order(dir, server_name) do
    pki = chain([server_name])
    write_client_pki(dir, pki)
    port = closed_port()

    start_supervised!(
      {GRPC.Server.Supervisor,
       endpoint: OrderServiceDoubleEndpoint,
       port: port,
       start_server: true,
       adapter_opts: [cred: GRPC.Credential.new(ssl: server_ssl(pki.server_config))]}
    )

    port
  end

  defp chain(server_names) do
    san =
      {:Extension, {2, 5, 29, 17}, false,
       Enum.map(server_names, &{:dNSName, String.to_charlist(&1)})}

    :public_key.pkix_test_data(%{
      server_chain: %{
        root: mesh_key(),
        intermediates: [],
        peer: [extensions: [san]] ++ mesh_key()
      },
      client_chain: %{root: mesh_key(), intermediates: [], peer: mesh_key()}
    })
  end

  defp mesh_key, do: [key: {:namedCurve, :secp256r1}, digest: :sha256]

  defp server_ssl(config) do
    [
      cert: Keyword.fetch!(config, :cert),
      key: Keyword.fetch!(config, :key),
      cacerts: Keyword.fetch!(config, :cacerts),
      verify: :verify_peer,
      fail_if_no_peer_cert: true,
      versions: [:"tlsv1.3", :"tlsv1.2"]
    ]
  end

  defp write_client_pki(dir, pki) do
    config = pki.client_config
    {key_type, key} = Keyword.fetch!(config, :key)

    File.write!(Path.join(dir, "tls.crt"), pem([{:Certificate, Keyword.fetch!(config, :cert)}]))
    File.write!(Path.join(dir, "tls.key"), pem([{key_type, key}]))

    File.write!(
      Path.join(dir, "ca.pem"),
      pem(Enum.map(Keyword.fetch!(config, :cacerts), &{:Certificate, &1}))
    )
  end

  defp pem(entries) do
    entries
    |> Enum.map(fn {type, der} -> {type, der, :not_encrypted} end)
    |> :public_key.pem_encode()
  end

  defp dial(host), do: Application.put_env(:fleet_pulse, OrderGrpc, host: host)

  defp name_order_double do
    lookup = :inet_db.res_option(:lookup)
    :ok = :inet_db.set_lookup([:file | List.delete(lookup, :file)])
    :ok = :inet_db.add_host({127, 0, 0, 1}, [String.to_charlist(@order_name)])

    lookup
  end

  defp forget_order_double(lookup) do
    :ok = :inet_db.del_host({127, 0, 0, 1})
    :ok = :inet_db.set_lookup(lookup)
  end

  defp closed_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)

    port
  end

  defp restore_dir(nil), do: System.delete_env("KINETIX_PKI_DIR")
  defp restore_dir(dir), do: System.put_env("KINETIX_PKI_DIR", dir)

  defp restore_config(nil), do: Application.delete_env(:fleet_pulse, OrderGrpc)
  defp restore_config(config), do: Application.put_env(:fleet_pulse, OrderGrpc, config)
end
