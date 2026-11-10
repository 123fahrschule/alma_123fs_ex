defmodule Alma123FS.Eligibility do
  @moduledoc """
  Which Alma plans are offered for a purchase amount, with schedule, fees, interest and total.

  Uses `POST /v2/payments/eligibility` (`reference/verifier-eligibilite-achat.md`).
  The v1 endpoint (`reference/verifier-leligibilite-dun-achat.md`) is marked obsolete
  by Alma and is not supported. The PHP client (`EligibilityEndpoint`) also uses v2.

  Each result reflects the requested plan. When `eligible` is `true`:

    * `payment_plan` — installments with `due_date`, `purchase_amount`, `customer_fee`,
      `customer_interest` and `total_amount` (integer cents);
    * `customer_total_cost_amount` — total fees and interest paid by the customer;
    * `customer_total_cost_bps` — that cost in basis points. Alma advises not to show it
      for credit (more than 4 installments): it is indicative, not contractual;
    * `customer_fee`, `customer_interest`, `annual_interest_rate` — present in the PHP
      client's model, not in the documentation's example; `nil` when absent;
    * `total_amount` — computed by this library as the sum of the installments'
      `total_amount`, `nil` if any installment lacks it.

  When `eligible` is `false`, `reasons` and `constraints` explain why
  (for example `%{"purchase_amount" => "invalid_value"}` with minimum/maximum).

  Interest depends on the day of the call; recheck eligibility before creating a payment.
  """
  alias Alma123FS.{Client, Decode, Error, Installment}

  @path "/v2/payments/eligibility"

  defstruct [
    :eligible,
    :installments_count,
    :deferred_days,
    :deferred_months,
    :purchase_amount,
    :customer_total_cost_amount,
    :customer_total_cost_bps,
    :customer_fee,
    :customer_interest,
    :annual_interest_rate,
    :total_amount,
    payment_plan: [],
    constraints: %{},
    reasons: %{},
    raw: %{}
  ]

  @type t :: %__MODULE__{
          eligible: boolean(),
          installments_count: integer() | nil,
          deferred_days: integer() | nil,
          deferred_months: integer() | nil,
          purchase_amount: integer() | nil,
          customer_total_cost_amount: integer() | nil,
          customer_total_cost_bps: integer() | nil,
          customer_fee: integer() | nil,
          customer_interest: integer() | nil,
          annual_interest_rate: integer() | nil,
          total_amount: integer() | nil,
          payment_plan: [Installment.t()],
          constraints: map(),
          reasons: map(),
          raw: map()
        }

  @doc """
  Check eligibility of `purchase_amount` (integer cents).

  Options:

    * `:installments_counts` — plans to evaluate, e.g. `Enum.to_list(2..12)`. One result
      per requested plan, in the same order. Without it Alma runs "discovery" and returns
      only the eligible plans enabled on the account.
    * `:deferred_days`, `:deferred_months` — applied to every query.
    * `:origin` — string forwarded unchanged (documented: `"online"`, `"pos"`;
      the PHP client accepts `"online"`, `"online_in_page"`).
    * `:billing_address`, `:shipping_address` — maps with Alma field names; the country
      determines the applicable pricing.
  """
  @spec check(Client.t(), pos_integer(), keyword()) :: {:ok, [t()]} | {:error, Error.t()}
  def check(%Client{} = client, purchase_amount, options \\ []) do
    options =
      Alma123FS.Options.validate!(options, [
        :installments_counts,
        :deferred_days,
        :deferred_months,
        :origin,
        :billing_address,
        :shipping_address
      ])

    with {:ok, body} <- body(purchase_amount, options),
         {:ok, _status, response} <- Client.request(client, :post, @path, json: body) do
      parse(response)
    end
  end

  @doc "Parse one decoded eligibility result."
  @spec from_map(term()) :: {:ok, t()} | :error
  def from_map(map) when is_map(map), do: Decode.run(fn -> decode!(map) end)
  def from_map(_), do: :error

  defp parse(results) when is_list(results) do
    case Decode.run(fn -> Enum.map(results, &decode_item!/1) end) do
      {:ok, eligibilities} -> {:ok, eligibilities}
      :error -> {:error, Error.protocol(200, results)}
    end
  end

  defp parse(other), do: {:error, Error.protocol(200, other)}

  defp decode_item!(map) when is_map(map), do: decode!(map)
  defp decode_item!(_), do: Decode.invalid()

  defp decode!(map) do
    eligible =
      case Map.get(map, "eligible") do
        value when is_boolean(value) -> value
        _ -> Decode.invalid()
      end

    plan = Decode.list(map, "payment_plan", &Installment.decode!/1)

    %__MODULE__{
      eligible: eligible,
      installments_count: Decode.integer(map, "installments_count"),
      deferred_days: Decode.integer(map, "deferred_days"),
      deferred_months: Decode.integer(map, "deferred_months"),
      purchase_amount: Decode.integer(map, "purchase_amount"),
      customer_total_cost_amount: Decode.integer(map, "customer_total_cost_amount"),
      customer_total_cost_bps: Decode.integer(map, "customer_total_cost_bps"),
      customer_fee: Decode.integer(map, "customer_fee"),
      customer_interest: Decode.integer(map, "customer_interest"),
      annual_interest_rate: Decode.integer(map, "annual_interest_rate"),
      total_amount: total(plan),
      payment_plan: plan,
      constraints: Decode.map(map, "constraints") || %{},
      reasons: Decode.map(map, "reasons") || %{},
      raw: map
    }
  end

  defp total([]), do: nil

  defp total(plan) do
    if Enum.all?(plan, &is_integer(&1.total_amount)),
      do: plan |> Enum.map(& &1.total_amount) |> Enum.sum(),
      else: nil
  end

  defp body(amount, options) do
    with :ok <- positive_amount(amount),
         {:ok, queries} <- queries(options),
         :ok <- optional(options[:origin], &(is_binary(&1) and &1 != ""), "origin"),
         :ok <- optional(options[:billing_address], &plain_map?/1, "billing_address"),
         :ok <- optional(options[:shipping_address], &plain_map?/1, "shipping_address") do
      body =
        %{
          "purchase_amount" => amount,
          "queries" => queries,
          "origin" => options[:origin],
          "billing_address" => options[:billing_address],
          "shipping_address" => options[:shipping_address]
        }
        |> Map.reject(fn {_key, value} -> is_nil(value) end)

      {:ok, body}
    end
  end

  defp queries(options) do
    deferred =
      [deferred_days: options[:deferred_days], deferred_months: options[:deferred_months]]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    with :ok <- deferred_valid(deferred),
         {:ok, counts} <- counts(options[:installments_counts]) do
      extra = Map.new(deferred, fn {key, value} -> {Atom.to_string(key), value} end)
      {:ok, counts && Enum.map(counts, &Map.put(extra, "installments_count", &1))}
    end
  end

  defp counts(nil), do: {:ok, nil}

  defp counts([_ | _] = counts) do
    if Enum.all?(counts, &(is_integer(&1) and &1 in 1..12)),
      do: {:ok, counts},
      else: invalid("installments_counts must be integers from 1 to 12")
  end

  defp counts(_), do: invalid("installments_counts must be a non-empty list")

  defp deferred_valid(deferred) do
    if Enum.all?(deferred, fn {_key, value} -> is_integer(value) and value >= 0 end),
      do: :ok,
      else: invalid("deferred_days and deferred_months must be non-negative integers")
  end

  defp positive_amount(amount) when is_integer(amount) and amount > 0, do: :ok
  defp positive_amount(_), do: invalid("purchase_amount must be a positive integer in cents")

  defp optional(nil, _check, _name), do: :ok

  defp optional(value, check, name),
    do: if(check.(value), do: :ok, else: invalid("invalid #{name}"))

  defp plain_map?(value), do: is_map(value) and not is_struct(value)

  defp invalid(message), do: {:error, Error.validation(message)}
end
