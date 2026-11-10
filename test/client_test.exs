defmodule Alma123FS.ClientTest do
  use ExUnit.Case, async: true
  import Alma123FS.TestSupport
  alias Alma123FS.{Client, Error}

  test "environments select the documented API hosts" do
    assert Client.new(api_key: "sk_test_x", environment: :sandbox).base_url ==
             "https://api.sandbox.getalma.eu"

    assert Client.new(api_key: "sk_live_x", environment: :live).base_url ==
             "https://api.getalma.eu"
  end

  test "the API key never appears in inspect output or the stored Req template" do
    client = Client.new(api_key: "sk_test_secret_value", environment: :sandbox)
    refute inspect(client) =~ "secret_value"
    refute inspect(client.request, limit: :infinity) =~ "secret_value"
    assert Req.Request.get_header(client.request, "authorization") == []
  end

  test "environment is required and must be known" do
    for options <- [[], [environment: :test], [environment: "sandbox"]] do
      assert_raise ArgumentError, fn -> Client.new([api_key: "sk_test_x"] ++ options) end
    end
  end

  test "key prefixes that contradict the environment are rejected without echoing the key" do
    error =
      assert_raise ArgumentError, fn ->
        Client.new(api_key: "sk_test_secret", environment: :live)
      end

    refute Exception.message(error) =~ "secret"

    assert_raise ArgumentError, fn ->
      Client.new(api_key: "sk_live_secret", environment: :sandbox)
    end

    assert %Client{} = Client.new(api_key: "other_key", environment: :live)
  end

  test "invalid keys and timeouts raise" do
    for options <- [
          [api_key: nil],
          [api_key: ""],
          [api_key: "sk_test_ secret"],
          [api_key: "sk_test_secret\n"],
          [api_key: "sk_test_x", receive_timeout: 0],
          [api_key: "sk_test_x", connect_timeout: -1],
          [api_key: "sk_test_x", unknown: true]
        ] do
      assert_raise ArgumentError, fn -> Client.new([environment: :sandbox] ++ options) end
    end
  end

  test "timeouts are configurable and retries and redirects are disabled" do
    client =
      Client.new(
        api_key: "sk_test_x",
        environment: :sandbox,
        receive_timeout: 1_234,
        connect_timeout: 567
      )

    assert client.request.options.receive_timeout == 1_234
    assert client.request.options.connect_options == [timeout: 567]
    assert client.request.options.retry == false
    assert client.request.options.redirect == false
  end

  test "requests carry the Alma-Auth header, JSON accept and a user agent" do
    respond(200, %{"ok" => true})
    assert {:ok, 200, %{"ok" => true}} = Client.request(client(), :get, "/v1/payments")
    assert_received {:request, %{headers: headers, path: "/v1/payments"}}
    assert headers["authorization"] == "Alma-Auth sk_test_fake_key"
    assert headers["accept"] == "application/json"
    assert headers["user-agent"] =~ "alma_123fs_ex/"
  end

  test "empty 2xx bodies decode to nil" do
    respond(204, "")
    assert {:ok, 204, nil} = Client.request(client(), :post, "/v1/payments/payment_1/cancel")
  end

  test "non-JSON 2xx bodies are protocol errors" do
    respond(200, "<html>")

    assert {:error, %Error{kind: :protocol, status: 200, body: "<html>"}} =
             Client.request(client(), :get, "/v1/payments")
  end

  test "non-JSON error bodies keep the raw body" do
    respond(502, "Bad Gateway")

    assert {:error,
            %Error{
              kind: :api,
              type: :server_error,
              status: 502,
              body: "Bad Gateway",
              message: nil
            }} =
             Client.request(client(), :get, "/v1/payments")
  end

  test "redirects are returned as errors and never followed" do
    parent = self()

    stub(fn conn ->
      send(parent, :called)

      conn
      |> Plug.Conn.put_resp_header("location", "https://attacker.test/v1/payments")
      |> Plug.Conn.send_resp(302, "")
    end)

    assert {:error, %Error{kind: :api, status: 302, type: :unexpected_status}} =
             Client.request(client(), :get, "/v1/payments")

    assert_received :called
    refute_received :called
  end

  test "option errors name the keys but never echo the values" do
    for options <- [
          [api_key: "sk_live_secret_value", environment: :live, timeout: 1],
          [api_key: "sk_live_secret_value", environment: :live, api_key: "sk_live_secret_value"]
        ] do
      error = assert_raise ArgumentError, fn -> Client.new(options) end
      refute Exception.message(error) =~ "secret_value"
    end

    error =
      assert_raise ArgumentError, fn ->
        Alma123FS.Payments.list(client(), email: "erika@example.test")
      end

    assert Exception.message(error) =~ ":email"
    refute Exception.message(error) =~ "erika"
    assert_raise ArgumentError, fn -> Client.new(%{api_key: "k"}) end
  end

  test "bodies that cannot be encoded as JSON are rejected before sending" do
    stub(fn _ -> flunk("must not reach Alma") end)

    for body <- [%{"a" => {1, 2}}, %{"a" => <<0xFF>>}, %{"a" => self()}] do
      assert {:error, %Error{kind: :validation, message: "request body is not JSON encodable"}} =
               Client.request(client(), :post, "/v1/payments", json: body)
    end
  end

  test "transport failures keep only the reason atom" do
    transport_error(:econnrefused)

    assert {:error, %Error{kind: :transport, reason: :econnrefused, status: nil}} =
             Client.request(client(), :get, "/v1/payments")
  end

  test "identifiers are restricted to Alma's id alphabet" do
    assert :ok = Client.validate_id("payment_11uPRjP4a3cFQvoM1lehDnpxa2tYm2Hy0I", "id")

    for id <- ["", "../payments", "a/b", "a?b", "a b", nil, 1, String.duplicate("a", 129)] do
      assert {:error, %Error{kind: :validation}} = Client.validate_id(id, "id")
    end
  end
end

defmodule Alma123FS.ConfigTest do
  use ExUnit.Case, async: false
  alias Alma123FS.Client

  setup do
    previous = Application.get_all_env(:alma_123fs_ex)

    on_exit(fn ->
      Enum.each(previous, fn {k, v} -> Application.put_env(:alma_123fs_ex, k, v) end)
    end)

    on_exit(fn ->
      Enum.each(
        [:api_key, :environment, :receive_timeout],
        &Application.delete_env(:alma_123fs_ex, &1)
      )
    end)
  end

  test "client/1 reads the caller's configuration at call time and accepts overrides" do
    Application.put_env(:alma_123fs_ex, :api_key, "sk_live_configured")
    Application.put_env(:alma_123fs_ex, :environment, :live)
    Application.put_env(:alma_123fs_ex, :receive_timeout, 5_000)

    assert %Client{environment: :live, base_url: "https://api.getalma.eu"} =
             client = Alma123FS.client()

    assert client.request.options.receive_timeout == 5_000

    assert %Client{environment: :sandbox} =
             Alma123FS.client(api_key: "sk_test_override", environment: :sandbox)
  end

  test "client/1 raises when the configuration is missing" do
    assert_raise ArgumentError, fn -> Alma123FS.client() end
  end
end
