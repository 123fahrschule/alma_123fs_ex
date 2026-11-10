defmodule Alma123FS.IPN do
  @moduledoc """
  Signature check for Alma's IPN ("Instant Payment Notification") callback.

  Alma calls `ipn_callback_url` with `?pid=<payment id>` after a payment succeeds and
  retries up to 10 times until it receives HTTP 200 (`reference/webhooks.md`).
  The documentation says the callback **is not signed**. The official PrestaShop plugin
  (`alma/controllers/front/ipn.php`, `alma/lib/Helpers/ValidateHelper.php`) and the PHP
  client (`RequestHelper::isHmacValidated`) nevertheless check the `X-Alma-Signature`
  header as `hash_hmac('sha256', pid, api_key) === signature`: lowercase hex HMAC-SHA256
  of the payment id, keyed with the merchant's API key. This module reproduces that
  check with a constant-time comparison. Confirmed in the sandbox on 2026-11-10: a real
  IPN (`GET`, `User-Agent: Alma/None:None`) carried exactly this signature.

  The signature is only a first filter against anonymous calls. It is **not** a payment
  confirmation: confirm with `Alma123FS.Payments.fetch/2` using the secret key, and
  check `processing_status` (`:authorized` or `:captured`), amount and your own
  `custom_data`/order reference.
  """

  @header "x-alma-signature"

  @doc "The lowercase request header name: `x-alma-signature`."
  @spec header() :: String.t()
  def header, do: @header

  @doc """
  Expected signature for a payment id: lowercase hex HMAC-SHA256(payment_id, api_key).
  """
  @spec signature(String.t(), String.t()) :: String.t()
  def signature(payment_id, api_key) when is_binary(payment_id) and is_binary(api_key) do
    :hmac |> :crypto.mac(:sha256, api_key, payment_id) |> Base.encode16(case: :lower)
  end

  @doc """
  Whether `signature` equals the expected signature, compared in constant time.

  Like the PHP check, the comparison is exact (an uppercase hex string does not match).
  Empty or non-string arguments return `false`.
  """
  @spec valid_signature?(term(), term(), term()) :: boolean()
  def valid_signature?(payment_id, api_key, signature)
      when is_binary(payment_id) and payment_id != "" and is_binary(api_key) and api_key != "" and
             is_binary(signature) do
    expected = signature(payment_id, api_key)
    byte_size(signature) == byte_size(expected) and :crypto.hash_equals(expected, signature)
  end

  def valid_signature?(_, _, _), do: false
end
