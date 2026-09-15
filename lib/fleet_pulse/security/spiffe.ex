defmodule FleetPulse.Security.Spiffe do
  @moduledoc """
  Reads the SPIFFE identity out of a peer certificate.

  A SPIFFE id lives in a URI subject-alternative name — `spiffe://kinetix.local/service/order` —
  and not in the common name. The CN is a display string anything can be issued with; the URI SAN
  is the field the CA is asserting.
  """

  require Record

  Record.defrecord(
    :otp_certificate,
    :OTPCertificate,
    Record.extract(:OTPCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecord(
    :otp_tbs_certificate,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecord(
    :extension,
    :Extension,
    Record.extract(:Extension, from_lib: "public_key/include/public_key.hrl")
  )

  @trust_domain "spiffe://kinetix.local/service/"

  @doc """
  The service name a DER-encoded peer certificate asserts, or `:error` when it asserts none.

  `:error` rather than a default: a certificate from our own CA carrying no SPIFFE id is one this
  mesh cannot place, and treating it as anonymous is the only honest reading.
  """
  @spec service_of(binary()) :: {:ok, String.t()} | :error
  def service_of(der) when is_binary(der) do
    der
    |> :public_key.pkix_decode_cert(:otp)
    |> uri_sans()
    |> Enum.find_value(:error, &parse/1)
  rescue
    _malformed -> :error
  end

  def service_of(_other), do: :error

  @spec uri_sans(tuple()) :: [String.t()]
  defp uri_sans(certificate) do
    certificate
    |> otp_certificate(:tbsCertificate)
    |> otp_tbs_certificate(:extensions)
    |> List.wrap()
    |> Enum.filter(&match?({:Extension, {2, 5, 29, 17}, _critical, _value}, &1))
    |> Enum.flat_map(fn ext -> List.wrap(extension(ext, :extnValue)) end)
    |> Enum.flat_map(fn
      {:uniformResourceIdentifier, uri} -> [to_string(uri)]
      _other_san_type -> []
    end)
  end

  @spec parse(String.t()) :: {:ok, String.t()} | nil
  defp parse(uri) do
    with %URI{scheme: "spiffe", host: "kinetix.local", path: path} when is_binary(path) <-
           URI.parse(uri),
         normalised = "spiffe://kinetix.local" <> Path.expand(path, "/"),
         true <- String.starts_with?(normalised, @trust_domain),
         service = String.replace_prefix(normalised, @trust_domain, ""),
         true <- service != "" and not String.contains?(service, "/") do
      {:ok, service}
    else
      _not_a_service_id -> nil
    end
  end
end
