defmodule FleetPulse.Storage.S3Test do
  use ExUnit.Case, async: false

  alias FleetPulse.Storage.S3
  alias FleetPulse.Storage.SigV4

  @moduletag :object_store

  @bucket "kinetix-pod-test"

  setup_all do
    endpoint = System.fetch_env!("OBJECT_STORE_TEST_ENDPOINT")

    config = [
      endpoint: endpoint,
      public_url: endpoint,
      bucket: @bucket,
      region: "us-east-1",
      access_key: System.fetch_env!("OBJECT_STORE_TEST_ACCESS_KEY"),
      secret_key: System.fetch_env!("OBJECT_STORE_TEST_SECRET_KEY")
    ]

    previous = Application.get_env(:fleet_pulse, S3)
    Application.put_env(:fleet_pulse, S3, config)
    on_exit(fn -> restore(previous) end)

    {:ok, %Req.Response{status: status}} =
      Req.put(signed("PUT", "/#{@bucket}", config), retry: false)

    assert status in [200, 409]

    %{config: config}
  end

  defp restore(nil), do: Application.delete_env(:fleet_pulse, S3)
  defp restore(previous), do: Application.put_env(:fleet_pulse, S3, previous)

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

  defp photo, do: <<0xFF, 0xD8, 0xFF, 0xE0>> <> :crypto.strong_rand_bytes(2_048)

  defp key_for(bytes) do
    "pod/7/#{Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}.jpg"
  end

  defp key, do: key_for(photo())

  defp put(upload, body, headers) do
    Req.put(
      upload.url,
      body: body,
      headers: Map.put(headers, "content-type", "image/jpeg"),
      retry: false
    )
  end

  test "a photo put through the upload address is there, under its checksum, and reads back" do
    photo = photo()
    key = key_for(photo)
    digest = :crypto.hash(:sha256, photo)
    upload = S3.upload(key, digest)

    assert {:ok, %Req.Response{status: 200}} = put(upload, photo, upload.headers)
    assert {:ok, {:sha256, ^digest}} = S3.checksum(key)

    assert {:ok, %Req.Response{status: 200, body: ^photo}} =
             Req.get(S3.read_url(key), retry: false, decode_body: false)
  end

  test "an upload address takes only the bytes whose SHA-256 it was signed for" do
    photo = photo()
    key = key_for(photo)
    upload = S3.upload(key, :crypto.hash(:sha256, photo))

    assert {:ok, %Req.Response{status: 400, body: body}} = put(upload, photo(), upload.headers)
    assert body =~ "BadDigest"
    assert {:ok, :absent} = S3.checksum(key)
  end

  test "an upload address writes once: a second put is refused and the first photo stays" do
    photo = photo()
    key = key_for(photo)
    digest = :crypto.hash(:sha256, photo)
    upload = S3.upload(key, digest)

    assert {:ok, %Req.Response{status: 200}} = put(upload, photo, upload.headers)
    assert {:ok, %Req.Response{status: 412}} = put(upload, photo, upload.headers)
    assert {:ok, {:sha256, ^digest}} = S3.checksum(key)
  end

  test "an upload address is refused without either header it was signed with" do
    photo = photo()
    key = key_for(photo)
    upload = S3.upload(key, :crypto.hash(:sha256, photo))

    for dropped <- Map.keys(upload.headers) do
      assert {:ok, %Req.Response{status: status, body: body}} =
               put(upload, photo, Map.delete(upload.headers, dropped))

      assert status in [400, 403]
      assert body =~ ~r{<Code>(AccessDenied|SignatureDoesNotMatch)</Code>}
    end

    assert {:ok, :absent} = S3.checksum(key)
  end

  test "an object stored without a checksum has none to show", %{config: config} do
    key = key()

    assert {:ok, %Req.Response{status: 200}} =
             Req.put(signed("PUT", "/#{@bucket}/#{key}", config), body: photo(), retry: false)

    assert {:ok, :no_checksum} = S3.checksum(key)
  end

  test "a photo nobody uploaded is absent, not unknown" do
    assert {:ok, :absent} = S3.checksum(key())
    assert {:ok, :absent} = S3.leading_bytes(key(), 3)
  end

  test "reads back only the first bytes of a stored photo, which show what kind of file it is" do
    photo = photo()
    key = key_for(photo)
    upload = S3.upload(key, :crypto.hash(:sha256, photo))

    assert {:ok, %Req.Response{status: 200}} = put(upload, photo, upload.headers)
    assert {:ok, <<0xFF, 0xD8, 0xFF>>} = S3.leading_bytes(key, 3)
  end

  test "an upload address with a forged signature is refused" do
    photo = photo()
    upload = S3.upload(key_for(photo), :crypto.hash(:sha256, photo))

    forged = %{
      upload
      | url:
          Regex.replace(
            ~r/X-Amz-Signature=[0-9a-f]+/,
            upload.url,
            "X-Amz-Signature=#{String.duplicate("0", 64)}"
          )
    }

    assert {:ok, %Req.Response{status: 403}} = put(forged, photo, upload.headers)
  end

  test "an upload address is refused under any host but the one it was signed for", %{
    config: config
  } do
    photo = photo()
    upload = S3.upload(key_for(photo), :crypto.hash(:sha256, photo))
    %URI{port: port} = URI.parse(config[:endpoint])

    assert {:ok, %Req.Response{status: 403}} =
             put(upload, photo, Map.put(upload.headers, "host", "kinetix-object-store:#{port}"))
  end

  test "a bucket that cannot be reached is unknown, not absent", %{config: config} do
    Application.put_env(:fleet_pulse, S3, Keyword.put(config, :endpoint, "http://127.0.0.1:1"))
    on_exit(fn -> Application.put_env(:fleet_pulse, S3, config) end)

    assert {:error, :unavailable} = S3.checksum(key())
    assert {:error, :unavailable} = S3.leading_bytes(key(), 3)
  end
end
