defmodule FleetPulse.Dispatch.DeliveryEvidence do
  @moduledoc """
  What matching saw when a job was delivered — the photo's and the signature's SHA-256, the courier
  and the time — written in the transaction that marks the job delivered, and never changed after.
  The notary reads it through `fulfillment.v1.DeliveryEvidenceService/DeliveriesSince`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias FleetPulse.Dispatch.Order
  alias FleetPulse.Dispatch.Proof
  alias FleetPulse.Types

  @type t :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          sequence: Types.id() | nil,
          order_id: Types.id() | nil,
          order: Order.t() | Ecto.Association.NotLoaded.t() | nil,
          order_number: String.t() | nil,
          driver_principal_id: String.t() | nil,
          photo_sha256: Proof.digest() | nil,
          signature_sha256: Proof.digest() | nil,
          delivered_at: DateTime.t() | nil
        }

  @type changeset :: Ecto.Changeset.t(t())

  @primary_key {:sequence, :id, autogenerate: true}

  schema "delivery_evidence" do
    belongs_to :order, Order
    field :order_number, :string
    field :driver_principal_id, :string
    field :photo_sha256, :binary
    field :signature_sha256, :binary
    field :delivered_at, :utc_datetime_usec
  end

  @spec changeset(Order.t(), String.t(), Proof.digest(), Proof.digest() | nil, DateTime.t()) ::
          changeset()
  def changeset(
        %Order{} = order,
        driver_principal_id,
        photo_sha256,
        signature_sha256,
        delivered_at
      ) do
    %__MODULE__{}
    |> change(
      order_id: order.id,
      order_number: order.order_number,
      driver_principal_id: driver_principal_id,
      photo_sha256: photo_sha256,
      signature_sha256: signature_sha256,
      delivered_at: delivered_at
    )
    |> unique_constraint(:order_id)
    |> foreign_key_constraint(:order_id)
    |> check_constraint(:photo_sha256, name: :delivery_evidence_photo_sha256_length)
    |> check_constraint(:signature_sha256, name: :delivery_evidence_signature_sha256_length)
    |> check_constraint(:driver_principal_id, name: :delivery_evidence_driver_principal_present)
  end
end
