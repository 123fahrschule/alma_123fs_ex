# Integration guide: Alma installments in a Phoenix application

This guide walks through the whole flow with this package: configuration, showing the
plans, creating the payment, Alma In-Page in the browser, confirming the payment on
`return_url` and on the IPN, abandoned payments and tests. Module names such as
`MyApp.Alma` are examples; persistence and jobs belong to your application.

The flow:

```
browser ──► your server: eligibility ──► plans shown
browser ──► your server: create payment (record persisted first) ──► payment.id
browser ──► Alma In-Page (payment.id) ──► customer pays
Alma ──► browser redirect to return_url?pid=…      ─┐
Alma ──► GET ipn_callback_url?pid=… (signed, ~1 min) ─┴► fetch payment ► confirm once
```

## 1. Dependency and configuration

```elixir
# mix.exs
{:alma_123fs_ex, github: "123fahrschule/alma_123fs_ex", tag: "0.1.0"}
```

```elixir
# config/runtime.exs — read at boot, never at compile time
config :alma_123fs_ex,
  api_key: System.fetch_env!("ALMA_API_KEY"),
  environment: if(config_env() == :prod, do: :live, else: :sandbox)

# config/test.exs — every request goes to a Req.Test stub, never to Alma
config :alma_123fs_ex,
  api_key: "sk_test_fake",
  environment: :sandbox,
  plug: {Req.Test, Alma123FS}
```

The environment must match the key (`sk_test_…` ↔ `:sandbox`, `sk_live_…` ↔ `:live`),
otherwise `Alma123FS.client/1` raises at the first call.

A small wrapper keeps the rest of the application independent of the configuration:

```elixir
defmodule MyApp.Alma do
  def client, do: Alma123FS.client()
  def api_key, do: Application.fetch_env!(:alma_123fs_ex, :api_key)
end
```

## 2. Showing the plans

```elixir
{:ok, results} =
  Alma123FS.Eligibility.check(MyApp.Alma.client(), amount_cents, installments_counts: Enum.to_list(2..12))

plans = Enum.filter(results, & &1.eligible)
# each plan: installments_count, total_amount, customer_total_cost_amount,
# payment_plan: [%Alma123FS.Installment{due_date, total_amount, customer_fee, customer_interest}]
```

Eligibility says which plans the merchant account offers for the amount; it does not
approve the customer. Alma scores the customer later, on its checkout, and may refuse the
installments and offer to pay everything at once (see step 5).

## 3. Creating the payment

`POST /v1/payments` has no idempotency key. Persist your own payment record and the time
**before** the call, put your id into `custom_data` and `order.merchant_reference`, and
treat `{:unknown, _}` as "maybe created":

```elixir
def start_payment(local_payment, student) do
  address = %{
    first_name: student.first_name,
    last_name: student.last_name,
    email: student.email,
    phone: student.phone,
    line1: student.street,
    postal_code: student.zip,
    city: student.city,
    country: "DE"
  }

  params = %{
    payment: %{
      purchase_amount: local_payment.amount_cents,
      installments_count: local_payment.installments_count,
      origin: "online_in_page",
      expires_after: 60,
      locale: "de",
      ipn_callback_url: url(~p"/webhooks/alma/ipn"),
      return_url: url(~p"/payment/alma/return"),
      customer_cancel_url: url(~p"/payment/alma/cancel"),
      failure_return_url: url(~p"/payment/alma/failure"),
      custom_data: %{"payment_id" => local_payment.id},
      billing_address: address
    },
    customer: %{
      first_name: student.first_name,
      last_name: student.last_name,
      email: student.email,
      phone: student.phone,
      birth_date: Date.to_iso8601(student.birth_date),
      addresses: [address]
    },
    order: %{merchant_reference: local_payment.id}
  }

  case Alma123FS.Payments.create(MyApp.Alma.client(), params) do
    {:ok, payment} -> {:ok, payment.id, payment.merchant_id}
    {:error, error} -> {:error, error}
    {:unknown, _error} -> :unknown
  end
end
```

- `{:error, %Alma123FS.Error{}}` — nothing was created; show an error, the student may
  retry.
- `:unknown` — do not create another Alma payment; recover the first one as described in
  the [Unknown outcome guide](unknown_outcome.md).
- Pass the student's address, phone and birth date: Alma pre-fills them on the checkout.
  Alma still asks for gender, birth country and birth place.

## 4. Alma In-Page in the browser

`origin: "online_in_page"` is mandatory for In-Page. Load the script and start the payment
with the id returned by your server (`docs/integration-in-page.md`):

```html
<script src="https://cdn.jsdelivr.net/npm/@alma/in-page@2.x/dist/index.umd.js"></script>
<div id="alma-in-page"></div>
<script>
  const inPage = Alma.InPage.initialize({
    merchantId: "<payment.merchant_id>",
    amountInCents: 45000,
    installmentsCount: 3,
    selector: "#alma-in-page",
    environment: "TEST",   // "LIVE" in production
    locale: "DE"
  });
  // after your server created the payment:
  inPage.startPayment({ paymentId: "<payment.id>" });
</script>
```

