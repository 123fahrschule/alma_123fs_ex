# Fixture provenance

Sources were retrieved on 2026-11-10. No test computes its expected signature with
the implementation under test.

| Fixture | Source |
|---|---|
| `eligibility_v2_response.json` | `reference/verifier-eligibilite-achat.md`, OpenAPI example of `POST /payments/eligibility` (200), verbatim |
| `eligibility_ineligible_php.json` | PHP client `tests/Client/Unit/Application/Endpoint/EligibilityEndpointTest.php`, `SERVER_REQUEST_NO_ELIGIBILITY_RESPONSE_JSON` |
| `payment_php.json` | PHP client `tests/Client/Unit/Application/Endpoint/PaymentEndpointTest.php`, `SERVER_REQUEST_RESPONSE_JSON` |
| `payment_canceled_constructed.json` | **constructed** from the field table of `reference/payment.md` (the page has no JSON example); values are invented |
| `payments_list_constructed.json` | **constructed** from `reference/recuperer-une-liste-de-payments.md` (fields) and `reference/format-des-donnees.md` (`data`/`has_more` envelope) |
| `cancel_400.json` | `reference/cancel-a-payment.md`, OpenAPI example of the 400 response |
| `order_docs.json` | `reference/order.md`, JSON example |
| `webhook_create_php.json` | PHP client `tests/Client/Unit/Application/Endpoint/WebhookEndpointTest.php`, `CREATE_WEBHOOK_RESPONSE_JSON` |
| `list_state_422_sandbox.json` | **sandbox response** (2026-11-10) to `GET /v1/payments?state=__not__paid`, verbatim |
| `api_contract.json` | methods and paths extracted by hand from the pages and PHP classes named in each entry |

PHP client: `alma/alma-php-client` at `28f6f8f0cb285223555568c57b293035214012f2`.
PrestaShop plugin: `alma/alma-installments-prestashop` at
`632c0dae360a25d90acc2a13c7627415251d85e5`.

SHA-256 of the documentation pages as downloaded (`https://docs.almapay.com/<page>.md`):

```
a667436bc99732622532ae68b32a38416a1449f96de9d6749fe0929869944241  reference/verifier-eligibilite-achat
8ca5f61e0acae1aad2c7ac04d22b43abc12d359e518c1c39cb5ba2af6a8e7154  reference/verifier-leligibilite-dun-achat
e57adba401e9dd17fe25378b82d474a1b182f12a82116dcc921a72cc559ecdbc  reference/creer-un-payment
17552c22a806b02badfb8c2853711bd3f301895079eb718bf818bb5983cbb43c  reference/payment
d14308f678c3856850e9f9e94c6bfb405c5e139b1fd7ae5bbe4fae054fa224b3  reference/cancel-a-payment
94715db263248623923540d93eaa7116c11c05fbf9597c5db89311a7419e9f21  reference/recuperer-une-liste-de-payments
f5ebab78838bf9aa9ea23b02cc5aca338e516ff24a69f20a8e2def5dbd7179e6  reference/recuperer-un-payment
bf5167ba64e77afb7ee266428009a86235c396cff437b68e5d188f7bf8735cd2  reference/order
57db18dd8ee0d02d5a029bda271e95b48d1a0eb3ff9de16dd8c3ea29794b7002  reference/authentification
447f2d402ce66e41d9b6e1432f820c0b0b83369003977fe9e07ea3b72ba85ce4  reference/webhooks
40be7fe9f8aa4e3f16d8eee1b59283a92e41a98cfe14788868f6254479c72f1e  reference/format-des-donnees
bac28e8f36a5681e154609a09aeaf68041a241215799108a8c0463b94898443d  reference/v10
7cb6f4fdbc9cdd1443565094899a2aef5c7a8c13462f3b1f62211a1b43b903de  docs/integration-in-page
```

## Signature vectors

* IPN: `0dd3cb46…b7b4b0` for (`merchant_id_test`, `api_key_test`) is taken from the PHP
  client's `tests/Client/Unit/Application/Helper/RequestTest.php`. `b44933e7…d63044` for
  (`payment_11uPRjP4a3cFQvoM1lehDnpxa2tYm2Hy0I`, `sk_test_fake_key`) was computed with
  Python `hmac.new(key, pid, sha256).hexdigest()`.
* Webhooks: the five scenarios of PHP `tests/Client/Unit/Application/Endpoint/Entity/WebhookTest.php`
  are copied unchanged. The extra vectors (`a b/é~*` with and without URL encoding, the
  empty parameter set) were computed with Python `urllib.parse.quote(value, safe="-_.~")`
  (equivalent to PHP `rawurlencode`), `hmac` and `base64.urlsafe_b64encode` without `=`.
