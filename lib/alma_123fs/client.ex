defmodule Alma123FS.Client do
  @moduledoc """
  Immutable configuration and HTTP transport for the Alma API.

  `new/1` options:

    * `:api_key` (required) — secret key (`sk_test_…` for sandbox, `sk_live_…` for live).
    * `:environment` (required) — `:sandbox` or `:live`. There is no default, so a
      missing setting cannot silently send live traffic to sandbox or the reverse.
      A key whose prefix contradicts the environment raises.
    * `:receive_timeout` — milliseconds, default `30_000`.
    * `:connect_timeout` — milliseconds, default `10_000`.
    * `:plug` — passed to Req, for `Req.Test` stubs in tests.

  The base URL is the API host (`https://api.getalma.eu` or
  `https://api.sandbox.getalma.eu`); endpoint paths carry their version
  (`/v1/payments`, `/v2/payments/eligibility`).

  Requests never retry and never follow redirects: the caller owns the retry policy,
  and the `Authorization` header must not travel to another host.
  The key is added per request and is not stored in the Req template;
  `Inspect` hides it. This module never logs.
  """

  alias Alma123FS.Error

  @version Mix.Project.config()[:version]
  @hosts %{live: "https://api.getalma.eu", sandbox: "https://api.sandbox.getalma.eu"}

  @derive {Inspect, only: [:environment, :base_url]}
  @enforce_keys [:environment, :base_url, :api_key, :request]
  defstruct [:environment, :base_url, :api_key, :request]

  @type environment :: :sandbox | :live
  @type t :: %__MODULE__{
          environment: environment(),
          base_url: String.t(),
          api_key: String.t(),
          request: Req.Request.t()
        }
  @type response :: {:ok, non_neg_integer(), term()} | {:error, Error.t()}

  @doc "Build a client; invalid configuration raises `ArgumentError` without echoing the key."
  @spec new(keyword()) :: t()
  def new(options) do
    options =
      Alma123FS.Options.validate!(options, [
        :api_key,
        :environment,
        :plug,
        receive_timeout: 30_000,
        connect_timeout: 10_000
      ])

    environment = environment!(options[:environment])
    key = api_key!(options[:api_key], environment)
    receive_timeout = positive_integer!(options[:receive_timeout], :receive_timeout)
    connect_timeout = positive_integer!(options[:connect_timeout], :connect_timeout)

    request =
      Req.new(
        [
          headers: [{"accept", "application/json"}, {"user-agent", "alma_123fs_ex/#{@version}"}],
          retry: false,
          redirect: false,
          decode_body: false,
          receive_timeout: receive_timeout,
          connect_options: [timeout: connect_timeout]
        ] ++ Keyword.take(options, [:plug])
      )

    %__MODULE__{
      environment: environment,
      base_url: Map.fetch!(@hosts, environment),
      api_key: key,
      request: request
    }
  end

  @doc """
  Send one request to a versioned path such as `"/v1/payments"`.

  Options: `:json` (map or list body) and `:params` (query keyword list).
  Returns `{:ok, status, body}` for 2xx with the JSON-decoded body (`nil` when empty),
  or `{:error, %Alma123FS.Error{}}`. A body that cannot be encoded as JSON is a
  `:validation` error and nothing is sent.
  """
  @spec request(t(), :get | :post | :delete, String.t(), keyword()) :: response()
  def request(%__MODULE__{} = client, method, path, options \\ []) do
    with {:ok, body_options} <- encode(Keyword.get(options, :json)) do
      request_options =
        [
          method: method,
          url: client.base_url <> path,
          headers: [{"authorization", "Alma-Auth " <> client.api_key} | body_options[:headers]]
        ] ++ Keyword.take(body_options, [:body]) ++ Keyword.take(options, [:params])

      case Req.request(client.request, request_options) do
        {:ok, %Req.Response{status: status, body: body}} -> response(status, body)
        {:error, exception} -> {:error, Error.transport(exception)}
      end
    end
  end

  defp encode(nil), do: {:ok, [headers: []]}

  defp encode(json) do
    case Jason.encode(json) do
      {:ok, body} -> {:ok, [headers: [{"content-type", "application/json"}], body: body]}
      {:error, _} -> {:error, Error.validation("request body is not JSON encodable")}
    end
  rescue
    Protocol.UndefinedError -> {:error, Error.validation("request body is not JSON encodable")}
  end

  @doc false
  @spec unknown_if_uncertain({:error, Error.t()}) :: {:error | :unknown, Error.t()}
  def unknown_if_uncertain({:error, error}) do
    if Error.outcome_unknown?(error), do: {:unknown, error}, else: {:error, error}
  end

  @doc false
  @spec validate_id(term(), String.t()) :: :ok | {:error, Error.t()}
  def validate_id(id, name) do
    if is_binary(id) and Regex.match?(~r/\A[A-Za-z0-9_-]{1,128}\z/, id),
      do: :ok,
      else: {:error, Error.validation("invalid #{name}")}
  end

  defp response(status, body) do
    decoded = decode(body)

    cond do
      status in 200..299 and decoded != :error -> {:ok, status, unwrap(decoded)}
      status in 200..299 -> {:error, Error.protocol(status, body)}
      decoded == :error -> {:error, Error.api(status, body)}
      true -> {:error, Error.api(status, unwrap(decoded))}
    end
  end

  defp decode(body) when body in ["", nil], do: {:ok, nil}

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, value} -> {:ok, value}
      {:error, _} -> :error
    end
  end

  defp decode(_), do: :error

  defp unwrap({:ok, value}), do: value

  defp environment!(environment) when environment in [:sandbox, :live], do: environment
  defp environment!(_), do: raise(ArgumentError, "environment must be :sandbox or :live")

  defp api_key!(key, environment) do
    unless is_binary(key) and Regex.match?(~r/\A[\x21-\x7e]+\z/, key),
      do: raise(ArgumentError, "api_key must be printable ASCII without whitespace")

    cond do
      environment == :live and String.starts_with?(key, "sk_test_") ->
        raise ArgumentError, "a test API key cannot be used with the :live environment"

      environment == :sandbox and String.starts_with?(key, "sk_live_") ->
        raise ArgumentError, "a live API key cannot be used with the :sandbox environment"

      true ->
        key
    end
  end

  defp positive_integer!(value, _name) when is_integer(value) and value > 0, do: value
  defp positive_integer!(_, name), do: raise(ArgumentError, "#{name} must be a positive integer")
end
