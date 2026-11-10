defmodule Alma123FS.Payments do
  @moduledoc """
  Create, fetch, cancel and list Alma payments (`/v1/payments`).

  A payment returned by `create/2` is not paid. Confirm a payment only with `fetch/2`:
  `processing_status` `:authorized` or `:captured`, `purchase_amount` and your own
  `custom_data`. Do not require the plan to match the request: Alma may decline
  installments and let the customer pay the full amount at once (seen in the sandbox).

  `POST /v1/payments` has **no idempotency key** (neither in the documentation nor in
  the PHP client). When `create/2` returns `{:unknown, error}` the payment may exist;
  find it with `list/2` before creating another one (see the "Unknown outcome" guide).
  """
  alias Alma123FS.{Client, Error, Payment}

  @path "/v1/payments"
  @top_level ["payment", "customer", "order"]
  @urls ["ipn_callback_url", "return_url", "customer_cancel_url", "failure_return_url"]

  @type create_result :: {:ok, Payment.t()} | {:error, Error.t()} | {:unknown, Error.t()}
  @type page :: %{payments: [Payment.t()], has_more: boolean()}

  @doc """
  `POST /v1/payments`. Returns the created payment, not a paid one.

  `params` mirrors Alma's body, with atom or string keys:

      %{
        payment: %{
          purchase_amount: 45_000,
          installments_count: 3,
          origin: "online_in_page",
          capture_method: "automatic",
          expires_after: 60,
          locale: "de",
          ipn_callback_url: "https://example.test/alma/ipn",
          return_url: "https://example.test/alma/return",
          customer_cancel_url: "https://example.test/alma/cancel",
          failure_return_url: "https://example.test/alma/failure",
          custom_data: %{"payment_id" => "…"},
          billing_address: %{…},
          shipping_address: %{…},
          cart: %{items: […]}
        },
        customer: %{first_name: "…", last_name: "…", email: "…", phone: "…", addresses: […]},
        order: %{merchant_reference: "…"}
      }

  Checked locally: `purchase_amount` (positive integer cents) and `installments_count`
  (1–12) are required — Alma would default the count to 3, this client does not let it;
  `capture_method` is `automatic` or `manual`; `expires_after` is a positive integer
  (minutes, Alma's default 2880); URLs are absolute http(s); `custom_data`, addresses,
  `cart`, `customer` and `order` are maps. Other payment fields are forwarded unchanged.

  Returns `{:unknown, error}` on transport failure, HTTP 5xx or 408, or an unreadable 2xx body:
  the payment may have been created.
  """
  @spec create(Client.t(), map()) :: create_result()
  def create(%Client{} = client, params) do
    with {:ok, body} <- create_body(params) do
      client |> Client.request(:post, @path, json: body) |> created()
    end
  end

  defp created({:ok, status, response}) do
    case Payment.from_map(response) do
      {:ok, payment} -> {:ok, payment}
      :error -> {:unknown, Error.protocol(status, response)}
    end
  end

  defp created(error), do: Client.unknown_if_uncertain(error)

  @doc "`GET /v1/payments/{id}`: the authoritative state of a payment."
  @spec fetch(Client.t(), String.t()) :: {:ok, Payment.t()} | {:error, Error.t()}
  def fetch(%Client{} = client, id) do
    with :ok <- Client.validate_id(id, "payment id"),
         {:ok, status, response} <- Client.request(client, :get, "#{@path}/#{id}") do
      case Payment.from_map(response) do
        {:ok, payment} -> {:ok, payment}
        :error -> {:error, Error.protocol(status, response)}
      end
    end
  end

  @doc """
  `POST /v1/payments/{id}/cancel`.

  Alma allows cancelation only until the first installment is collected:
  HTTP 204 → `:ok`; HTTP 400 → `{:error, %Error{type: :bad_request}}` with Alma's message.
  Canceling an already canceled payment returns 204 again (observed in the sandbox),
  so repeating `cancel/2` after `{:unknown, error}` is safe; fetch the payment to see
  the final state.
  """
  @spec cancel(Client.t(), String.t()) :: :ok | {:error, Error.t()} | {:unknown, Error.t()}
  def cancel(%Client{} = client, id) do
    with :ok <- Client.validate_id(id, "payment id") do
      case Client.request(client, :post, "#{@path}/#{id}/cancel") do
        {:ok, _status, _body} -> :ok
        error -> Client.unknown_if_uncertain(error)
      end
    end
  end

  @doc """
  `GET /v1/payments`: newest first, a subset of payment fields.

  Filters (keyword list):

    * `:created_after`, `:created_before` — `DateTime` or POSIX seconds (inclusive);
    * `:customer_email` — Alma matches every payment whose email **contains** this value;
    * `:state` — legacy state string or list, sent comma-separated (Alma returns the union).
      Values accepted by the sandbox: `not_ready`, `not_started`, `scored_no`,
      `scored_maybe`, `scored_yes`, `in_progress`, `paid`, `late`, `default`; anything
      else, including the `__not__` prefix from the generic documentation, is a 422.
      Canceled payments keep `state: "not_started"`: use `processing_status` for that;
    * `:limit` — 1–100 (Alma's default 20);
    * `:starting_after` — a payment id, for the next page.

  Returns `%{payments: [...], has_more: boolean}`.
  """
  @spec list(Client.t(), keyword()) :: {:ok, page()} | {:error, Error.t()}
  def list(%Client{} = client, filters \\ []) do
    filters =
      Alma123FS.Options.validate!(filters, [
        :created_after,
        :created_before,
        :customer_email,
        :state,
        :limit,
        :starting_after
      ])

    with {:ok, params} <- list_params(filters),
         {:ok, status, response} <- Client.request(client, :get, @path, params: params) do
      parse_page(status, response)
    end
  end

  defp parse_page(status, %{"data" => data, "has_more" => has_more} = response)
       when is_list(data) and is_boolean(has_more) do
    data
    |> Enum.reduce_while([], fn item, acc ->
      case Payment.from_map(item) do
        {:ok, payment} -> {:cont, [payment | acc]}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      :error -> {:error, Error.protocol(status, response)}
      payments -> {:ok, %{payments: Enum.reverse(payments), has_more: has_more}}
    end
  end

  defp parse_page(status, response), do: {:error, Error.protocol(status, response)}

  defp list_params(filters) do
    Enum.reduce_while(filters, {:ok, []}, fn {key, value}, {:ok, acc} ->
      case list_param(key, value) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, param} -> {:cont, {:ok, [{key, param} | acc]}}
        :error -> {:halt, invalid("invalid list filter: #{key}")}
      end
    end)
    |> case do
      {:ok, params} -> {:ok, Enum.reverse(params)}
      error -> error
    end
  end

  defp list_param(_key, nil), do: {:ok, nil}

  defp list_param(key, %DateTime{} = value) when key in [:created_after, :created_before],
    do: {:ok, DateTime.to_unix(value)}

  defp list_param(key, value)
       when key in [:created_after, :created_before] and is_integer(value) and value >= 0,
       do: {:ok, value}

  defp list_param(:customer_email, value) when is_binary(value) and value != "", do: {:ok, value}
  defp list_param(:state, value) when is_binary(value) and value != "", do: {:ok, value}

  defp list_param(:state, [_ | _] = values) do
    if Enum.all?(values, &(is_binary(&1) and &1 != "")),
      do: {:ok, Enum.join(values, ",")},
      else: :error
  end

  defp list_param(:limit, value) when is_integer(value) and value in 1..100, do: {:ok, value}

  defp list_param(:starting_after, value) do
    if Client.validate_id(value, "starting_after") == :ok, do: {:ok, value}, else: :error
  end

  defp list_param(_key, _value), do: :error

  defp create_body(params) when is_map(params) and not is_struct(params) do
    with {:ok, body} <- stringify(params, "params"),
         :ok <- known_top_level(body),
         {:ok, payment} <- payment(body),
         :ok <- optional_map(body, "customer"),
         :ok <- optional_map(body, "order") do
      {:ok, Map.put(body, "payment", payment)}
    end
  end

  defp create_body(_), do: invalid("params must be a map")

  defp known_top_level(body) do
    case Map.keys(body) -- @top_level do
      [] -> :ok
      unknown -> invalid("unknown top-level keys: #{Enum.join(Enum.sort(unknown), ", ")}")
    end
  end

  defp payment(%{"payment" => payment}) when is_map(payment) and not is_struct(payment) do
    with {:ok, payment} <- stringify(payment, "payment"),
         :ok <- check(payment, "purchase_amount", &(is_integer(&1) and &1 > 0), :required),
         :ok <- check(payment, "installments_count", &(is_integer(&1) and &1 in 1..12), :required),
         :ok <-
           check(payment, "capture_method", &(&1 in ["automatic", "manual", :automatic, :manual])),
         :ok <- check(payment, "expires_after", &(is_integer(&1) and &1 > 0)),
         :ok <- check(payment, "origin", &(is_binary(&1) and &1 != "")),
         :ok <- check(payment, "locale", &(is_binary(&1) and &1 != "")),
         :ok <- check_all(payment, @urls, &absolute_url?/1),
         :ok <-
           check_all(
             payment,
             ["custom_data", "billing_address", "shipping_address", "cart"],
             &plain_map?/1
           ) do
      {:ok, payment}
    end
  end

  defp payment(_), do: invalid("payment must be a map")

  defp check_all(map, keys, check) do
    Enum.reduce_while(keys, :ok, fn key, :ok ->
      case check(map, key, check) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp check(map, key, check, required \\ :optional) do
    case Map.fetch(map, key) do
      {:ok, value} when not is_nil(value) ->
        if check.(value), do: :ok, else: invalid("invalid payment.#{key}")

      _ when required == :required ->
        invalid("payment.#{key} is required")

      _ ->
        :ok
    end
  end

  defp optional_map(body, key) do
    case Map.get(body, key) do
      nil -> :ok
      value -> if plain_map?(value), do: :ok, else: invalid("#{key} must be a map")
    end
  end

  defp stringify(map, name) do
    stringified = Map.new(map, fn {key, value} -> {to_key(key), value} end)

    cond do
      Enum.any?(Map.keys(stringified), &is_nil/1) ->
        invalid("#{name} keys must be atoms or strings")

      map_size(stringified) != map_size(map) ->
        invalid("#{name} has duplicate atom and string keys")

      true ->
        {:ok, stringified}
    end
  end

  defp to_key(key) when is_binary(key), do: key

  defp to_key(key) when is_atom(key) and not is_nil(key) and not is_boolean(key),
    do: Atom.to_string(key)

  defp to_key(_), do: nil

  defp absolute_url?(value) do
    is_binary(value) and
      match?(
        %URI{scheme: scheme, host: host}
        when scheme in ["http", "https"] and is_binary(host) and host != "",
        URI.parse(value)
      )
  end

  defp plain_map?(value), do: is_map(value) and not is_struct(value)

  defp invalid(message), do: {:error, Error.validation(message)}
end
