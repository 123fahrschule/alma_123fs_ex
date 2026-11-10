defmodule Alma123FS.Installment do
  @moduledoc """
  One installment of a payment plan, from a payment or an eligibility result.

  Amounts are integer cents. `total_amount` is present in eligibility results
  (principal + fee + interest); payments report `original_purchase_amount`,
  `state` and `date_paid` instead. Fields absent from the response are `nil`.

  `state` maps `pending`, `paid` and `covered` to atoms; any other value is `:unknown`.
  """
  alias Alma123FS.Decode

  @states %{"pending" => :pending, "paid" => :paid, "covered" => :covered}

  defstruct [
    :id,
    :due_date,
    :date_paid,
    :purchase_amount,
    :original_purchase_amount,
    :customer_fee,
    :customer_interest,
    :total_amount,
    :state
  ]

  @type state :: :pending | :paid | :covered | :unknown
  @type t :: %__MODULE__{
          id: String.t() | nil,
          due_date: DateTime.t() | nil,
          date_paid: DateTime.t() | nil,
          purchase_amount: integer() | nil,
          original_purchase_amount: integer() | nil,
          customer_fee: integer() | nil,
          customer_interest: integer() | nil,
          total_amount: integer() | nil,
          state: state() | nil
        }

  @doc false
  @spec decode!(map()) :: t()
  def decode!(map) do
    %__MODULE__{
      id: Decode.string(map, "id"),
      due_date: Decode.timestamp(map, "due_date"),
      date_paid: Decode.timestamp(map, "date_paid"),
      purchase_amount: Decode.integer(map, "purchase_amount"),
      original_purchase_amount: Decode.integer(map, "original_purchase_amount"),
      customer_fee: Decode.integer(map, "customer_fee"),
      customer_interest: Decode.integer(map, "customer_interest"),
      total_amount: Decode.integer(map, "total_amount"),
      state: Decode.enum(map, "state", @states)
    }
  end
end
