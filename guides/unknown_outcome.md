# Unknown outcome: `POST /v1/payments` without an idempotency key

Adyen deduplicates retries by `Idempotency-Key`. Alma's `POST /v1/payments` has no such
key: neither the documentation (`reference/creer-un-payment.md`) nor the PHP client
(`PaymentEndpoint::create`) mention one. A retry after a timeout can create a second
payment.

`Alma123FS.Payments.create/2` therefore distinguishes three results:

- `{:ok, payment}` — created; `payment.id` is known.
- `{:error, %Error{kind: :validation}}` or `{:error, %Error{kind: :api}}` (4xx except
  408) — not created.
- `{:unknown, error}` (timeout, closed connection, HTTP 5xx or 408, unreadable 2xx) —
  maybe created.

`cancel/2`, `Webhooks.create/3` and `Webhooks.delete/2` use the same `{:unknown, _}`
result. Read-only calls (`fetch`, `list`, eligibility) return transport failures as
`{:error, _}`: nothing changed.

## Making the lost payment findable

Before calling `create/2`, persist your own payment record and put its id where
`list/2` can see it:

* `payment.custom_data` — `%{"payment_id" => our_payment_id}`;
* `order.merchant_reference` — `our_payment_id`.

Also record the time just before the request: the search relies on `created_after`.

Do not rely on `customer_email`. In the sandbox (2026-11-10) a payment created with
`customer.email: "…@example.test"` came back with `customer.email: nil` (first and last
name were kept), so the email filter found nothing. When an email is stored, Alma matches
every email that *contains* the value, so `custom_data` must be compared anyway.

## After `{:unknown, _}`

1. Keep the local payment open; do not create a new Alma payment yet.
2. Search:

   ```elixir
   Alma123FS.Payments.list(client,
     created_after: DateTime.add(requested_at, -60),
     created_before: DateTime.add(requested_at, 300),
     limit: 100
   )
   ```

   Follow `has_more` with `starting_after`. List items carry no `custom_data`
   (observed in the sandbox), so `fetch/2` each candidate and match
   `custom_data["payment_id"]` (or `orders[].merchant_reference`).
3. Found: continue with that payment (or cancel it before starting again).
   Not found: the payment may not be visible yet; search again later. Its lifetime is
   `expires_after` minutes (Alma's default 2880).
4. Before creating a replacement, cancel every earlier Alma payment of the same
   local payment. Repeating a cancelation is safe: an already canceled payment answers
   204 again (observed in the sandbox). `cancel/2` returns HTTP 400 once the first
   installment was collected (observed in the sandbox): that payment is paid, so do
   not create another one.

A lost payment cannot be paid by the customer anyway: In-Page opens by payment id, and
the id was never received (inference, unverified in sandbox).
