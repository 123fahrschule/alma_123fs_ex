defmodule Alma123FS.PaymentsTest do
  use ExUnit.Case, async: true
  import Alma123FS.TestSupport
  alias Alma123FS.{Error, Payment, Payments}

  @params %{
    payment: %{
      purchase_amount: 45_000,
      installments_count: 3,
      capture_method: "automatic",
      expires_after: 60,
      origin: "online_in_page",
      ipn_callback_url: "https://example.test/alma/ipn",
      return_url: "https://example.test/alma/return",
      customer_cancel_url: "https://example.test/alma/cancel",
      failure_return_url: "https://example.test/alma/failure",
      custom_data: %{"payment_id" => "8b3f2c1e"},
      locale: "de",
      billing_address: %{country: "DE"},
      shipping_address: %{"country" => "DE"},
      cart: %{
        items: [
          %{
            title: "Paket",
            quantity: 1,
            line_price: 45_000,
            picture_url: "https://example.test/p.png"
          }
        ]
      }
    },
    customer: %{first_name: "Erika", last_name: "Mustermann", email: "erika@example.test"},
    order: %{merchant_reference: "RS-PAYMENT-1"}
  }

  describe "create/2" do
    test "sends Alma's body and returns the created payment" do
      respond(200, fixture("payment_php.json"))
      assert {:ok, %Payment{id: "payment_xxxxxx"}} = Payments.create(client(), @params)
      assert_received {:request, %{method: "POST", path: "/v1/payments", body: body}}

      assert body["payment"]["purchase_amount"] == 45_000
      assert body["payment"]["installments_count"] == 3
      assert body["payment"]["origin"] == "online_in_page"
      assert body["payment"]["expires_after"] == 60
      assert body["payment"]["custom_data"] == %{"payment_id" => "8b3f2c1e"}

      assert body["payment"]["cart"]["items"] == [
               %{
                 "title" => "Paket",
                 "quantity" => 1,
                 "line_price" => 45_000,
                 "picture_url" => "https://example.test/p.png"
               }
             ]

      assert body["customer"]["email"] == "erika@example.test"
      assert body["order"] == %{"merchant_reference" => "RS-PAYMENT-1"}
      assert Map.keys(body) |> Enum.sort() == ["customer", "order", "payment"]
    end

    test "accepts string keys and forwards unlisted payment fields" do
      respond(200, %{"id" => "payment_1"})

      params = %{
        "payment" => %{
          "purchase_amount" => 100,
          "installments_count" => 1,
          "deferred_days" => 30,
          "capture_method" => :manual
        }
      }

      assert {:ok, %Payment{id: "payment_1"}} = Payments.create(client(), params)

      assert_received {:request,
                       %{
                         body: %{
                           "payment" => %{"deferred_days" => 30, "capture_method" => "manual"}
                         }
                       }}
    end

    test "rejects invalid parameters before any request" do
      stub(fn _ -> flunk("must not reach Alma") end)
      put = fn key, value -> put_in(@params, [:payment, key], value) end

      for params <- [
            nil,
            [],
            %{},
            %{payment: "x"},
            %{payment: %{installments_count: 3}},
            %{payment: %{purchase_amount: 100}},
            put.(:purchase_amount, 0),
            put.(:purchase_amount, 450.0),
            put.(:installments_count, 13),
            put.(:installments_count, 0),
            put.(:capture_method, "later"),
            put.(:expires_after, 0),
            put.(:origin, ""),
            put.(:locale, :de),
            put.(:return_url, "/relative"),
            put.(:ipn_callback_url, "ftp://example.test"),
            put.(:customer_cancel_url, "https://"),
            put.(:custom_data, "payment_1"),
            put.(:cart, [1]),
            Map.put(@params, :merchant_reference, "RS-1"),
            Map.put(@params, :customer, "erika"),
            Map.put(@params, :order, merchant_reference: "x"),
            Map.put(@params, "payment", %{}),
            %{
              payment: %{:purchase_amount => 1, "purchase_amount" => 1, :installments_count => 3}
            },
            %{payment: %{1 => 2}}
          ] do
        assert {:error, %Error{kind: :validation}} = Payments.create(client(), params)
      end
    end

    test "timeouts and closed connections are an unknown outcome" do
      for reason <- [:timeout, :closed, :econnreset] do
        transport_error(reason)

        assert {:unknown, %Error{kind: :transport, reason: ^reason}} =
                 Payments.create(client(), @params)
      end
    end

    test "5xx and unreadable 2xx bodies are an unknown outcome" do
      for {status, body} <- [
            {500, %{"message" => "boom"}},
            {503, ""},
            {200, "not json"},
            {200, %{"url" => "x"}},
            {201, []}
          ] do
        respond(status, body)
        assert {:unknown, %Error{}} = Payments.create(client(), @params)
      end
    end

    test "unencodable nested values are a validation error, not an exception" do
      stub(fn _ -> flunk("must not reach Alma") end)
      params = put_in(@params, [:payment, :custom_data], %{"ref" => {:our, 1}})
      assert {:error, %Error{kind: :validation}} = Payments.create(client(), params)
    end

    test "HTTP 408 is an unknown outcome" do
      respond(408, "")
      assert {:unknown, %Error{status: 408}} = Payments.create(client(), @params)
    end

    test "4xx answers are rejections, not unknown outcomes" do
      for status <- [400, 401, 403, 422, 429] do
        respond(status, %{"message" => "rejected"})

        assert {:error, %Error{kind: :api, status: ^status, message: "rejected"}} =
                 Payments.create(client(), @params)
      end
    end
  end

  describe "fetch/2" do
    test "returns the parsed payment" do
      respond(200, fixture("payment_canceled_constructed.json"))
      id = "payment_11uPRjP4a3cFQvoM1lehDnpxa2tYm2Hy0I"
      assert {:ok, %Payment{id: ^id, processing_status: :canceled}} = Payments.fetch(client(), id)
      assert_received {:request, %{method: "GET", path: "/v1/payments/" <> ^id, body: nil}}
    end

    test "rejects ids that could change the path" do
      stub(fn _ -> flunk("must not reach Alma") end)

      for id <- ["../balance-transactions", "p/cancel", "p?x=1", ""] do
        assert {:error, %Error{kind: :validation}} = Payments.fetch(client(), id)
      end
    end

    test "errors are plain errors for this read" do
      respond(404, %{"message" => "Not found"})

      assert {:error, %Error{type: :not_found, message: "Not found"}} =
               Payments.fetch(client(), "p")

      transport_error(:timeout)
      assert {:error, %Error{kind: :transport}} = Payments.fetch(client(), "p")
      respond(200, %{"no" => "id"})
      assert {:error, %Error{kind: :protocol, status: 200}} = Payments.fetch(client(), "p")
    end
  end

  describe "cancel/2" do
    test "HTTP 204 is :ok" do
      respond(204, "")
      assert :ok = Payments.cancel(client(), "payment_1")
      assert_received {:request, %{method: "POST", path: "/v1/payments/payment_1/cancel"}}
    end

    test "HTTP 400 carries Alma's documented message" do
      respond(400, fixture("cancel_400.json"))

      assert {:error,
              %Error{
                type: :bad_request,
                status: 400,
                message: "Le statut de ce paiement ne permet pas de l'annuler"
              }} =
               Payments.cancel(client(), "payment_1")
    end

    test "transport failures and 5xx leave the cancelation unknown" do
      transport_error(:timeout)
      assert {:unknown, %Error{kind: :transport}} = Payments.cancel(client(), "payment_1")
      respond(502, "")
      assert {:unknown, %Error{status: 502}} = Payments.cancel(client(), "payment_1")
    end

    test "an unreadable 2xx body leaves the cancelation unknown" do
      respond(200, "<html>")
      assert {:unknown, %Error{kind: :protocol}} = Payments.cancel(client(), "payment_1")
    end

    test "invalid ids are rejected locally" do
      assert {:error, %Error{kind: :validation}} = Payments.cancel(client(), "a/b")
    end
  end

  describe "list/2" do
    test "encodes filters and parses the page" do
      respond(200, fixture("payments_list_constructed.json"))

      assert {:ok, %{payments: [%Payment{} = first, %Payment{}], has_more: true}} =
               Payments.list(client(),
                 created_after: ~U[2025-11-10 10:00:00Z],
                 created_before: 1_762_772_400,
                 customer_email: "student@example.test",
                 state: ["not_started", "scored_yes"],
                 limit: 100,
                 starting_after: "payment_11uPRjP4a3cFQvoM1lehDnpxa2tYm2Hy0B"
               )

      assert first.purchase_amount == 45_000
      assert first.installments_count == nil
      assert first.processing_status == nil

      assert_received {:request, %{method: "GET", path: "/v1/payments", query: query}}

      assert query == %{
               "created_after" => "1762768800",
               "created_before" => "1762772400",
               "customer_email" => "student@example.test",
               "state" => "not_started,scored_yes",
               "limit" => "100",
               "starting_after" => "payment_11uPRjP4a3cFQvoM1lehDnpxa2tYm2Hy0B"
             }
    end

    test "nil filters are omitted and a single state is sent as is" do
      respond(200, %{"data" => [], "has_more" => false})

      assert {:ok, %{payments: [], has_more: false}} =
               Payments.list(client(), state: "paid", limit: nil)

      assert_received {:request, %{query: %{"state" => "paid"} = query}}
      assert map_size(query) == 1
    end

    test "invalid filters are rejected locally" do
      stub(fn _ -> flunk("must not reach Alma") end)

      for filters <- [
            [limit: 0],
            [limit: 101],
            [created_after: -1],
            [created_before: "yesterday"],
            [customer_email: ""],
            [state: []],
            [state: ["paid", 1]],
            [starting_after: "../x"]
          ] do
        assert {:error, %Error{kind: :validation}} = Payments.list(client(), filters)
      end

      assert_raise ArgumentError, fn -> Payments.list(client(), email: "x") end
    end

    test "the sandbox's 422 for an unsupported state carries Alma's code and message" do
      respond(422, fixture("list_state_422_sandbox.json"))

      assert {:error,
              %Error{
                kind: :api,
                status: 422,
                type: :unprocessable_entity,
                code: "validation_error",
                message: message
              }} =
               Payments.list(client(), state: "__not__paid")

      assert message =~ "'in_progress'"
      assert_received {:request, %{query: %{"state" => "__not__paid"}}}
    end

    test "unexpected envelopes are protocol errors" do
      for body <- [
            [],
            %{"data" => []},
            %{"data" => %{}, "has_more" => false},
            %{"data" => [%{}], "has_more" => false}
          ] do
        respond(200, body)
        assert {:error, %Error{kind: :protocol}} = Payments.list(client())
      end
    end
  end
end
