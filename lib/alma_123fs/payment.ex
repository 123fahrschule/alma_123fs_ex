defmodule Alma123FS.Payment do
  @moduledoc """
  An Alma payment (`reference/payment.md`).

  Status fields are mapped explicitly; a value this library does not know becomes
  `:unknown` instead of failing the parse. The complete response map is kept in `raw`.

  `processing_status`:

  | Alma | atom |
  |---|---|
  | `awaiting_authorization` | `:awaiting_authorization` |
  | `authorized` | `:authorized` |
  | `captured` | `:captured` |
  | `canceled` | `:canceled` |

  `cancelation_reason`: `requested_by_merchant`, `requested_by_customer`,
  `authorization_expired`, `expired` (documented) and `declined` (present only in the
  PHP client) map to the atom of the same name.

  `capture_method`: `automatic` / `manual`.

  Amounts (`purchase_amount`, `customer_fee`, `customer_interest`) are integer cents.
  `expired_at` is a `DateTime` (Alma sends POSIX seconds).

  `GET /v1/payments` returns a subset of fields; absent fields are `nil` (lists are `[]`).
  Only `id` is required for a successful parse. A present field the library reads
  (ids, statuses, amounts, timestamps, plan and orders) with a wrong JSON type is a
  protocol error; `custom_data`, `fees` and `orders[].data` are kept as received.
  """
  alias Alma123FS.{Decode, Installment, Order}

  @processing_statuses %{
    "awaiting_authorization" => :awaiting_authorization,
    "authorized" => :authorized,
    "captured" => :captured,
    "canceled" => :canceled
  }

  @cancelation_reasons %{
    "requested_by_merchant" => :requested_by_merchant,
    "requested_by_customer" => :requested_by_customer,
    "authorization_expired" => :authorization_expired,
    "expired" => :expired,
    "declined" => :declined
  }

  @capture_methods %{"automatic" => :automatic, "manual" => :manual}

  defstruct [
    :id,
    :url,
    :processing_status,
    :cancelation_reason,
    :expired_at,
    :purchase_amount,
    :installments_count,
    :capture_method,
    :custom_data,
    :merchant_id,
    :customer_fee,
    :customer_interest,
    :fees,
    payment_plan: [],
    orders: [],
    raw: %{}
  ]

  @type processing_status ::
          :awaiting_authorization | :authorized | :captured | :canceled | :unknown
  @type cancelation_reason ::
          :requested_by_merchant
          | :requested_by_customer
          | :authorization_expired
          | :expired
          | :declined
          | :unknown
  @type capture_method :: :automatic | :manual | :unknown
  @type t :: %__MODULE__{
          id: String.t(),
          url: String.t() | nil,
          processing_status: processing_status() | nil,
          cancelation_reason: cancelation_reason() | nil,
          expired_at: DateTime.t() | nil,
          purchase_amount: integer() | nil,
          installments_count: integer() | nil,
          capture_method: capture_method() | nil,
          payment_plan: [Installment.t()],
          custom_data: term(),
          orders: [Order.t()],
          merchant_id: String.t() | nil,
          customer_fee: integer() | nil,
          customer_interest: integer() | nil,
          fees: term(),
          raw: map()
        }

  @doc "Parse a decoded JSON payment object."
  @spec from_map(term()) :: {:ok, t()} | :error
  def from_map(map) when is_map(map), do: Decode.run(fn -> decode!(map) end)
  def from_map(_), do: :error

  @doc false
  @spec decode!(map()) :: t()
  def decode!(map) do
    %__MODULE__{
      id: Decode.required_string(map, "id"),
      url: Decode.string(map, "url"),
      processing_status: Decode.enum(map, "processing_status", @processing_statuses),
      cancelation_reason: Decode.enum(map, "cancelation_reason", @cancelation_reasons),
      expired_at: Decode.timestamp(map, "expired_at"),
      purchase_amount: Decode.integer(map, "purchase_amount"),
      installments_count: Decode.integer(map, "installments_count"),
      capture_method: Decode.enum(map, "capture_method", @capture_methods),
      payment_plan: Decode.list(map, "payment_plan", &Installment.decode!/1),
      custom_data: Map.get(map, "custom_data"),
      orders: Decode.list(map, "orders", &Order.decode!/1),
      merchant_id: Decode.string(map, "merchant_id"),
      customer_fee: Decode.integer(map, "customer_fee"),
      customer_interest: Decode.integer(map, "customer_interest"),
      fees: Map.get(map, "fees"),
      raw: map
    }
  end
end
