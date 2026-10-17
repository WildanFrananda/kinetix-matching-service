defmodule FleetPulse.Dispatch.Proof do
  @moduledoc """
  What a proof of delivery is made of: a photo stored under its own SHA-256 in this job's folder,
  and a signature drawn on the phone, sent as a PNG in a `data:` URI.
  """

  alias FleetPulse.Types

  @type digest :: <<_::256>>

  @photo_key ~r|\Apod/(\d+)/([0-9a-f]{64})\.jpg\z|
  @signature_prefix "data:image/png;base64,"
  @png_magic <<0x89, ?P, ?N, ?G, 0x0D, 0x0A, 0x1A, 0x0A>>

  @spec parse_sha256(term()) :: {:ok, digest()} | {:error, :invalid_photo_hash}
  def parse_sha256(hex) when is_binary(hex) and byte_size(hex) == 64 do
    case Base.decode16(hex, case: :lower) do
      {:ok, digest} -> {:ok, digest}
      :error -> {:error, :invalid_photo_hash}
    end
  end

  def parse_sha256(_hex), do: {:error, :invalid_photo_hash}

  @spec photo_key(Types.id(), digest()) :: String.t()
  def photo_key(order_id, digest) do
    "pod/#{order_id}/#{Base.encode16(digest, case: :lower)}.jpg"
  end

  @spec photo_named(String.t(), Types.id()) :: {:ok, digest()} | :error
  def photo_named(key, order_id) do
    job = Integer.to_string(order_id)

    case Regex.run(@photo_key, key) do
      [_key, ^job, hex] -> {:ok, Base.decode16!(hex, case: :lower)}
      _another_jobs_or_unnamed -> :error
    end
  end

  @spec signature_reference?(String.t()) :: boolean()
  def signature_reference?(value), do: String.starts_with?(value, @signature_prefix)

  @spec signature_sha256(map()) :: {:ok, digest() | nil} | {:error, :invalid_proof}
  def signature_sha256(%{"pod_signature" => @signature_prefix <> encoded}) do
    case Base.decode64(encoded) do
      {:ok, @png_magic <> _image = png} -> {:ok, :crypto.hash(:sha256, png)}
      _not_a_png -> {:error, :invalid_proof}
    end
  end

  def signature_sha256(%{"pod_signature" => nil}), do: {:ok, nil}
  def signature_sha256(%{"pod_signature" => _other}), do: {:error, :invalid_proof}
  def signature_sha256(_unsigned), do: {:ok, nil}
end
