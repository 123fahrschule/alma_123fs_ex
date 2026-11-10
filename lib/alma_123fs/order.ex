defmodule Alma123FS.Order do
  @moduledoc """
  An order attached to a payment (`reference/order.md`).

  `merchant_reference` links the Alma payment to the merchant's order.
  `payment` is absent when the order is embedded in a payment.
  """
  alias Alma123FS.Decode

  defstruct [
    :id,
    :created_at,
    :merchant_reference,
    :merchant_url,
    :customer_url,
    :payment,
    :data,
    :comment
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          created_at: DateTime.t() | nil,
          merchant_reference: String.t() | nil,
          merchant_url: String.t() | nil,
          customer_url: String.t() | nil,
          payment: String.t() | nil,
          data: term(),
          comment: String.t() | nil
        }

  @doc false
  @spec decode!(map()) :: t()
  def decode!(map) do
    %__MODULE__{
      id: Decode.string(map, "id"),
      created_at: Decode.timestamp(map, "created"),
      merchant_reference: Decode.string(map, "merchant_reference"),
      merchant_url: Decode.string(map, "merchant_url"),
      customer_url: Decode.string(map, "customer_url"),
      payment: Decode.string(map, "payment"),
      data: Map.get(map, "data"),
      comment: Decode.string(map, "comment")
    }
  end
end
