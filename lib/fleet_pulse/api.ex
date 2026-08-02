defmodule FleetPulse.Api do
  @moduledoc """
  The partner API context — API keys for external applications that read fleet
  tracking data. Keys are read-only credentials, distinct from admin sessions
  and driver tokens.
  """

  import Ecto.Query

  alias FleetPulse.Api.Key
  alias FleetPulse.Repo
  alias FleetPulse.Types

  @key_bytes 32
  @prefix "fp_"

  @doc """
  Creates an API key. Returns the record AND the plaintext key — shown once,
  never stored (only its hash is persisted). Treat the plaintext like a
  password: display it once to the operator.
  """
  @spec create_key(String.t()) :: {:ok, Key.t(), String.t()} | {:error, Key.changeset()}
  def create_key(label) do
    plaintext = generate_key()

    %Key{}
    |> Key.changeset(%{label: label, hashed_key: hash_key(plaintext)})
    |> Repo.insert()
    |> with_plaintext(plaintext)
  end

  @spec with_plaintext({:ok, Key.t()} | {:error, Key.changeset()}, String.t()) ::
          {:ok, Key.t(), String.t()} | {:error, Key.changeset()}
  defp with_plaintext({:ok, key}, plaintext), do: {:ok, key, plaintext}
  defp with_plaintext({:error, _changeset} = error, _plaintext), do: error

  @doc """
  Authenticates a presented key by hash lookup.

  No constant-time comparison is needed: the key carries 256 bits of entropy,
  so the space cannot be brute-forced or enumerated — a direct indexed lookup
  on the hash is both safe and O(1). (This is why a fast SHA-256, not bcrypt,
  is the right choice: bcrypt's per-record salt would force an O(n) scan.)
  """
  @spec authenticate(term()) :: {:ok, Key.t()} | {:error, :invalid}
  def authenticate(presented) when is_binary(presented) do
    case Repo.get_by(Key, hashed_key: hash_key(presented)) do
      %Key{revoked_at: nil} = key -> {:ok, key}
      _revoke_or_missing -> {:error, :invalid}
    end
  end

  def authenticate(_presented), do: {:error, :invalid}

  @spec revoke_key(Types.id()) :: {:ok, Key.t()} | {:error, :not_found | Key.changeset()}
  def revoke_key(id) do
    case Repo.get(Key, id) do
      nil ->
        {:error, :not_found}

      %Key{} = key ->
        key
        |> Key.changeset(%{revoked_at: DateTime.truncate(DateTime.utc_now(), :second)})
        |> Repo.update()
    end
  end

  @spec list_keys() :: [Key.t()]
  def list_keys do
    Repo.all(from k in Key, order_by: [desc: k.inserted_at])
  end

  @spec generate_key() :: String.t()
  defp generate_key do
    @prefix <> Base.url_encode64(:crypto.strong_rand_bytes(@key_bytes), padding: false)
  end

  @spec hash_key(String.t()) :: String.t()
  defp hash_key(key) do
    :sha256 |> :crypto.hash(key) |> Base.encode16(case: :lower)
  end
end
