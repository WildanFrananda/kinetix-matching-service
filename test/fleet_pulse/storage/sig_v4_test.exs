defmodule FleetPulse.Storage.SigV4Test do
  use ExUnit.Case, async: true

  alias FleetPulse.Storage.SigV4

  test "signs the presigned GET AWS publishes as its worked example" do
    url =
      SigV4.presign(
        %{
          method: "GET",
          base_url: "https://examplebucket.s3.amazonaws.com",
          path: "/test.txt",
          expires_in: 86_400,
          at: ~U[2013-05-24 00:00:00Z]
        },
        %{
          access_key: "AKIAIOSFODNN7EXAMPLE",
          secret_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
          region: "us-east-1"
        }
      )

    assert url ==
             "https://examplebucket.s3.amazonaws.com/test.txt" <>
               "?X-Amz-Algorithm=AWS4-HMAC-SHA256" <>
               "&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request" <>
               "&X-Amz-Date=20130524T000000Z" <>
               "&X-Amz-Expires=86400" <>
               "&X-Amz-SignedHeaders=host" <>
               "&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"
  end

  test "signs for the port as well as the host when the port is not the scheme's own" do
    url =
      SigV4.presign(
        %{
          method: "PUT",
          base_url: "http://127.0.0.1:9000",
          path: "/kinetix-pod/pod/7/photo.jpg",
          expires_in: 600,
          at: ~U[2026-10-13 00:00:00Z]
        },
        %{access_key: "key", secret_key: "secret", region: "us-east-1"}
      )

    assert String.starts_with?(url, "http://127.0.0.1:9000/kinetix-pod/pod/7/photo.jpg?")
  end
end
