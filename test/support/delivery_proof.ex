defmodule FleetPulse.DeliveryProof do
  @moduledoc """
  A photo uploaded to the proof-of-delivery bucket for a fleet job, as a delivering courier would send it.
  """

  alias FleetPulse.FakeStorage

  @spec proof_for(pos_integer()) :: %{String.t() => String.t()}
  def proof_for(order_id) do
    url = FakeStorage.object_url("pod/#{order_id}/#{Ecto.UUID.generate()}.jpg")
    :ok = FakeStorage.uploaded(url)
    %{"pod_photo_url" => url}
  end
end
