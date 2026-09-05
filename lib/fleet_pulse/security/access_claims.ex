defmodule FleetPulse.Security.AccessClaims do
  @moduledoc """
  The claims an identity access token carries, after verification.

  A struct rather than the decoder's raw map, so nothing downstream reads a claim that was never
  asserted. `principal_id` is a UUID and `user_id` is the account id; the two collided across
  services before principals existed, so they are kept apart by name and by type.
  """

  @enforce_keys [:principal_id, :user_id, :email, :role]
  defstruct [:principal_id, :user_id, :email, :role]

  @type t :: %__MODULE__{
          principal_id: String.t(),
          user_id: pos_integer(),
          email: String.t(),
          role: String.t()
        }

  @doc """
  Narrows a verified payload claim by claim.

  A token missing any of these is not a token this service can act on: defaulting one would
  attribute a driver's location, or a merchant's order, to whoever the default named.
  """
  @spec from_payload(map()) :: {:ok, t()} | {:error, :malformed_claims}
  def from_payload(payload) when is_map(payload) do
    with {:ok, principal_id} <- text(payload, "sub"),
         {:ok, user_id} <- number(payload, "uid"),
         {:ok, email} <- text(payload, "email"),
         {:ok, role} <- text(payload, "role") do
      {:ok,
       %__MODULE__{principal_id: principal_id, user_id: user_id, email: email, role: role}}
    end
  end

  def from_payload(_payload), do: {:error, :malformed_claims}

  @spec text(map(), String.t()) :: {:ok, String.t()} | {:error, :malformed_claims}
  defp text(payload, name) do
    case Map.get(payload, name) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, :malformed_claims}
    end
  end

  @spec number(map(), String.t()) :: {:ok, pos_integer()} | {:error, :malformed_claims}
  defp number(payload, name) do
    case Map.get(payload, name) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _missing -> {:error, :malformed_claims}
    end
  end
end
