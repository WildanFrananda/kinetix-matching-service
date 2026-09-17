defmodule FleetPulse.Geocoding.GeocodedAddress do
  @moduledoc """
  A remembered answer: this address is at this point, according to this provider.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: integer() | nil,
          query: String.t() | nil,
          latitude: float() | nil,
          longitude: float() | nil,
          provider: String.t() | nil,
          display_name: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @type changeset :: Ecto.Changeset.t(t())

  @fields [:query, :latitude, :longitude, :provider, :display_name]
  @required [:query, :latitude, :longitude, :provider]

  schema "geocoded_addresses" do
    field :query, :string
    field :latitude, :float
    field :longitude, :float
    field :provider, :string
    field :display_name, :string

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: changeset()
  def changeset(%__MODULE__{} = address, attrs) do
    address
    |> cast(attrs, @fields)
    |> validate_required(@required)
    |> validate_number(:latitude, greater_than_or_equal_to: -90.0, less_than_or_equal_to: 90.0)
    |> validate_number(:longitude, greater_than_or_equal_to: -180.0, less_than_or_equal_to: 180.0)
    |> unique_constraint(:query)
  end
end
