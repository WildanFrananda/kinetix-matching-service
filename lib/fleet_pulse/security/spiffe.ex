defmodule FleetPulse.Security.Spiffe do
  @moduledoc """
  Reads the SPIFFE identity out of a peer certificate.
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

  @default_trust_domain "kinetix.local"

  @spec trust_domains() :: [String.t()]
  def trust_domains do
    configured =
      System.get_env("KINETIX_TRUST_DOMAIN", "")
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case configured do
      [] -> [@default_trust_domain]
      domains -> domains
    end
  end

  @spec trust_domain() :: String.t()
  def trust_domain, do: hd(trust_domains())

  @spec prefix_for(String.t()) :: String.t()
  def prefix_for(domain), do: "spiffe://" <> domain <> "/service/"

  @spec service_of(binary()) :: {:ok, String.t()} | :error
  def service_of(der) when is_binary(der) do
    der
    |> :public_key.pkix_decode_cert(:otp)
    |> uri_sans()
    |> Enum.find_value(:error, fn uri ->
      Enum.find_value(trust_domains(), fn domain -> service_in(uri, domain) end)
    end)
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

  @spec service_in(String.t(), String.t()) :: {:ok, String.t()} | nil
  def service_in(uri, domain) do
    prefix = prefix_for(domain)

    with %URI{scheme: "spiffe", host: ^domain, path: path} when is_binary(path) <- URI.parse(uri),
         normalised = "spiffe://" <> domain <> Path.expand(path, "/"),
         true <- String.starts_with?(normalised, prefix),
         service = String.replace_prefix(normalised, prefix, ""),
         true <- service != "" and not String.contains?(service, "/") do
      {:ok, service}
    else
      _not_a_service_id -> nil
    end
  end
end
