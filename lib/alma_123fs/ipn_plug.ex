if Code.ensure_loaded?(Plug.Conn) do
  defmodule Alma123FS.IPNPlug do
    @moduledoc """
    Optional Plug for the IPN callback. Mount it in the endpoint **before `Plug.Parsers`**.

    Required options:

      * `:path` — exact callback path, e.g. `"/webhooks/alma/ipn"`.
      * `:api_key` — `{module, function, args}` returning the API key at request time
        (recommended: the key stays out of compiled code), or the key itself.
      * `:handle` — function of one argument or `{module, function, extra_args}`.
        Receives the payment id (first argument) of a correctly signed call. Return `:ok`
        only after the work (typically a job that fetches the payment) is durably stored.

    Responses: 200 after `:handle` returned `:ok`; 503 for any other return (Alma retries);
    401 for a missing, repeated or invalid `X-Alma-Signature`; 400 for a missing or
    malformed `pid`; 405 for methods other than GET and POST. Exceptions from `:handle`
    propagate. A resolved key that is not a non-empty string raises `ArgumentError`.

    The signature does not confirm a payment: `:handle` must not mark anything as paid.
    See `Alma123FS.IPN` and the IPN guide.
    """
    @behaviour Plug
    import Plug.Conn, only: [halt: 1, send_resp: 3, put_resp_header: 3]
    alias Alma123FS.{Client, IPN}

    @impl true
    def init(options) do
      options = Alma123FS.Options.validate!(options, [:path, :api_key, :handle])

      unless is_binary(options[:path]) and String.starts_with?(options[:path], "/"),
        do: invalid!("path")

      unless key_source?(options[:api_key]), do: invalid!("api_key")
      unless callback?(options[:handle]), do: invalid!("handle")
      Map.new(options)
    end

    @impl true
    def call(%Plug.Conn{request_path: path} = conn, %{path: expected}) when path != expected,
      do: conn

    def call(%Plug.Conn{method: method} = conn, _options) when method not in ["GET", "POST"] do
      conn |> put_resp_header("allow", "GET, POST") |> respond(405)
    end

    def call(conn, options) do
      conn = Plug.Conn.fetch_query_params(conn)
      payment_id = conn.query_params["pid"]

      cond do
        Client.validate_id(payment_id, "pid") != :ok ->
          respond(conn, 400)

        not signed?(conn, payment_id, resolve_key(options.api_key)) ->
          respond(conn, 401)

        handle(options.handle, payment_id) == :ok ->
          respond(conn, 200)

        true ->
          respond(conn, 503)
      end
    end

    defp signed?(conn, payment_id, key) do
      case Plug.Conn.get_req_header(conn, IPN.header()) do
        [signature] -> IPN.valid_signature?(payment_id, key, signature)
        _ -> false
      end
    end

    defp handle({module, function, args}, payment_id),
      do: apply(module, function, [payment_id | args])

    defp handle(function, payment_id), do: function.(payment_id)

    defp resolve_key({module, function, args}) do
      key = apply(module, function, args)
      unless valid_key?(key), do: invalid!("resolved api_key")
      key
    end

    defp resolve_key(key), do: key

    defp key_source?({module, function, args}), do: mfa?(module, function, args)
    defp key_source?(key), do: valid_key?(key)
    defp valid_key?(key), do: is_binary(key) and key != ""

    defp callback?({module, function, args}), do: mfa?(module, function, args)
    defp callback?(function), do: is_function(function, 1)
    defp mfa?(module, function, args), do: is_atom(module) and is_atom(function) and is_list(args)

    defp invalid!(name), do: raise(ArgumentError, "invalid IPN option: #{name}")
    defp respond(conn, status), do: conn |> send_resp(status, "") |> halt()
  end
end
