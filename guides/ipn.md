# IPN: signature first, confirmation by fetch

Alma calls `ipn_callback_url` with `?pid=<payment id>` **after a payment was accepted
and its first installment collected** (`reference/webhooks.md`). It retries up to
10 times while the answer is not HTTP 200. No IPN is sent for canceled or expired
payments (inference from the documentation), so the application must also fetch the
payment on `return_url`,
`customer_cancel_url` and in its own cleanup.

## What the signature is

Alma's documentation says the IPN is not signed and recommends fetching the payment.
The official PrestaShop plugin (`alma/controllers/front/ipn.php`) rejects calls
without `X-Alma-Signature` and checks it with
`hash_hmac('sha256', $pid, $apiKey) === $signature` (`ValidateHelper::checkSignature`,
PHP client `RequestHelper::isHmacValidated`). `Alma123FS.IPN.valid_signature?/3`
does the same with a constant-time comparison.

Observed in the sandbox (2026-11-10): the IPN arrived as `GET <ipn_callback_url>?pid=…`
about one minute after the customer was redirected to `return_url?pid=…`, with
`User-Agent: Alma/None:None` and an `X-Alma-Signature` equal to the lowercase hex
HMAC-SHA256 of the pid keyed with the sandbox API key. The redirect to `return_url`
carries no signature.

RegistrationService depends on this header exactly as much as Alma's own PrestaShop
plugin does: its `ipn.php` refuses an IPN without `X-Alma-Signature`, while its
`validation.php` (the `return_url` handler) confirms the payment by fetching it, with no
signature. Use the same two paths: `Alma123FS.IPNPlug` for the IPN, and a `fetch/2` on
`return_url?pid=…`. The second path also gives the customer an immediate answer — the
IPN came about a minute after the redirect.

Retries were observed once: after a 503 the next IPN came 60 s later (the guide says
"within 30 seconds"), and a 200 stopped them. Answering 503 while the follow-up cannot
be stored is therefore safe; the same `pid` will come again.

The signature only stops anonymous calls from triggering work. The `pid` is not secret,
and the call says nothing about amount or status. Never mark a payment as paid in the
IPN handler.

## Mounting

Mount the Plug in the endpoint before `Plug.Parsers`, next to other provider callbacks:

```elixir
plug Alma123FS.IPNPlug,
  path: "/webhooks/alma/ipn",
  api_key: {MyApp.Alma, :api_key, []},
  handle: {MyApp.Alma, :enqueue_confirmation, []}
```

Use an MFA for `:api_key`: Phoenix runs `init/1` at compile time, a literal key would
end up in the compiled module. The key must be the one of the environment that
created the payment.

| Response | When |
|---|---|
| 200 | signature valid and `handle` returned `:ok` |
| 503 | `handle` returned anything else (Alma retries) |
| 401 | `X-Alma-Signature` missing, repeated or wrong |
| 400 | `pid` missing or not an Alma id |
| 405 | method other than GET/POST |

`handle` receives the payment id. Return `:ok` only once the follow-up is durably
stored (for example after `Oban.insert/1` committed):

```elixir
def enqueue_confirmation(payment_id) do
  case Oban.insert(ConfirmAlmaPaymentJob.new(%{alma_payment_id: payment_id})) do
    {:ok, _job} -> :ok
    {:error, _} -> :error
  end
end
```

## Confirmation

The job fetches the payment with the secret key and decides:

```elixir
{:ok, payment} = Alma123FS.Payments.fetch(client, alma_payment_id)

with %Alma123FS.Payment{processing_status: status} when status in [:authorized, :captured] <- payment,
     true <- payment.purchase_amount == expected_amount,
     %{"payment_id" => ^our_payment_id} <- payment.custom_data do
  # record the payment as received
end
```

Alma's technical guide (`docs/custom-integration-technical-guide.md`) asks for exactly
these checks: `processing_status` `authorized` **or** `captured`, and `purchase_amount`
equal to the cart. With `capture_method: "automatic"` the sandbox reported `captured`.

Do not require the plan to match the request. In the sandbox Alma declined the
3-installment plan and offered the customer to pay the full amount at once
(`reference/payment.md`: even a `scored_no` payment "can finally be paid at once"):
the paid payment had `state: "paid"`, `installments_count: 1`, `kind: "P1X"` and a
single installment `paid: 45000` instead of three. The requested plan is kept only in
the undocumented `payment.raw["requested_products"]`; use it for reporting if needed,
not for accepting the payment. Comparing
`installments_count` or `payment_plan` with the requested plan would reject a valid
payment.

Unknown ids (not created by this application) must be ignored, not retried forever.
`processing_status: :unknown` means Alma sent a value this library does not know;
keep the payment open and look at `payment.raw`.
