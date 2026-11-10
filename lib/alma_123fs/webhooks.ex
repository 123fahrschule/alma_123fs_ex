defmodule Alma123FS.Webhooks do
  @moduledoc """
  Webhook subscriptions: `POST /v1/webhooks`, `GET /v1/webhooks/{id}`,
  `DELETE /v1/webhooks/{id}`.

  These endpoints are not in Alma's public reference; they follow the PHP client's
  `WebhookEndpoint`. Its tests use the type `ecommerce_report` and a create response
  with `id`, `type` and `url` only (no secret). Whether the same endpoints manage the
  beta `payment.*` events is unknown, so responses are returned as decoded maps.
  """
  alias Alma123FS.{Client, Error}

  @path "/v1/webhooks"

  @doc """
  Create a subscription for `type` delivered to `url` (absolute http/https).

  Returns `{:unknown, error}` when the subscription may have been created.
  """
  @spec create(Client.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()} | {:unknown, Error.t()}
  def create(%Client{} = client, type, url) do
    with :ok <- validate_type(type),
         :ok <- validate_url(url) do
      case Client.request(client, :post, @path, json: %{"type" => type, "url" => url}) do
        {:ok, _status, body} when is_map(body) -> {:ok, body}
        {:ok, status, body} -> {:unknown, Error.protocol(status, body)}
        error -> Client.unknown_if_uncertain(error)
      end
    end
  end

  @doc "Fetch a subscription by id."
  @spec fetch(Client.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def fetch(%Client{} = client, id) do
    with :ok <- Client.validate_id(id, "webhook id") do
      case Client.request(client, :get, "#{@path}/#{id}") do
        {:ok, _status, body} when is_map(body) -> {:ok, body}
        {:ok, status, body} -> {:error, Error.protocol(status, body)}
        error -> error
      end
    end
  end

  @doc "Delete a subscription. Returns `{:unknown, error}` when it may have been deleted."
  @spec delete(Client.t(), String.t()) :: :ok | {:error, Error.t()} | {:unknown, Error.t()}
  def delete(%Client{} = client, id) do
    with :ok <- Client.validate_id(id, "webhook id") do
      case Client.request(client, :delete, "#{@path}/#{id}") do
        {:ok, _status, _body} -> :ok
        error -> Client.unknown_if_uncertain(error)
      end
    end
  end

  defp validate_type(type) when is_binary(type) and type != "", do: :ok
  defp validate_type(_), do: {:error, Error.validation("invalid webhook type")}

  defp validate_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        :ok

      _ ->
        {:error, Error.validation("invalid webhook url")}
    end
  end

  defp validate_url(_), do: {:error, Error.validation("invalid webhook url")}
end
