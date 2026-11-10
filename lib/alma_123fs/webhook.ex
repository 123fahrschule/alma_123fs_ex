defmodule Alma123FS.Webhook do
  @moduledoc """
  Signature verification and event parsing for Alma's beta webhooks. **Unverified.**

  Alma documents (`reference/webhooks.md`) that the beta webhooks replace the IPN,
  are enabled by e-mail to squad-integrations@getalma.eu, emit `payment.created`,
  `payment.authorized`, `payment.captured` and `payment.canceled`, and arrive as
  `POST` requests with an envelope and an event code. The envelope format, the
  signature and the retry policy are **not documented**.

  `verify_signature/4` reproduces the PHP client's
  `WebhookHelper::verifySignature($signature, $params, $secret, $urlEncode = true)`
  exactly. It is not known whether that signature applies to the beta `POST` events or
  to an older mechanism with query parameters, nor where `secret` comes from. For this
  reason the library ships no webhook Plug. See the "Beta webhooks" guide.
  """

  defmodule Event do
    @moduledoc """
    A parsed beta webhook event: `type` as an atom (`:unknown` for anything not listed
    in `Alma123FS.Webhook.event_types/0`), `raw_type` as received, and the original
    decoded `payload`.
    """
    defstruct [:type, :raw_type, payload: %{}]

    @type t :: %__MODULE__{
            type: Alma123FS.Webhook.event_type(),
            raw_type: String.t() | nil,
            payload: map()
          }
  end

  @event_types %{
    "payment.created" => :payment_created,
    "payment.authorized" => :payment_authorized,
    "payment.captured" => :payment_captured,
    "payment.canceled" => :payment_canceled
  }

  @type event_type ::
          :payment_created
          | :payment_authorized
          | :payment_captured
          | :payment_canceled
          | :unknown

  @doc "The documented event codes and their atoms."
  @spec event_types() :: %{String.t() => event_type()}
  def event_types, do: @event_types

  @doc """
  Verify a signature exactly as the PHP client does.

  Parameters (all except `signature`) are sorted by name, each value is
  `rawurlencode`d (RFC 3986: everything except `A-Z a-z 0-9 - _ . ~`) unless
  `url_encode: false`, joined as `name=value` with `&`, signed with HMAC-SHA256 keyed
  by `secret`, and encoded as base64url without padding. The comparison is
  constant-time. Values may be strings, integers, booleans (`true` → `"1"`,
  `false` → `""`, like PHP) or `nil` (`""`); anything else returns `false`.
  """
  @spec verify_signature(term(), term(), term(), keyword()) :: boolean()
  def verify_signature(signature, params, secret, options \\ [])

  def verify_signature(signature, params, secret, options)
      when is_binary(signature) and is_map(params) and is_binary(secret) do
    url_encode = Keyword.get(options, :url_encode, true)

    case canonical(params, url_encode) do
      {:ok, data} ->
        expected =
          :hmac |> :crypto.mac(:sha256, secret, data) |> Base.url_encode64(padding: false)

        byte_size(signature) == byte_size(expected) and :crypto.hash_equals(expected, signature)

      :error ->
        false
    end
  end

  def verify_signature(_, _, _, _), do: false

  @doc """
  Parse a beta webhook body (a JSON string or an already decoded map).

  The event code is looked up in `"type"` and `"event"` — an assumption, since the
  envelope is undocumented. A documented code in either field wins; otherwise
  `raw_type` is the first string found and `type` is `:unknown`. Missing codes give
  `type: :unknown`; the parse fails only when the body is not a JSON object.
  """
  @spec parse_event(term()) :: {:ok, Event.t()} | {:error, :invalid_payload}
  def parse_event(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, payload} -> parse_event(payload)
      {:error, _} -> {:error, :invalid_payload}
    end
  end

  def parse_event(payload) when is_map(payload) and not is_struct(payload) do
    raw_type =
      Enum.find_value(["type", "event"], fn key ->
        value = Map.get(payload, key)
        if is_map_key(@event_types, value), do: value
      end) || Enum.find(Enum.map(["type", "event"], &Map.get(payload, &1)), &is_binary/1)

    {:ok,
     %Event{type: Map.get(@event_types, raw_type, :unknown), raw_type: raw_type, payload: payload}}
  end

  def parse_event(_), do: {:error, :invalid_payload}

  defp canonical(params, url_encode) do
    pairs = Enum.map(params, fn {key, value} -> {param_name(key), param_value(value)} end)

    if Enum.any?(pairs, fn {key, value} -> key == :error or value == :error end) or
         length(Enum.uniq_by(pairs, &elem(&1, 0))) != length(pairs) do
      :error
    else
      data =
        pairs
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map_join("&", fn {key, value} -> key <> "=" <> encode(value, url_encode) end)

      {:ok, data}
    end
  end

  defp param_name(key) when is_binary(key), do: key

  defp param_name(key) when is_atom(key) and key not in [nil, true, false],
    do: Atom.to_string(key)

  defp param_name(_), do: :error

  defp param_value(value) when is_binary(value), do: value
  defp param_value(value) when is_integer(value), do: Integer.to_string(value)
  defp param_value(true), do: "1"
  defp param_value(value) when value in [false, nil], do: ""
  defp param_value(_), do: :error

  defp encode(value, true), do: URI.encode(value, &URI.char_unreserved?/1)
  defp encode(value, false), do: value
end
