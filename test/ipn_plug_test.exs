defmodule Alma123FS.IPNPlugTest do
  use ExUnit.Case, async: true
  import Plug.Test
  alias Alma123FS.{IPN, IPNPlug}

  @key "sk_test_fake_key"
  @pid "payment_11uPRjP4a3cFQvoM1lehDnpxa2tYm2Hy0I"

  def key, do: @key
  def key(:invalid), do: ""
  def store(payment_id, parent), do: send(parent, {:stored, payment_id}) && :ok

  defp options(overrides \\ []) do
    parent = self()

    [
      path: "/webhooks/alma/ipn",
      api_key: @key,
      handle: fn id -> send(parent, {:stored, id}) && :ok end
    ]
    |> Keyword.merge(overrides)
    |> IPNPlug.init()
  end

  defp signed(method \\ :get, pid \\ @pid, signature \\ IPN.signature(@pid, @key)) do
    method
    |> conn("/webhooks/alma/ipn?pid=#{pid}")
    |> Plug.Conn.put_req_header("x-alma-signature", signature)
  end

  test "a signed GET is handed to the handler and acknowledged with 200" do
    conn = IPNPlug.call(signed(), options())
    assert conn.status == 200
    assert conn.halted
    assert_received {:stored, @pid}
  end

  test "a signed POST is accepted as well" do
    assert IPNPlug.call(signed(:post), options()).status == 200
    assert_received {:stored, @pid}
  end

  test "missing, repeated or invalid signatures are rejected without calling the handler" do
    opts = options(handle: fn _ -> flunk("must not handle") end)

    assert IPNPlug.call(conn(:get, "/webhooks/alma/ipn?pid=#{@pid}"), opts).status == 401

    assert IPNPlug.call(
             signed(:get, @pid, "0" <> String.slice(IPN.signature(@pid, @key), 1..-1//1)),
             opts
           ).status == 401

    assert IPNPlug.call(signed(:get, @pid, IPN.signature(@pid, "sk_test_other")), opts).status ==
             401

    repeated = %{
      signed()
      | req_headers: [{"x-alma-signature", IPN.signature(@pid, @key)} | signed().req_headers]
    }

    assert IPNPlug.call(repeated, opts).status == 401
  end

  test "a missing or malformed pid is a bad request" do
    opts = options(handle: fn _ -> flunk("must not handle") end)
    assert IPNPlug.call(conn(:get, "/webhooks/alma/ipn"), opts).status == 400
    assert IPNPlug.call(signed(:get, "a%2Fb", IPN.signature("a/b", @key)), opts).status == 400
  end

  test "a list-valued pid is a bad request and a repeated pid uses the last, signed value" do
    opts = options(handle: fn _ -> flunk("must not handle") end)

    list_conn =
      conn(:get, "/webhooks/alma/ipn?pid[]=#{@pid}")
      |> Plug.Conn.put_req_header("x-alma-signature", IPN.signature(@pid, @key))

    assert IPNPlug.call(list_conn, opts).status == 400

    repeated =
      conn(:get, "/webhooks/alma/ipn?pid=payment_other&pid=#{@pid}")
      |> Plug.Conn.put_req_header("x-alma-signature", IPN.signature(@pid, @key))

    assert IPNPlug.call(repeated, options()).status == 200
    assert_received {:stored, @pid}
  end

  test "other paths pass through untouched" do
    conn = IPNPlug.call(conn(:get, "/other"), options())
    refute conn.halted
    assert conn.status == nil
  end

  test "other methods are not allowed" do
    conn = IPNPlug.call(conn(:put, "/webhooks/alma/ipn?pid=#{@pid}"), options())
    assert conn.status == 405
    assert Plug.Conn.get_resp_header(conn, "allow") == ["GET, POST"]
  end

  test "a handler result other than :ok returns 503 so Alma retries" do
    assert IPNPlug.call(signed(), options(handle: fn _ -> {:error, :db_down} end)).status == 503
  end

  test "handler exceptions propagate" do
    assert_raise RuntimeError, "db down", fn ->
      IPNPlug.call(signed(), options(handle: fn _ -> raise "db down" end))
    end
  end

  test "the key and the handler can be resolved through MFA tuples" do
    opts = options(api_key: {__MODULE__, :key, []}, handle: {__MODULE__, :store, [self()]})
    assert IPNPlug.call(signed(), opts).status == 200
    assert_received {:stored, @pid}
  end

  test "a resolved key that is not a string raises" do
    assert_raise ArgumentError, ~r/resolved api_key/, fn ->
      IPNPlug.call(signed(), options(api_key: {__MODULE__, :key, [:invalid]}))
    end
  end

  test "invalid options raise at init" do
    for overrides <- [
          [path: "webhooks"],
          [path: nil],
          [api_key: ""],
          [api_key: nil],
          [handle: fn -> :ok end],
          [handle: nil]
        ] do
      assert_raise ArgumentError, fn -> options(overrides) end
    end

    assert_raise ArgumentError, fn -> options(secret: "x") end
  end
end
