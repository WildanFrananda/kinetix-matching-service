defmodule FleetPulse.Dispatch.Order do
  @moduledoc """
  Ecto schema for a delivery order — a Pure Data Object (PODO).
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias FleetPulse.Tracking.Driver
  alias FleetPulse.Types

  @type status :: :pending | :assigned | :picked_up | :delivered | :cancelled

  @type t :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: Types.id() | nil,
          pickup_latitude: Types.latitude() | nil,
          pickup_longitude: Types.longitude() | nil,
          dropoff_latitude: Types.latitude() | nil,
          dropoff_longitude: Types.longitude() | nil,
          weight_kg: non_neg_integer() | nil,
          status: status() | nil,
          driver_id: Types.id() | nil,
          order_number: String.t() | nil,
          merchant_principal_id: integer() | nil,
          pod_photo_url: String.t() | nil,
          pod_signature: String.t() | nil,
          driver: Driver.t() | Ecto.Association.NotLoaded.t() | nil,
          assigned_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @type changeset :: Ecto.Changeset.t(t())

  @statuses [:pending, :assigned, :picked_up, :delivered, :cancelled]

  @required_fields [
    :pickup_latitude,
    :pickup_longitude,
    :dropoff_latitude,
    :dropoff_longitude
  ]

  schema "orders" do
    field :pickup_latitude, :float
    field :pickup_longitude, :float
    field :dropoff_latitude, :float
    field :dropoff_longitude, :float
    field :weight_kg, :integer, default: 0
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :assigned_at, :utc_datetime_usec
    field :order_number, :string
    field :merchant_principal_id, :string
    field :pod_photo_url, :string
    field :pod_signature, :string

    belongs_to :driver, Driver

    timestamps(type: :utc_datetime_usec)
  end

  @spec statuses() :: [status(), ...]
  def statuses, do: @statuses

  @spec changeset(t(), map()) :: changeset()
  def changeset(%__MODULE__{} = order, attrs) do
    order
    |> cast(attrs, @required_fields ++ [:weight_kg, :merchant_principal_id, :order_number])
    |> validate_required(@required_fields)
    |> validate_coordinate(:pickup_latitude, -90, 90)
    |> validate_coordinate(:pickup_longitude, -180, 180)
    |> validate_coordinate(:dropoff_latitude, -90, 90)
    |> validate_coordinate(:dropoff_longitude, -180, 180)
    |> validate_number(:weight_kg, greater_than_or_equal_to: 0, less_than_or_equal_to: 5_000)
    |> check_constraint(:pickup_latitude, name: :orders_pickup_latitude_range)
    |> check_constraint(:dropoff_latitude, name: :orders_dropoff_latitude_range)
    |> unique_constraint(:order_number)
  end

  @max_pod_photo_url 2_048
  @max_pod_signature 65_536

  @spec pod_changeset(t(), map()) :: changeset()
  def pod_changeset(%__MODULE__{} = order, attrs) do
    order
    |> cast(attrs, [:pod_photo_url, :pod_signature])
    |> validate_length(:pod_photo_url, max: @max_pod_photo_url)
    |> validate_length(:pod_signature, max: @max_pod_signature)
    |> validate_change(:pod_photo_url, &validate_photo_reference/2)
    |> validate_change(:pod_signature, &validate_signature_reference/2)
  end

  @spec validate_photo_reference(atom(), String.t()) :: [{atom(), String.t()}]
  defp validate_photo_reference(field, value) do
    case URI.new(value) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        []

      _not_a_fetchable_url ->
        [{field, "must be an http or https URL naming where the photo is stored"}]
    end
  end

  @spec validate_signature_reference(atom(), String.t()) :: [{atom(), String.t()}]
  defp validate_signature_reference(field, value) do
    case URI.new(value) do
      {:ok, %URI{scheme: "data"}} ->
        []

      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        []

      _neither ->
        [
          {field,
           "must be a data: URI carrying the signature, or a URL naming where it is stored"}
        ]
    end
  end

  @spec validate_coordinate(changeset(), atom(), number(), number()) :: changeset()
  defp validate_coordinate(changeset, field, min, max) do
    validate_number(changeset, field,
      greater_than_or_equal_to: min,
      less_than_or_equal_to: max
    )
  end
end
