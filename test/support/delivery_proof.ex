defmodule FleetPulse.DeliveryProof do
  @moduledoc """
  A photo uploaded to the proof-of-delivery bucket for a fleet job, and a signature drawn on the
  phone, as a delivering courier would send them.
  """

  alias FleetPulse.Dispatch.Proof
  alias FleetPulse.FakeStorage

  @png <<0x89, ?P, ?N, ?G, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, ?I, ?H, ?D, ?R>>

  @spec photo_bytes() :: <<_::2080>>
  def photo_bytes, do: <<0xFF, 0xD8, 0xFF, 0xE0>> <> :crypto.strong_rand_bytes(256)

  @spec photo_url_for(pos_integer(), binary()) :: String.t()
  def photo_url_for(order_id, bytes) do
    FakeStorage.object_url(Proof.photo_key(order_id, :crypto.hash(:sha256, bytes)))
  end

  @spec proof_for(pos_integer()) :: %{String.t() => String.t()}
  def proof_for(order_id) do
    bytes = photo_bytes()
    url = photo_url_for(order_id, bytes)
    :ok = FakeStorage.uploaded(url, bytes)
    %{"pod_photo_url" => url}
  end

  @spec signature_png() :: <<_::640>>
  def signature_png, do: @png <> :crypto.strong_rand_bytes(64)

  @spec signature_uri(binary()) :: String.t()
  def signature_uri(png), do: "data:image/png;base64," <> Base.encode64(png)
end
