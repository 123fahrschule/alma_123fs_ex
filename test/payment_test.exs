defmodule Alma123FS.PaymentTest do
  use ExUnit.Case, async: true
  import Alma123FS.TestSupport
  alias Alma123FS.{Installment, Order, Payment}

  test "the PHP client's payment fixture parses" do
    assert {:ok, payment} = Payment.from_map(fixture("payment_php.json"))

    assert %Payment{
             id: "payment_xxxxxx",
             url: "https://test.alma.eu/payments/v2/payments/payment_xxxxxx",
             processing_status: :authorized,
             cancelation_reason: nil,
             purchase_amount: 11_733,
             installments_count: 3,
             customer_fee: 100,
             customer_interest: 0,
             custom_data: %{},
             capture_method: nil,
             merchant_id: nil,
             fees: nil
           } = payment

    assert payment.expired_at == DateTime.from_unix!(1_657_528_851)

    assert [%Installment{state: :paid, customer_fee: 100, date_paid: %DateTime{}} | _] =
             payment.payment_plan

    assert [%Order{merchant_reference: "C1-000027951", payment: "payment_xxxxxx"}] =
             payment.orders

    assert payment.raw["state"] == "paid"
  end

  test "every documented field of the constructed canceled payment is mapped" do
    assert {:ok, payment} = Payment.from_map(fixture("payment_canceled_constructed.json"))

    assert %Payment{
             processing_status: :canceled,
             cancelation_reason: :requested_by_merchant,
             capture_method: :automatic,
             merchant_id: "merchant_11gLsWNxRc3ZLvM1G4RbQzTsLKmeE0yYCq",
             custom_data: %{"payment_id" => "8b3f2c1e-0000-4000-8000-000000000001"},
             fees: %{"merchant" => %{"total" => 1350}}
           } = payment

    assert [%Order{merchant_reference: "RS-PAYMENT-1", created_at: %DateTime{}}] = payment.orders
    assert Enum.all?(payment.payment_plan, &(&1.state == :pending and &1.date_paid == nil))
  end

  test "the documented order example parses inside a payment" do
    assert {:ok, %Payment{orders: [order]}} =
             Payment.from_map(%{"id" => "p", "orders" => [fixture("order_docs.json")]})

    assert %Order{
             id: "order_11h4MCc4atnjecmoK6GU6UYGo6qMK6RMLw",
             merchant_reference: "ref-9676683702228572",
             merchant_url: "https://backoffice.merchant.com/orders/ref-9676683702228572",
             customer_url: nil,
             payment: "payment_11h4MEW6jokMbn3ya4sI0scgeauAm41CO4",
             data: %{},
             comment: nil
           } = order

    assert order.created_at == DateTime.from_unix!(1_552_553_941)
  end

  test "fields the library does not act on are kept as received" do
    assert {:ok, %Payment{fees: [], custom_data: "ref-1", orders: [%Order{data: []}]}} =
             Payment.from_map(%{
               "id" => "p",
               "fees" => [],
               "custom_data" => "ref-1",
               "orders" => [%{"data" => []}]
             })
  end

  test "every status value has an explicit mapping" do
    for {raw, atom} <- [
          {"awaiting_authorization", :awaiting_authorization},
          {"authorized", :authorized},
          {"captured", :captured},
          {"canceled", :canceled}
        ] do
      assert {:ok, %Payment{processing_status: ^atom}} =
               Payment.from_map(%{"id" => "p", "processing_status" => raw})
    end

    for reason <-
          ~w(requested_by_merchant requested_by_customer authorization_expired expired declined) do
      assert {:ok, %Payment{cancelation_reason: atom}} =
               Payment.from_map(%{"id" => "p", "cancelation_reason" => reason})

      assert Atom.to_string(atom) == reason
    end

    assert {:ok, %Payment{capture_method: :manual}} =
             Payment.from_map(%{"id" => "p", "capture_method" => "manual"})
  end

  test "unknown values do not break the parse" do
    assert {:ok, payment} =
             Payment.from_map(%{
               "id" => "p",
               "processing_status" => "on_hold",
               "cancelation_reason" => "fraud",
               "capture_method" => 1,
               "payment_plan" => [%{"state" => "late"}]
             })

    assert %Payment{
             processing_status: :unknown,
             cancelation_reason: :unknown,
             capture_method: :unknown
           } = payment

    assert [%Installment{state: :unknown}] = payment.payment_plan
    assert payment.raw["processing_status"] == "on_hold"
  end

  test "a missing id or a mistyped field is not a payment" do
    for map <- [
          %{},
          %{"id" => ""},
          %{"id" => 1},
          %{"id" => "p", "purchase_amount" => "11733"},
          %{"id" => "p", "expired_at" => "2026-01-01"},
          %{"id" => "p", "expired_at" => 99_999_999_999_999},
          %{"id" => "p", "payment_plan" => %{}},
          %{"id" => "p", "payment_plan" => [1]},
          %{"id" => "p", "orders" => [%{"created" => "yesterday"}]},
          %{"id" => "p", "orders" => [%{"merchant_reference" => 1}]}
        ] do
      assert :error = Payment.from_map(map)
    end

    assert :error = Payment.from_map([])
  end
end
