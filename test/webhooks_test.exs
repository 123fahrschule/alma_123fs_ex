defmodule Alma123FS.WebhooksTest do
  use ExUnit.Case, async: true
  import Alma123FS.TestSupport
  alias Alma123FS.{Error, Webhooks}

  @id "webhook_1213KqH5XRTfCB2w3ZK1qkZRahPy22Ex4J"

  test "create posts type and url and returns the PHP fixture response" do
    respond(200, fixture("webhook_create_php.json"))

    assert {:ok, %{"id" => @id, "type" => "ecommerce_report"}} =
             Webhooks.create(
               client(),
               "ecommerce_report",
               "https://api-sandbox.example-services.io"
             )

    assert_received {:request, %{method: "POST", path: "/v1/webhooks", body: body}}

    assert body == %{
             "type" => "ecommerce_report",
             "url" => "https://api-sandbox.example-services.io"
           }
  end

  test "create validates its arguments locally" do
    stub(fn _ -> flunk("must not reach Alma") end)

    assert {:error, %Error{kind: :validation}} =
             Webhooks.create(client(), "", "https://example.test")

    assert {:error, %Error{kind: :validation}} =
             Webhooks.create(client(), :payment, "https://example.test")

    assert {:error, %Error{kind: :validation}} =
             Webhooks.create(client(), "t", "example.test/hook")

    assert {:error, %Error{kind: :validation}} = Webhooks.create(client(), "t", nil)
  end

  test "create reports an unknown outcome when the subscription may exist" do
    transport_error(:timeout)

    assert {:unknown, %Error{kind: :transport}} =
             Webhooks.create(client(), "t", "https://example.test")

    respond(200, ["unexpected"])

    assert {:unknown, %Error{kind: :protocol}} =
             Webhooks.create(client(), "t", "https://example.test")

    respond(400, %{"message" => "invalid type"})

    assert {:error, %Error{type: :bad_request, message: "invalid type"}} =
             Webhooks.create(client(), "t", "https://example.test")
  end

  test "fetch reads one subscription" do
    respond(200, fixture("webhook_create_php.json"))
    assert {:ok, %{"id" => @id}} = Webhooks.fetch(client(), @id)
    assert_received {:request, %{method: "GET", path: "/v1/webhooks/" <> @id}}
    respond(200, "")
    assert {:error, %Error{kind: :protocol}} = Webhooks.fetch(client(), @id)
    respond(404, %{})
    assert {:error, %Error{type: :not_found}} = Webhooks.fetch(client(), @id)
    assert {:error, %Error{kind: :validation}} = Webhooks.fetch(client(), "../payments")
  end

  test "delete returns :ok on success and unknown when it may have happened" do
    respond(204, "")
    assert :ok = Webhooks.delete(client(), @id)
    assert_received {:request, %{method: "DELETE", path: "/v1/webhooks/" <> @id}}
    respond(500, %{})
    assert {:unknown, %Error{status: 500}} = Webhooks.delete(client(), @id)
    respond(200, "not json")
    assert {:unknown, %Error{kind: :protocol}} = Webhooks.delete(client(), @id)
    respond(404, %{})
    assert {:error, %Error{type: :not_found}} = Webhooks.delete(client(), @id)
    assert {:error, %Error{kind: :validation}} = Webhooks.delete(client(), "a b")
  end
end
