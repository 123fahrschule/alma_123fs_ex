defmodule Alma123FS.APIContractTest do
  use ExUnit.Case, async: true
  import Alma123FS.TestSupport
  alias Alma123FS.{Client, Eligibility, Payments, Webhooks}

  @contract fixture("api_contract.json")
  @id "resource_123"

  @calls %{
    "eligibility" => {Eligibility, :check, [1000, [installments_counts: [3]]], []},
    "payments.create" =>
      {Payments, :create, [%{payment: %{purchase_amount: 1000, installments_count: 3}}],
       %{"id" => "p"}},
    "payments.fetch" => {Payments, :fetch, [@id], %{"id" => "p"}},
    "payments.cancel" => {Payments, :cancel, [@id], ""},
    "payments.list" => {Payments, :list, [[limit: 1]], %{"data" => [], "has_more" => false}},
    "webhooks.create" =>
      {Webhooks, :create, ["ecommerce_report", "https://example.test"], %{"id" => "w"}},
    "webhooks.fetch" => {Webhooks, :fetch, [@id], %{"id" => "w"}},
    "webhooks.delete" => {Webhooks, :delete, [@id], ""}
  }

  test "every contract operation is exercised and every public API function is listed" do
    assert Map.keys(@calls) |> Enum.sort() == Map.keys(@contract["operations"]) |> Enum.sort()

    exported =
      for module <- [Eligibility, Payments, Webhooks],
          {function, _arity} <- module.__info__(:functions),
          function not in [:from_map, :__struct__],
          into: MapSet.new(),
          do: {module, function}

    listed =
      for {_name, {module, function, _, _}} <- @calls, into: MapSet.new(), do: {module, function}

    assert MapSet.equal?(exported, listed)
  end

  test "base URLs match the pinned contract" do
    assert Client.new(api_key: "k", environment: :live).base_url == @contract["base_urls"]["live"]

    assert Client.new(api_key: "k", environment: :sandbox).base_url ==
             @contract["base_urls"]["sandbox"]
  end

  for {name, operation} <- @contract["operations"] do
    @name name
    @operation operation

    test "#{name} uses #{operation["method"]} #{operation["path"]} with Alma-Auth" do
      {module, function, args, response} = @calls[@name]
      respond(200, response)
      apply(module, function, [client() | args])

      assert_received {:request, request}
      assert request.method == @operation["method"]
      assert request.path == String.replace(@operation["path"], "{id}", @id)

      assert request.headers[@contract["authorization"]["header"]] ==
               "#{@contract["authorization"]["scheme"]} sk_test_fake_key"

      body_keys = @operation["body_root"] || @operation["body"]
      if body_keys, do: assert(Map.keys(request.body) -- body_keys == [])
      if @operation["query"], do: assert(Map.keys(request.query) -- @operation["query"] == [])
    end
  end
end
