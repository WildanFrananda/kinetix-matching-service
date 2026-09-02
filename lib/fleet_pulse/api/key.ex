defmodule FleetPulse.Api.Key do
  @moduledoc """
  An API key issued to an external application that reads fleet tracking data.

  Only the SHA-256 hash of the key is stored — the plaintext is shown once at
  creation and never persisted.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias FleetPulse.Types

  @type t :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: Types.id() | nil,
          label: String.t() | nil,
          hashed_key: String.t() | nil,
          revoked_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @type changeset :: Ecto.Changeset.t(t())

  schema "api_keys" do
    field :label, :string
    field :hashed_key, :string, redact: true
    field :revoked_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @spec changeset(t(), map()) :: changeset()
  def changeset(key, attrs) do
    key
    |> cast(attrs, [:label, :hashed_key, :revoked_at])
    |> validate_required([:label, :hashed_key])
    |> unique_constraint(:hashed_key)
  end
end
