defmodule Alma123FS.EligibilityTest do
  use ExUnit.Case, async: true
  import Alma123FS.TestSupport
  alias Alma123FS.{Eligibility, Error, Installment}

  test "queries every requested plan with the same deferral, origin and addresses" do
    respond(200, [])

    assert {:ok, []} =
             Eligibility.check(client(), 81_700,
               installments_counts: [2, 3, 12],
               deferred_days: 0,
               deferred_months: 1,
               origin: "online",
               billing_address: %{"country" => "DE"},
               shipping_address: %{country: "DE"}
             )

    assert_received {:request, %{method: "POST", path: "/v2/payments/eligibility", body: body}}

    assert body == %{
             "purchase_amount" => 81_700,
             "origin" => "online",
             "billing_address" => %{"country" => "DE"},
             "shipping_address" => %{"country" => "DE"},
             "queries" => [
               %{"installments_count" => 2, "deferred_days" => 0, "deferred_months" => 1},
               %{"installments_count" => 3, "deferred_days" => 0, "deferred_months" => 1},
               %{"installments_count" => 12, "deferred_days" => 0, "deferred_months" => 1}
             ]
           }
  end

  test "without plans the request is a discovery request" do
    respond(200, [])
    assert {:ok, []} = Eligibility.check(client(), 20_000)
    assert_received {:request, %{body: %{"purchase_amount" => 20_000} = body}}
    assert map_size(body) == 1
  end

  test "the documented v2 example parses with schedule, cost and total" do
    respond(200, fixture("eligibility_v2_response.json"))

    assert {:ok, [p3x, p4x, p10x]} =
             Eligibility.check(client(), 81_700, installments_counts: [3, 4, 10])

    assert %Eligibility{
             eligible: true,
             installments_count: 3,
             purchase_amount: 81_700,
             customer_total_cost_amount: 0,
             total_amount: 81_700,
             deferred_days: 0,
             deferred_months: 0
           } = p3x

    assert %Eligibility{
             customer_total_cost_amount: 1936,
             customer_total_cost_bps: 237,
             total_amount: 83_636
           } = p4x

    assert [
             %Installment{
               customer_fee: 1936,
               purchase_amount: 20_425,
               total_amount: 22_361,
               due_date: due
             }
             | _
           ] = p4x.payment_plan

    assert due == DateTime.from_unix!(1_628_067_070)

    assert %Eligibility{
             installments_count: 10,
             customer_total_cost_amount: 4962,
             total_amount: 86_662
           } = p10x

    assert length(p10x.payment_plan) == 10
    assert p10x.payment_plan |> Enum.map(& &1.customer_interest) |> Enum.sum() == 4962
    assert p3x.customer_fee == nil and p3x.annual_interest_rate == nil
  end

  test "an ineligible result from the PHP tests carries reasons and constraints" do
    respond(200, fixture("eligibility_ineligible_php.json"))
    assert {:ok, [result]} = Eligibility.check(client(), 130, installments_counts: [3])

    assert %Eligibility{
             eligible: false,
             payment_plan: [],
             total_amount: nil,
             reasons: %{"purchase_amount" => "invalid_value"},
             constraints: %{"purchase_amount" => %{"minimum" => 5000, "maximum" => 200_000}}
           } = result
  end

  test "fields from the PHP model are read when present" do
    item = %{
      "eligible" => true,
      "customer_fee" => 310,
      "customer_interest" => 0,
      "annual_interest_rate" => 0,
      "payment_plan" => [%{"total_amount" => 6978}, %{"purchase_amount" => 6666}]
    }

    assert {:ok, %Eligibility{customer_fee: 310, annual_interest_rate: 0, total_amount: nil}} =
             Eligibility.from_map(item)
  end

  test "invalid input is rejected before any request" do
    stub(fn _ -> flunk("must not reach Alma") end)

    for {amount, options} <- [
          {0, []},
          {-1, []},
          {10.5, []},
          {1000, installments_counts: []},
          {1000, installments_counts: [13]},
          {1000, installments_counts: [0]},
          {1000, installments_counts: 3},
          {1000, deferred_days: -1},
          {1000, deferred_months: "1"},
          {1000, origin: ""},
          {1000, billing_address: "DE"},
          {1000, shipping_address: ~D[2026-01-01]}
        ] do
      assert {:error, %Error{kind: :validation}} = Eligibility.check(client(), amount, options)
    end
  end

  test "unknown options raise" do
    assert_raise ArgumentError, fn -> Eligibility.check(client(), 1000, installments: [3]) end
  end

  test "responses that are not lists of results are protocol errors" do
    for body <- [
          %{"eligible" => true},
          [%{"installments_count" => 3}],
          [%{"eligible" => "yes"}],
          [%{"eligible" => true, "payment_plan" => "none"}],
          [%{"eligible" => true, "customer_total_cost_amount" => "0"}],
          ["result"]
        ] do
      respond(200, body)
      assert {:error, %Error{kind: :protocol}} = Eligibility.check(client(), 1000)
    end

    assert :error = Eligibility.from_map(nil)
  end

  test "API and transport errors are plain errors for this read-only call" do
    respond(400, %{"message" => "merchant not activated"})

    assert {:error, %Error{kind: :api, status: 400, message: "merchant not activated"}} =
             Eligibility.check(client(), 1000)

    transport_error(:timeout)

    assert {:error, %Error{kind: :transport, reason: :timeout}} =
             Eligibility.check(client(), 1000)
  end
end
