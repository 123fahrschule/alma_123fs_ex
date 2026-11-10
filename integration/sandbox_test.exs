defmodule Alma123FS.SandboxTest do
  use ExUnit.Case, async: false
  alias Alma123FS.{Client, Eligibility, Payment, Payments}

  @api_key System.get_env("ALMA_API_KEY", "")

  @moduletag :integration
  if @api_key == "", do: @moduletag(skip: "ALMA_API_KEY (sk_test_…) is not set")

  setup_all do
    {:ok, client: Client.new(api_key: System.fetch_env!("ALMA_API_KEY"), environment: :sandbox)}
  end

  test "eligibility returns one result per requested plan", %{client: client} do
    counts = Enum.to_list(2..12)
    assert {:ok, results} = Eligibility.check(client, 45_000, installments_counts: counts)
    assert Enum.map(results, & &1.installments_count) == counts

    for %Eligibility{eligible: true} = result <- results do
      assert result.payment_plan != []
      assert is_integer(result.total_amount)
    end
  end

  test "a created payment can be fetched, listed and canceled", %{client: client} do
    reference = reference()
    created_after = DateTime.utc_now() |> DateTime.add(-60)
    {:ok, payment} = create(client, reference, "#{reference}@example.com")
    id = payment.id
    assert payment.processing_status == :awaiting_authorization

    assert {:ok,
            %Payment{id: ^id, purchase_amount: 45_000, custom_data: %{"reference" => ^reference}}} =
             Payments.fetch(client, id)

    assert id in list_ids(client, created_after: created_after)
    assert :ok = Payments.cancel(client, id)

    assert {:ok, %Payment{processing_status: :canceled, cancelation_reason: reason}} =
             Payments.fetch(client, id)

    assert reason == :requested_by_merchant
  end

  test "canceling an already canceled payment succeeds again", %{client: client} do
    {:ok, payment} = create(client, reference(), nil)
    assert :ok = Payments.cancel(client, payment.id)
    assert :ok = Payments.cancel(client, payment.id)
    assert {:ok, %Payment{processing_status: :canceled}} = Payments.fetch(client, payment.id)
  end

  test "errors for an unknown payment and an invalid key", %{client: client} do
    assert {:error, not_found} = Payments.fetch(client, "payment_doesnotexist0000000000000000")
    IO.puts("\nunknown payment: status=#{not_found.status} message=#{inspect(not_found.message)}")
    assert %Alma123FS.Error{kind: :api, status: 404, type: :not_found} = not_found
    assert not_found.message =~ "not found"

    bad = Client.new(api_key: "sk_test_invalid", environment: :sandbox)
    assert {:error, unauthorized} = Eligibility.check(bad, 45_000)
    IO.puts("invalid key: status=#{unauthorized.status} message=#{inspect(unauthorized.message)}")
    assert %Alma123FS.Error{status: 403, type: :forbidden} = unauthorized
  end

  test "a customer email with a real domain is stored and filterable", %{client: client} do
    reference = reference()
    email = "#{reference}@example.com"
    {:ok, payment} = create(client, reference, email)
    {:ok, fetched} = Payments.fetch(client, payment.id)
    IO.puts("\nstored customer email: #{inspect(get_in(fetched.raw, ["customer", "email"]))}")
    assert get_in(fetched.raw, ["customer", "email"]) == email
    assert payment.id in list_ids(client, customer_email: reference)
  end

  defp create(client, reference, email) do
    customer =
      %{first_name: "Erika", last_name: "Mustermann", email: email}
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    result =
      Payments.create(client, %{
        payment: %{
          purchase_amount: 45_000,
          installments_count: 3,
          origin: "online_in_page",
          expires_after: 30,
          locale: "de",
          return_url: "https://example.com/alma/return",
          customer_cancel_url: "https://example.com/alma/cancel",
          ipn_callback_url: "https://example.com/alma/ipn",
          custom_data: %{"reference" => reference}
        },
        customer: customer,
        order: %{merchant_reference: reference}
      })

    with {:ok, %Payment{id: id}} <- result do
      on_exit(fn -> Payments.cancel(client, id) end)
    end

    result
  end

  defp list_ids(client, filters, starting_after \\ nil, pages \\ 5) do
    {:ok, %{payments: payments, has_more: more}} =
      Payments.list(client, filters ++ [limit: 100, starting_after: starting_after])

    ids = Enum.map(payments, & &1.id)

    if more and pages > 1 and ids != [],
      do: ids ++ list_ids(client, filters, List.last(ids), pages - 1),
      else: ids
  end

  defp reference, do: "alma-123fs-ex-#{System.system_time(:millisecond)}"
end
