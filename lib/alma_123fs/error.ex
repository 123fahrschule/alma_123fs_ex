defmodule Alma123FS.Error do
  @moduledoc """
  The single error shape returned by this library.

  Fields:

    * `:kind` — where the failure happened:
      * `:validation` — rejected locally, nothing was sent to Alma;
      * `:api` — Alma answered with a non-2xx status;
      * `:transport` — no HTTP response (timeout, closed connection, DNS…);
      * `:protocol` — Alma answered 2xx, but the body is not what the API documents.
    * `:status` — HTTP status, or `nil` when there was no response.
    * `:type` — a fixed atom that classifies the error (see `t:type/0`).
    * `:message` — Alma's own `"message"` (or `"error"`) string from the response body,
      or a fixed local description for `:validation` errors.
    * `:code` — Alma's machine-readable `"error_code"` from the response body, when
      present (seen in the sandbox: `"validation_error"` on HTTP 422).
    * `:reason` — the transport reason atom (`:timeout`, `:closed`, …) for `:transport` errors.
    * `:body` — the decoded (or raw) response body, for diagnostics.

  `Inspect` shows only `kind`, `type`, `status`, `code` and `reason`: Alma's message and the
  body can echo customer data, so log them deliberately or not at all.
  No field ever contains the API key.

  ## Unknown outcome

  Functions that change state at Alma (`Alma123FS.Payments.create/2`,
  `Alma123FS.Payments.cancel/2`, `Alma123FS.Webhooks.create/3`,
  `Alma123FS.Webhooks.delete/2`) return `{:unknown, %Alma123FS.Error{}}` instead of
  `{:error, …}` when the request may have been executed: transport failures, HTTP 5xx or 408
  and unreadable 2xx bodies. `POST /v1/payments` has no idempotency key, so after
  `{:unknown, _}` a payment may exist. See the "Unknown outcome" guide.
  Read-only calls return such failures as `{:error, %Alma123FS.Error{}}`.
  """

  @derive {Inspect, only: [:kind, :type, :status, :code, :reason]}
  defstruct [:kind, :type, :status, :code, :message, :reason, :body]

  @type kind :: :validation | :api | :transport | :protocol
  @type type ::
          :invalid_request
          | :bad_request
          | :unauthorized
          | :forbidden
          | :not_found
          | :conflict
          | :unprocessable_entity
          | :rate_limited
          | :server_error
          | :unexpected_status
          | :invalid_response
          | :transport
  @type t :: %__MODULE__{
          kind: kind(),
          type: type(),
          status: non_neg_integer() | nil,
          code: String.t() | nil,
          message: String.t() | nil,
          reason: atom() | nil,
          body: term()
        }

  @doc "Build a local validation error; nothing has been sent to Alma."
  @spec validation(String.t()) :: t()
  def validation(message),
    do: %__MODULE__{kind: :validation, type: :invalid_request, message: message}

  @doc false
  @spec api(non_neg_integer(), term()) :: t()
  def api(status, body) do
    %__MODULE__{
      kind: :api,
      type: type_for_status(status),
      status: status,
      code: alma_code(body),
      message: alma_message(body),
      body: body
    }
  end

  @doc false
  @spec protocol(non_neg_integer(), term()) :: t()
  def protocol(status, body) do
    %__MODULE__{kind: :protocol, type: :invalid_response, status: status, body: body}
  end

  @doc false
  @spec transport(term()) :: t()
  def transport(%{reason: reason}) when is_atom(reason),
    do: %__MODULE__{kind: :transport, type: :transport, reason: reason}

  def transport(_), do: %__MODULE__{kind: :transport, type: :transport, reason: :unknown}

  @doc """
  Whether the request may have been executed by Alma although no success was seen.

  True for transport failures, HTTP 5xx, HTTP 408 and unreadable 2xx bodies.
  """
  @spec outcome_unknown?(t()) :: boolean()
  def outcome_unknown?(%__MODULE__{kind: kind}) when kind in [:transport, :protocol], do: true

  def outcome_unknown?(%__MODULE__{kind: :api, status: status})
      when status >= 500 or status == 408,
      do: true

  def outcome_unknown?(%__MODULE__{}), do: false

  @doc false
  @spec type_for_status(non_neg_integer()) :: type()
  def type_for_status(400), do: :bad_request
  def type_for_status(401), do: :unauthorized
  def type_for_status(403), do: :forbidden
  def type_for_status(404), do: :not_found
  def type_for_status(409), do: :conflict
  def type_for_status(422), do: :unprocessable_entity
  def type_for_status(429), do: :rate_limited
  def type_for_status(status) when status >= 500, do: :server_error
  def type_for_status(_), do: :unexpected_status

  defp alma_message(%{"message" => message}) when is_binary(message), do: message
  defp alma_message(%{"error" => message}) when is_binary(message), do: message
  defp alma_message(_), do: nil

  defp alma_code(%{"error_code" => code}) when is_binary(code), do: code
  defp alma_code(_), do: nil
end
