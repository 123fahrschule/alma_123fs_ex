defmodule Alma123FS.WebhookTest do
  use ExUnit.Case, async: true
  alias Alma123FS.Webhook
  alias Alma123FS.Webhook.Event

  @php_signature "L1h5wQPg6UyaZlazatLpl_CtN7CwYSzxBIQ07u9DFjk"
  @php_params %{"param1" => "value1", "param2" => "value2"}

  @php_scenarios [
    {"valid_signature_with_url_encoding", @php_signature, @php_params, "secret_key", true, true},
    {"invalid_signature_with_url_encoding", "invalid_signature", @php_params, "secret_key", true,
     false},
    {"valid_signature_without_url_encoding", @php_signature, @php_params, "secret_key", false,
     true},
    {"invalid_signature_without_url_encoding", "invalid_signature", @php_params, "secret_key",
     false, false},
    {"empty_params", @php_signature, %{}, "secret_key", true, false}
  ]

  for {name, signature, params, secret, url_encode, expected} <- @php_scenarios do
    @signature signature
    @params params
    @secret secret
    @url_encode url_encode
    @expected expected

    test "PHP WebhookTest scenario #{name}" do
      assert Webhook.verify_signature(@signature, @params, @secret, url_encode: @url_encode) ==
               @expected
    end
  end

  test "url encoding defaults to true and follows rawurlencode" do
    params = %{"pid" => "payment_1", "note" => "a b/é~*", "amount" => "100"}
    encoded = "IIVvNvZ7ZDYbs3xpmdIMn28pa01nAqQrb5zuvwVGg-E"
    raw = "wfq4n3DdrtB3P3JS7R7h3MRzUa4P_iHALRwMmCs0qBY"

    assert Webhook.verify_signature(encoded, params, "whsec")
    refute Webhook.verify_signature(raw, params, "whsec")
    assert Webhook.verify_signature(raw, params, "whsec", url_encode: false)
    refute Webhook.verify_signature(encoded, params, "whsec", url_encode: false)
  end

  test "an empty parameter set signs the empty string" do
    assert Webhook.verify_signature(
             "8wTBEnTKvJOr5586u4SLlAJtPhyaSQceqW--zpufK7A",
             %{},
             "secret_key"
           )
  end

  test "atom keys and PHP-like scalar conversion give the same canonical string" do
    assert Webhook.verify_signature(
             @php_signature,
             %{param2: "value2", param1: "value1"},
             "secret_key"
           )

    signature = sign("a=1&b=1&c=&d=")

    assert Webhook.verify_signature(
             signature,
             %{"a" => 1, "b" => true, "c" => false, "d" => nil},
             "k"
           )
  end

  test "unsupported values, duplicate names and wrong argument types are rejected" do
    refute Webhook.verify_signature(@php_signature, %{"param1" => ["value1"]}, "secret_key")
    refute Webhook.verify_signature(@php_signature, %{"param1" => 1.5}, "secret_key")
    refute Webhook.verify_signature(@php_signature, %{1 => "value1"}, "secret_key")
    refute Webhook.verify_signature(sign("a=1"), %{:a => "1", "a" => "1"}, "k")
    refute Webhook.verify_signature(nil, @php_params, "secret_key")
    refute Webhook.verify_signature(@php_signature, [param1: "value1"], "secret_key")
    refute Webhook.verify_signature(@php_signature, @php_params, nil)
  end

  test "documented events map to atoms and keep the payload" do
    for {code, type} <- Webhook.event_types() do
      payload = %{"type" => code, "data" => %{"id" => "payment_1"}}

      assert {:ok, %Event{type: ^type, raw_type: ^code, payload: ^payload}} =
               Webhook.parse_event(payload)
    end

    assert Map.values(Webhook.event_types()) |> Enum.sort() ==
             [:payment_authorized, :payment_canceled, :payment_captured, :payment_created]
  end

  test "unknown or missing event codes do not break the parse" do
    assert {:ok, %Event{type: :unknown, raw_type: "payment.refunded"}} =
             Webhook.parse_event(%{"type" => "payment.refunded"})

    assert {:ok, %Event{type: :unknown, raw_type: nil}} = Webhook.parse_event(%{"type" => 1})
    assert {:ok, %Event{type: :unknown, raw_type: nil, payload: %{}}} = Webhook.parse_event(%{})
  end

  test "the event code falls back to the event field and JSON strings are decoded" do
    assert {:ok, %Event{type: :payment_captured}} =
             Webhook.parse_event(%{"event" => "payment.captured"})

    assert {:ok, %Event{type: :payment_created}} =
             Webhook.parse_event(~s({"type":"payment.created"}))
  end

  test "names are sorted bytewise like PHP ksort with SORT_STRING" do
    params = %{"ab" => "4", "a_b" => "3", "a" => "2", "B" => "1"}
    assert Webhook.verify_signature("_RsiQK8uAI_1-QafnXbaqX4lL6G6R93UUXyq58JLNZM", params, "k")
  end

  test "a documented code in either field wins over a non-event value" do
    assert {:ok, %Event{type: :payment_captured, raw_type: "payment.captured"}} =
             Webhook.parse_event(%{"type" => "payment", "event" => "payment.captured"})

    assert {:ok, %Event{type: :payment_canceled}} =
             Webhook.parse_event(%{"type" => nil, "event" => "payment.canceled"})

    assert {:ok, %Event{type: :unknown, raw_type: "payment"}} =
             Webhook.parse_event(%{"type" => "payment", "event" => 3})
  end

  test "bodies that are not JSON objects are invalid" do
    for body <- ["{broken", "[]", ~s("payment.created"), [], nil, ~D[2026-01-01]] do
      assert {:error, :invalid_payload} = Webhook.parse_event(body)
    end
  end

  defp sign(data),
    do: :hmac |> :crypto.mac(:sha256, "k", data) |> Base.url_encode64(padding: false)
end