Alma's documentation recommends the floating `@2.x` URL so that bug fixes arrive
automatically. A floating URL cannot carry Subresource Integrity; if your security policy
requires `integrity`/`crossorigin` on third-party scripts, pin an exact `@alma/in-page`
version, compute its hash and update it deliberately.

After a successful payment Alma redirects to `return_url?pid=…` (or calls your
`onPaymentSucceeded` callback); on refusal to `failure_return_url`.

## 5. Confirming the payment — one function for both doors

A redirect and an IPN only tell you *which* payment to look at. Fetch it with the secret
key and decide in one idempotent function:

```elixir
def confirm(alma_payment_id) do
  with {:ok, payment} <- Alma123FS.Payments.fetch(MyApp.Alma.client(), alma_payment_id),
       %{"payment_id" => local_id} <- payment.custom_data,
       local when not is_nil(local) <- MyApp.Payments.get(local_id) do
    cond do
      local.status == :received ->
        :ok

      payment.processing_status in [:authorized, :captured] and
          payment.purchase_amount == local.amount_cents ->
        MyApp.Payments.mark_received(local, payment)

      true ->
        {:not_paid, payment.processing_status}
    end
  else
    _ -> :ignore
  end
end
```

- Check `processing_status` (`:authorized` or `:captured`) and the amount — this is what
  Alma's technical guide prescribes.
- **Do not compare the plan.** If Alma refused the installments and the customer paid
  everything at once, the payment becomes `installments_count: 1`, `kind: "P1X"`. It is a
  valid payment. The requested plan is kept in `payment.raw["requested_products"]`.
- Ignore payments that are not yours (no matching `custom_data`): returning an error for
  them would make Alma retry forever.

### Return URL

```elixir
def alma_return(conn, %{"pid" => pid}) do
  case MyApp.AlmaPayments.confirm(pid) do
    :ok -> redirect(conn, to: ~p"/payment/done")
    _ -> redirect(conn, to: ~p"/payment/pending")
  end
end
```

The IPN arrives about a minute after this redirect, so confirming here gives the student
an immediate answer.

### IPN

Mount `Alma123FS.IPNPlug` in the endpoint **before** `Plug.Parsers`:

```elixir
# lib/my_app_web/endpoint.ex
plug Alma123FS.IPNPlug,
  path: "/webhooks/alma/ipn",
  api_key: {MyApp.Alma, :api_key, []},
  handle: {MyApp.AlmaPayments, :enqueue_confirmation, []}
```

```elixir
def enqueue_confirmation(alma_payment_id) do
  case Oban.insert(MyApp.ConfirmAlmaPaymentJob.new(%{"alma_payment_id" => alma_payment_id})) do
    {:ok, _job} -> :ok
    {:error, _} -> :error
  end
end
```

The Plug answers 401 to calls without a valid `X-Alma-Signature`, 200 when `handle`
returned `:ok`, and 503 otherwise — Alma retries a 503 (observed: one minute later, up to
10 times according to the documentation). Return `:ok` only after the job is stored. The
job calls `confirm/1`. Details in the [IPN guide](ipn.md).

## 6. Abandoned and failed payments

- No IPN is sent for payments that were never paid. Your own cleanup decides when to give
  up: `Alma123FS.Payments.cancel/2` returns `:ok` (also when the payment is already
  canceled) or `{:error, %Error{status: 400}}` once the first installment was collected —
  then the payment is paid and must be confirmed, not replaced.
- A payment expires on its own after `expires_after` minutes (Alma's default is 2880).
- Before creating a second Alma payment for the same local payment, cancel the first.

## 7. Tests

Unit tests stub Alma with `Req.Test` (enabled by `plug: {Req.Test, Alma123FS}` in
`config/test.exs`):

```elixir
test "confirms a captured payment" do
  Req.Test.stub(Alma123FS, fn conn ->
    Req.Test.json(conn, %{
      "id" => "payment_1",
      "processing_status" => "captured",
      "purchase_amount" => 45_000,
      "custom_data" => %{"payment_id" => local.id}
    })
  end)

  assert {:ok, _} = MyApp.AlmaPayments.confirm("payment_1")
end
```

Test the IPN endpoint with a real signature:

```elixir
signature = Alma123FS.IPN.signature("payment_1", "sk_test_fake")

conn =
  build_conn()
  |> put_req_header("x-alma-signature", signature)
  |> get("/webhooks/alma/ipn?pid=payment_1")

assert conn.status == 200
```

Simulate a timeout with `Req.Test.transport_error(conn, :timeout)`: `create/2` then returns
`{:unknown, _}`.

## 8. Before going live

- In the sandbox, use plausible customer data from the merchant's country; with the
  sandbox's own test identity Alma refuses installments. The test card is shown on the
  sandbox checkout page.
- Pay once in installments and once "all at once" and check that both are confirmed.
- Switch `environment: :live` together with the `sk_live_…` key and In-Page
  `environment: "LIVE"`.
