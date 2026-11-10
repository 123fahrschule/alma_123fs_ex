ExUnit.start(exclude: [:integration])

defmodule Alma123FS.TestSupport do
  @stub Alma123FS.TestStub

  def client(options \\ []) do
    [api_key: "sk_test_fake_key", environment: :sandbox, plug: {Req.Test, @stub}]
    |> Keyword.merge(options)
    |> Alma123FS.Client.new()
  end

  def stub(fun), do: Req.Test.stub(@stub, fun)

  def respond(status, body) do
    parent = self()

    stub(fn conn ->
      send(parent, {:request, request(conn)})
      reply(conn, status, body)
    end)
  end

  def transport_error(reason) do
    parent = self()

    stub(fn conn ->
      send(parent, {:request, request(conn)})
      Req.Test.transport_error(conn, reason)
    end)
  end

  def reply(conn, status, body) when is_binary(body), do: Plug.Conn.send_resp(conn, status, body)
  def reply(conn, status, body), do: conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)

  def request(conn) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)

    %{
      method: conn.method,
      path: conn.request_path,
      query: URI.decode_query(conn.query_string),
      body: if(raw == "", do: nil, else: Jason.decode!(raw)),
      headers: Map.new(conn.req_headers)
    }
  end

  def fixture(name), do: Path.join([__DIR__, "fixtures", name]) |> File.read!() |> Jason.decode!()
end
