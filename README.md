# Alma123FS

A small Elixir client for the [Alma](https://docs.almapay.com/) API, built on Req.
It covers what RegistrationService needs for Alma installments: eligibility, payments
(create, fetch, cancel, list), the IPN signature and the beta webhooks helpers.
There is no official Elixir client; the reference implementation is the official
[PHP client](https://github.com/alma/alma-php-client).

Independent of Phoenix, Ecto and RegistrationService. Elixir 1.18+, Req 0.7, Jason.
Plug is optional and only needed for `Alma123FS.IPNPlug`.

**Where to read what**

| You want to | Read |
|---|---|
| add the package and make the first call | [Installation](#installation), [Configuration](#configuration), [Quick start](#quick-start) |
| integrate the whole payment flow into a Phoenix app | [Integration guide](guides/integration.md) |
| receive and confirm IPN callbacks | [IPN guide](guides/ipn.md) |
| handle a timeout while creating a payment | [Unknown outcome](guides/unknown_outcome.md) |
| update to a newer version | [Versions and upgrading](#versions-and-upgrading), [CHANGELOG](CHANGELOG.md) |
| know what Alma really does (vs its documentation) | [Verified in the sandbox](#verified-in-the-sandbox) |
| change or release the package | [CONTRIBUTING](CONTRIBUTING.md) |

## Installation

The package is not on Hex. Add it from GitHub, pinned to a release tag:

```elixir
# mix.exs
defp deps do
  [
    {:alma_123fs_ex, github: "123fahrschule/alma_123fs_ex", tag: "0.1.0"}
  ]
end
```

```bash
mix deps.get
```

Plug comes with Phoenix; without Plug everything except `Alma123FS.IPNPlug` works. If you
add Plug to an application that already compiled this package, recompile it once with
`mix deps.compile alma_123fs_ex --force` so that `Alma123FS.IPNPlug` becomes available.

## Configuration

The API key and the environment always come from the caller. There is no default
environment.

```elixir
client = Alma123FS.Client.new(
  api_key: System.fetch_env!("ALMA_API_KEY"),
  environment: :sandbox,          # or :live
  receive_timeout: 30_000,        # default
  connect_timeout: 10_000         # default
)
```

or, reading `config :alma_123fs_ex, …` at call time:

```elixir
# config/runtime.exs
config :alma_123fs_ex, api_key: System.fetch_env!("ALMA_API_KEY"), environment: :live

# config/test.exs
config :alma_123fs_ex, api_key: "sk_test_fake", environment: :sandbox, plug: {Req.Test, Alma123FS}

client = Alma123FS.client()
```

| Environment | Host | Key prefix |
|---|---|---|
| `:live` | `https://api.getalma.eu` | `sk_live_` |
| `:sandbox` | `https://api.sandbox.getalma.eu` | `sk_test_` |

Keys are in the Alma dashboard under "Paramètres → Configuration d'API" (sandbox:
`dashboard.sandbox.getalma.eu`). Keep them in environment variables, never in code.

A key whose prefix contradicts the environment raises. Every request sends
`Authorization: Alma-Auth <api_key>`. The key is never stored in the Req template,
`Inspect` hides it, errors never contain it, and the library does not log.
Requests never retry and never follow redirects.

## Quick start

```elixir
client = Alma123FS.client()

# 1. Which plans does Alma offer for 450 €?
{:ok, plans} = Alma123FS.Eligibility.check(client, 45_000, installments_counts: [3, 4])

# 2. Create the payment (persist your own record first, see the integration guide).
{:ok, payment} =
  Alma123FS.Payments.create(client, %{
    payment: %{
      purchase_amount: 45_000,
      installments_count: 3,
      origin: "online_in_page",
      ipn_callback_url: "https://app.example/webhooks/alma/ipn",
      return_url: "https://app.example/payment/alma/return",
      custom_data: %{"payment_id" => our_payment_id}
    },
    order: %{merchant_reference: our_payment_id}
  })

# 3. The browser opens Alma In-Page with payment.id and payment.merchant_id.
# 4. On return_url?pid=… and on the IPN: confirm with fetch, never trust the callback itself.
{:ok, %Alma123FS.Payment{processing_status: status, purchase_amount: 45_000}} =
  Alma123FS.Payments.fetch(client, payment.id)

paid? = status in [:authorized, :captured]
```

## Results and errors

Every function returns one of:

- `{:ok, value}` or `:ok` — Alma answered 2xx with the documented shape.
- `{:error, %Alma123FS.Error{}}` — rejected locally (`kind: :validation`) or by Alma
  (`kind: :api`, 4xx except 408), or a read that failed.
- `{:unknown, %Alma123FS.Error{}}` — **only for state-changing calls**: no reliable answer
  (timeout, closed connection, HTTP 5xx or 408, unreadable 2xx). The change may have
  happened.

Invalid options or arguments of the wrong shape (an unknown option key, a non-keyword
list) are programmer errors and raise `ArgumentError`; the message names the keys but
never echoes values, so the API key cannot leak through it.

`%Alma123FS.Error{}` always has the same fields: `kind` (`:validation | :api | :transport | :protocol`),
`status` (HTTP status or `nil`), `type` (fixed atom: `:bad_request`, `:unauthorized`,
`:not_found`, `:rate_limited`, `:server_error`, `:transport`, …), `code` (Alma's
`"error_code"`, e.g. `"validation_error"`), `message` (Alma's `"message"`), `reason`
(transport reason atom), `body`.

`POST /v1/payments` has **no idempotency key** — neither in Alma's documentation nor in
the PHP client. After `{:unknown, _}` from `Payments.create/2` a payment may exist and a
new attempt may create a second one. See [Unknown outcome](guides/unknown_outcome.md).

Amounts are integer cents everywhere. Timestamps are `DateTime`.

## Eligibility

```elixir
{:ok, plans} = Alma123FS.Eligibility.check(client, 45_000, installments_counts: Enum.to_list(2..12))

for %Alma123FS.Eligibility{eligible: true} = plan <- plans do
  {plan.installments_count, plan.total_amount, plan.customer_total_cost_amount, plan.payment_plan}
end
```

`POST /v2/payments/eligibility`. Each result carries the schedule (`due_date`,
`purchase_amount`, `customer_fee`, `customer_interest`, `total_amount` per installment),
the customer's total cost and the computed total. Ineligible results carry `reasons`
and `constraints` (for example the minimum and maximum amount).

## Payments

```elixir
{:ok, payment} =
  Alma123FS.Payments.create(client, %{
    payment: %{
      purchase_amount: 45_000,
      installments_count: 3,
      origin: "online_in_page",
      expires_after: 60,
      locale: "de",
      ipn_callback_url: "https://rs.example/webhooks/alma/ipn",
      return_url: "https://rs.example/payment/alma/return",
      customer_cancel_url: "https://rs.example/payment/alma/cancel",
      failure_return_url: "https://rs.example/payment/alma/failure",
      custom_data: %{"payment_id" => our_payment_id}
    },
    customer: %{first_name: "Erika", last_name: "Mustermann", email: "erika@example.com"},
    order: %{merchant_reference: our_payment_id}
  })

# The browser opens In-Page with payment.id (Alma.InPage … startPayment({paymentId})).

# The authoritative state:
{:ok, %Alma123FS.Payment{processing_status: status}} = Alma123FS.Payments.fetch(client, payment.id)

# Give up an unpaid payment (400 once the first installment is collected):
:ok = Alma123FS.Payments.cancel(client, payment.id)

# Search, newest first; follow has_more with starting_after:
{:ok, %{payments: payments, has_more: more}} =
  Alma123FS.Payments.list(client, created_after: started_at, limit: 100)
```

`Alma123FS.Payment` exposes `id`, `url`, `processing_status`, `cancelation_reason`,
`expired_at`, `purchase_amount`, `installments_count`, `capture_method`, `payment_plan`,
`custom_data`, `orders`, `merchant_id`, `customer_fee`, `customer_interest`, `fees` and
the full response in `raw`. Statuses are atoms with an explicit mapping; unknown values
become `:unknown`, they never fail the parse.

Locally validated before sending: `purchase_amount` (positive integer) and
`installments_count` (1–12) are required (Alma would silently default the count to 3);
`capture_method` is `automatic`/`manual`; `expires_after` positive; callback URLs
absolute http(s); `custom_data`, addresses, `cart`, `customer`, `order` are maps; only
`payment`, `customer` and `order` are accepted at the top level; the body must be
JSON-encodable; ids used in paths match `[A-Za-z0-9_-]{1,128}`. Pass the customer's
address, phone and birth date when you have them: Alma pre-fills them on its checkout.

A created payment is not a paid payment. A redirect to `return_url`, an IPN call or a
webhook is not a confirmation either. **Confirm only with `fetch/2`**: `processing_status`
`:authorized` or `:captured` (Alma's technical guide), `purchase_amount` and your
`custom_data`. Do not compare the plan with the request: Alma may decline installments
and let the customer pay everything at once.

## IPN

```elixir
# endpoint.ex, before Plug.Parsers
plug Alma123FS.IPNPlug,
  path: "/webhooks/alma/ipn",
  api_key: {MyApp.Alma, :api_key, []},
  handle: {MyApp.Alma, :enqueue_confirmation, []}
```

`X-Alma-Signature` = lowercase hex HMAC-SHA256(`pid`, API key), compared in constant
time; missing or wrong signature → 401. Alma's documentation says the IPN is unsigned;
the signature comes from the official PrestaShop plugin and the PHP client, and a real
sandbox IPN carried it. It is a first filter only. See the [IPN guide](guides/ipn.md).

## Beta webhooks

`Alma123FS.Webhooks.create/3`, `fetch/2`, `delete/2` (`/v1/webhooks`),
`Alma123FS.Webhook.verify_signature/4` (exactly as the PHP `WebhookHelper::verifySignature`)
and `Alma123FS.Webhook.parse_event/1`. No Plug: it is not known what the signature
covers. See [Beta webhooks](guides/webhooks_beta.md).

## Versions and upgrading

Versions follow [Semantic Versioning](https://semver.org/). Each release is a Git tag equal
to the version in `mix.exs` (`0.1.0`, no `v` prefix), described in [CHANGELOG.md](CHANGELOG.md).
Published tags are never moved.

Before 1.0:

| Change | Example | May break your code? |
|---|---|---|
| patch | `0.1.0` → `0.1.1` | no: fixes only |
| minor | `0.1.x` → `0.2.0` | **yes**: read the **Upgrading** notes in the CHANGELOG |

To upgrade an application:

1. Read the CHANGELOG entries between your version and the new one.
2. Change the tag in `mix.exs`, e.g. `tag: "0.1.0"` → `tag: "0.2.0"`.
3. Run `mix deps.update alma_123fs_ex` — this updates `mix.lock` to the commit of the new
   tag; commit both files.
4. Apply the Upgrading notes, then run `mix compile --warnings-as-errors` and your tests.

To see which version an application uses: `mix deps | grep alma_123fs_ex`, or the tag in
its `mix.exs`. The library also sends it in the `User-Agent` (`alma_123fs_ex/0.1.0`).

## Out of scope

Refunds, captures for `capture_method: "manual"` (`POST /v1/payments/{id}/captures`,
7-day window), payment edits, orders endpoints, data exports, balance transactions,
share of checkout, merchant business events, configuration and everything under the PHP
client's `src/Plugin`.

## Documentation vs PHP client

Where the sources disagree, this library does not choose silently; the choice is listed.

- **Eligibility endpoint.** Docs: two pages — `verifier-leligibilite-dun-achat` (v1,
  `{"payment": {…}}`) is marked obsolete, `verifier-eligibilite-achat` is v2 (`queries`).
  PHP: `POST /v2/payments/eligibility`. Here: v2 only.
- **Base URL.** Docs: `https://api.getalma.eu/v1/` (and `/v2/` on the eligibility page).
  PHP: host only, paths carry `/v1` or `/v2`. Here: host only, versioned paths.
- **Cancel method.** Docs: `POST /v1/payments/{id}/cancel`. PHP: `PUT`. Here: `POST`,
  confirmed in the sandbox.
- **`cancelation_reason`.** Docs: 4 values. PHP: adds `declined`. Here: all 5 mapped.
- **Eligibility `origin`.** Docs: `online`, `pos`. PHP: `online`, `online_in_page`. Here:
  the string is forwarded unchanged.
- **Eligibility response.** Docs: the example has no `customer_fee`, `customer_interest`,
  `annual_interest_rate`. PHP: `customer_fee` and `annual_interest_rate` are required when
  eligible. Here: all optional (`nil`).
- **IPN signature.** Docs: "the webhook is not signed". PHP: `X-Alma-Signature` is checked
  (PrestaShop `ipn.php`, `RequestHelper::isHmacValidated`). Here: checked; the header is
  present and valid in the sandbox.
- **IPN method.** Docs: `GET` with `?pid=`. PHP: PrestaShop reads `pid` from GET or POST.
  Here: GET and POST, `pid` from the query string; the sandbox sent `GET`.
- **`/v1/webhooks`.** Docs: not in the reference; beta webhooks are enabled by e-mail.
  PHP: `WebhookEndpoint` create/fetch/delete, tests use type `ecommerce_report` and a
  response without a secret. Here: implemented as in PHP, returns raw maps.
- **`custom_data`.** Docs: the create schema says `string`, the description says JSON
  object. PHP: `array`. Here: must be a map.
- **`cart.items[].picture_url`.** Docs: required in the create schema. PHP: optional in
  `CartItemDto`. Here: not validated.
- **Payment required fields.** Docs: the list endpoint returns a subset. PHP: the entity
  requires about 16 fields. Here: only `id` is required.

Documentation-internal ambiguity: the list format page describes `starting_after` as the
lexicographic **minimum** id while lists are newest first. In the sandbox it behaves as a
plain cursor: the next page continues with older payments.

## Verified in the sandbox

Checked on 2026-11-10 with the sandbox tests in `integration/` and with one-off scripts
(manual payments with the sandbox test card):

1. Host-level base URL, `Authorization: Alma-Auth <key>`, `POST /v2/payments/eligibility`
   with `queries` (one result per requested plan, same order, 2–12).
2. `POST /v1/payments` returns the full payment object, `processing_status:
   "awaiting_authorization"`; `GET /v1/payments/{id}` returns `custom_data` unchanged.
3. `GET /v1/payments` uses the `{"data": […], "has_more": …}` envelope and filters by
   `created_after` (POSIX seconds). List items also carry `processing_status` and
   `cancelation_reason` (not in the documented field table) but no `custom_data`.
4. Cancel is `POST /v1/payments/{id}/cancel` (as documented; the PHP client's `PUT`
   is wrong) and answers 204; the payment becomes `canceled` with
   `cancelation_reason: requested_by_merchant`. Canceling it **again** also answers 204.
5. Error bodies carry `"message"`: unknown payment → 404
   `"Payment … not found"`.
6. An invalid key answers **403** `"Unauthorized access"`, not the documented 401.
7. A customer email on a non-existent domain (`…@example.test`) is dropped silently
   (`customer.email: nil`, first and last name kept), so `customer_email` cannot find
   the payment. An `…@example.com` email is stored and `customer_email` (substring)
   finds it.
8. With a wrong key, `GET /v1/payments/{unknown id}` answered **404**, not 403: a 404 from
   `fetch/2` does not prove that the payment is absent (wrong key or environment).

A paid sandbox payment (test card shown on the sandbox checkout page,
`checkout.sandbox.getalma.eu`) confirmed the rest of the flow:

9. The IPN is `GET <ipn_callback_url>?pid=…`, about one minute after the redirect to
   `return_url?pid=…`, with `User-Agent: Alma/None:None` and `X-Alma-Signature` equal to
   lowercase hex HMAC-SHA256(pid, API key). `Alma123FS.IPNPlug` accepted it with 200 and
   Alma did not retry. The redirect carries no signature.
10. After the IPN the payment was `processing_status: "captured"`, `state: "paid"`.
    Alma had declined the 3-installment plan and the customer paid 450 € at once
    (dashboard history: "Scored payment - refused", then "Scored payment - accepted").
    The payment itself changed: `installments_count: 1`, `kind: "P1X"`, a single
    installment `paid: 45000`. The original request survives only in the undocumented
    `raw["requested_products"]` (`[%{"installments_count" => 3, "deferred_days" => 0}]`).
    Neither the API nor the dashboard gives a reason for the refusal. The billing address
    and phone entered on the sandbox checkout were Egyptian/Polish test data, and the
    payment reported `country_of_service: "FR"` and `transaction_country: "FR"`.
11. Canceling the paid payment answers 400 `"Le statut de ce paiement ne permet pas de
    l'annuler"`.
12. The same payment created with a plausible German customer (`billing_address`,
    `shipping_address` in DE, `+49` phone, `customer.birth_date`) was approved in 3
    installments: `processing_status: "captured"`, `state: "in_progress"`,
    `installments_count: 3`, `kind: "P3X"`, plan `paid 15000` today and two `pending
    15000`. The refusal above was therefore most likely caused by the sandbox's own test
    customer data (inference from this experiment, not an explanation from Alma).
    Data passed at creation is pre-filled on the checkout; Alma still asks for gender,
    birth country and birth place. `country_of_service` followed the billing country
    (`DE` here, `FR` before); `transaction_country` was `FR` in both payments.

`GET /v1/payments` in the sandbox (read-only checks):

13. Newest first, by `created` and by id; `starting_after: <last id>` returns the next,
    older page.
14. `state` accepts a comma-separated list (union) and these values, listed by Alma's own
    422: `not_ready`, `not_started`, `scored_no`, `scored_maybe`, `scored_yes`,
    `in_progress`, `paid`, `late`, `default` (`in_progress`, `late`, `default` are not in
    the documented filter list). The `__not__` prefix promised by the generic
    "Énumérations" page is rejected with 422 `error_code: "validation_error"`.
15. Canceled payments keep the legacy `state: "not_started"` (the dashboard shows them as
    "Expired"); only `processing_status` says `canceled`.

IPN for an approved installment payment, first IPN answered 503 on purpose:

16. The IPN arrived 68 s after the redirect, signed as above. After the 503 Alma retried
    **60 s** later (the technical guide says "within 30 seconds"); the 200 ended the
    retries. At that point the payment was `captured`, `state: "in_progress"`, `P3X`,
    plan `paid 15000`, `pending 15000`, `pending 15000`.
17. Canceling after the first installment answers 400 with the same message as for a
    fully paid payment; that 400 body has no `error_code`.

## Unverified assumptions

There is no contact with Alma: what the sandbox or its dashboard cannot show stays an
open risk, and the code tolerates it.

1. HTTP 5xx or 408 on create may have created a payment (treated as `{:unknown, _}`).
2. The spacing of later IPN retries (only the first retry was observed) and what happens
   after the 10th failed attempt.
3. Why `transaction_country` is `FR` for a German merchant, with 20 % tax on the
   merchant fee (French VAT rate): possibly the account's company settings — check the
   sandbox dashboard.
4. Beta webhooks: whether `verify_signature/4` applies to them, where `secret` comes from
   (the PHP create response has none), the envelope field holding the event code
   (`"type"` and `"event"` are tried), retries, and whether `POST /v1/webhooks`
   accepts `payment.*` types.
5. Limits of `expires_after` and `installments_count` per account.

## Development

Checks, test rules and the release procedure are in [CONTRIBUTING.md](CONTRIBUTING.md).

Sandbox tests live in `integration/` and are excluded from `mix test`. They are
skipped unless `ALMA_API_KEY` holds a sandbox key:

```bash
ALMA_API_KEY=sk_test_… mix test --only integration
```

They create three sandbox payments and cancel each of them, also when a test fails.

## Sources

Checked 2026-11-10: [docs.almapay.com](https://docs.almapay.com/llms.txt) reference pages
listed in `test/fixtures/README.md`, `alma/alma-php-client` at
`28f6f8f0cb285223555568c57b293035214012f2`, `alma/alma-installments-prestashop` at
`632c0dae360a25d90acc2a13c7627415251d85e5`.
