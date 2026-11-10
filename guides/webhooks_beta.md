# Beta webhooks

## What Alma documents

`reference/webhooks.md` (updated 2026-05-18): a new webhook system is in beta and
replaces the IPN. It is enabled by writing to squad-integrations@getalma.eu. It sends
four events — `payment.created`, `payment.authorized`, `payment.captured`,
`payment.canceled` — as `POST` requests "with a structured envelope and an event code",
almost instantly instead of the IPN's ~60 seconds.

Not documented: the envelope format, the field that holds the event code, the signature,
the signing secret and the retry policy.

## What the PHP client has

* `WebhookEndpoint`: `POST /v1/webhooks` (`type`, `url`), `GET /v1/webhooks/{id}`,
  `DELETE /v1/webhooks/{id}`. Its tests use the type `ecommerce_report` and a create
  response with `id`, `type`, `url` — no secret.
* `WebhookHelper::verifySignature($signature, $params, $secret, $urlEncode = true)`:
  sort parameters (all but `signature`) by name, `rawurlencode` each value, join as
  `name=value` with `&`, HMAC-SHA256 with `$secret`, base64url without `=`,
  `hash_equals`.

That helper signs a parameter set, which fits callbacks with query parameters better
than a JSON `POST`. It may belong to an older mechanism.

## What this library provides

* `Alma123FS.Webhooks.create/3`, `fetch/2`, `delete/2` — the PHP endpoints, responses
  as decoded maps.
* `Alma123FS.Webhook.verify_signature/4` — byte-for-byte the PHP algorithm; the PHP
  `WebhookTest` scenarios give the same results.
* `Alma123FS.Webhook.parse_event/1` — reads the event code from `"type"`, else
  `"event"`, maps the four documented codes to atoms, anything else to `:unknown`,
  and keeps the payload map.
* No Plug: what to verify (body? which parameters? which header?) cannot be determined
  from the sources.

## Before using them

RegistrationService uses the classic IPN. The beta webhooks are enabled only on request
by e-mail to Alma, and the team has no contact with Alma, so they are not available.
If they ever are, capture real deliveries in the sandbox first (as was done for the
IPN): the envelope, the signature header and what it signs, and the retries. Then add a
Plug that verifies the raw body before `Plug.Parsers`, like `Alma123FS.IPNPlug`, and keep
confirming payments with `Alma123FS.Payments.fetch/2`.
