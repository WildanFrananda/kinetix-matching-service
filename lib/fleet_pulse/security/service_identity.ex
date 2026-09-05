defmodule FleetPulse.Security.ServiceIdentity do
  @moduledoc """
  This service's own mesh credentials: the leaf it presents, the key that proves it, and the CA
  that decides which peers are ours.

  The files are bind-mounted read-only at `/pki` — this service's leaf only, never a shared
  volume, so a compromised container cannot read another service's key.
  """

  @type t :: %__MODULE__{cert: Path.t(), key: Path.t(), ca: Path.t()}

  defstruct [:cert, :key, :ca]

  @doc """
  Reads the PKI directory and fails loudly if it is incomplete.

  Checked at boot rather than at the first handshake: a missing key would otherwise surface as a
  TLS alert on a live call, which reads as a network fault rather than a deployment one.
  """
  @spec load!(Path.t() | nil) :: t()
  def load!(dir \\ nil) do
    dir = dir || System.get_env("KINETIX_PKI_DIR") || "/pki"
    identity = %__MODULE__{
      cert: Path.join(dir, "tls.crt"),
      key: Path.join(dir, "tls.key"),
      ca: Path.join(dir, "ca.pem")
    }

    for path <- [identity.cert, identity.key, identity.ca], not File.exists?(path) do
      raise """
      #{path} is missing. This service's PKI is mounted at #{dir}; issue it with
      kinetix-infrastructure/bin/kinetix-pki issue.
      """
    end

    identity
  end

  @doc """
  `:ssl` options for the gRPC server.

  `verify_peer` with `fail_if_no_peer_cert` is the whole point: without the second option a
  client that presents no certificate completes the handshake, and every guarantee then rests on
  the interceptor instead of on the transport refusing first.
  """
  @spec server_options(t()) :: keyword()
  def server_options(%__MODULE__{} = identity) do
    [
      certfile: identity.cert,
      keyfile: identity.key,
      cacertfile: identity.ca,
      verify: :verify_peer,
      fail_if_no_peer_cert: true,
      versions: [:"tlsv1.3", :"tlsv1.2"]
    ]
  end

  @doc """
  `:ssl` options for dialling another service in the mesh.
  """
  @spec client_options(t()) :: keyword()
  def client_options(%__MODULE__{} = identity) do
    [
      certfile: identity.cert,
      keyfile: identity.key,
      cacertfile: identity.ca,
      verify: :verify_peer,
      depth: 3,
      versions: [:"tlsv1.3", :"tlsv1.2"]
    ]
  end
end
