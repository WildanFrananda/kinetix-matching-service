defmodule FleetPulse.Storage.MinioTest do
  use ExUnit.Case, async: false

  alias FleetPulse.Storage.Minio
  alias FleetPulse.Storage.SigV4

  @moduletag :minio

  @bucket "kinetix-pod-test"

  setup_all do
    endpoint = System.fetch_env!("MINIO_TEST_ENDPOINT")

    config = [
      endpoint: endpoint,
      public_url: endpoint,
      bucket: @bucket,
      region: "us-east-1",
      access_key: System.fetch_env!("MINIO_TEST_ACCESS_KEY"),
      secret_key: System.fetch_env!("MINIO_TEST_SECRET_KEY")
    ]

    previous = Application.get_env(:fleet_pulse, Minio)
    Application.put_env(:fleet_pulse, Minio, config)
    on_exit(fn -> restore(previous) end)

    {:ok, %Req.Response{status: status}} =
      Req.put(signed("PUT", "/#{@bucket}", config), retry: false)

    assert status in [200, 409]

    %{config: config}
  end

  defp restore(nil), do: Application.delete_env(:fleet_pulse, Minio)
  defp restore(previous), do: Application.put_env(:fleet_pulse, Minio, previous)

  defp signed(method, path, config) do
    SigV4.presign(
      %{
        method: method,
        base_url: config[:endpoint],
        path: path,
        expires_in: 60,
        at: DateTime.utc_now()
      },
      %{
        access_key: config[:access_key],
        secret_key: config[:secret_key],
        region: config[:region]
      }
    )
  end

  defp key, do: "pod/7/#{Ecto.UUID.generate()}.jpg"

  test "a photo put through the upload address is there, and reads back" do
    key = key()
    photo = :crypto.strong_rand_bytes(2_048)

    assert {:ok, %Req.Response{status: 200}} =
             Req.put(
               Minio.upload_url(key),
               body: photo,
               headers: [{"content-type", "image/jpeg"}],
               retry: false
             )

    assert {:ok, true} = Minio.exists?(key)

    assert {:ok, %Req.Response{status: 200, body: ^photo}} =
             Req.get(Minio.read_url(key), retry: false, decode_body: false)
  end

  test "a photo nobody uploaded is absent, not unknown" do
    assert {:ok, false} = Minio.exists?(key())
  end

  test "an upload address with a forged signature is refused" do
    forged =
      Regex.replace(
        ~r/X-Amz-Signature=[0-9a-f]+/,
        Minio.upload_url(key()),
        "X-Amz-Signature=#{String.duplicate("0", 64)}"
      )

    assert {:ok, %Req.Response{status: 403}} = Req.put(forged, body: "x", retry: false)
  end

  test "an upload address is refused under any host but the one it was signed for", %{
    config: config
  } do
    url = Minio.upload_url(key())
    %URI{port: port} = URI.parse(config[:endpoint])

    assert {:ok, %Req.Response{status: 403}} =
             Req.put(url, body: "x", headers: [{"host", "kinetix-minio:#{port}"}], retry: false)
  end

  test "a bucket that cannot be reached is unknown, not absent", %{config: config} do
    Application.put_env(:fleet_pulse, Minio, Keyword.put(config, :endpoint, "http://127.0.0.1:1"))
    on_exit(fn -> Application.put_env(:fleet_pulse, Minio, config) end)

    assert {:error, :unavailable} = Minio.exists?(key())
  end
end
