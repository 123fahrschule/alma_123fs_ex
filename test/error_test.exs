defmodule Alma123FS.ErrorTest do
  use ExUnit.Case, async: true
  alias Alma123FS.Error

  test "HTTP statuses map to fixed types" do
    for {status, type} <- [
          {400, :bad_request},
          {401, :unauthorized},
          {403, :forbidden},
          {404, :not_found},
          {409, :conflict},
          {422, :unprocessable_entity},
          {429, :rate_limited},
          {500, :server_error},
          {503, :server_error},
          {418, :unexpected_status}
        ] do
      assert %Error{kind: :api, type: ^type, status: ^status} = Error.api(status, %{})
    end
  end

  test "Alma's error_code is kept as code and shown by inspect" do
    error = Error.api(422, %{"error_code" => "validation_error", "message" => "x"})
    assert error.code == "validation_error"
    assert inspect(error) =~ "validation_error"
    assert Error.api(422, %{"error_code" => 1}).code == nil
    assert Error.api(500, "plain").code == nil
  end

  test "Alma's message is taken from message or error" do
    assert Error.api(400, %{"message" => "Le statut"}).message == "Le statut"
    assert Error.api(401, %{"error" => "Invalid API key"}).message == "Invalid API key"
    assert Error.api(400, %{"message" => 12}).message == nil
    assert Error.api(400, "plain").message == nil
  end

  test "inspect omits the message and body" do
    error = Error.api(400, %{"message" => "student@example.test is invalid"})
    refute inspect(error) =~ "student@example.test"
    assert inspect(error) =~ ":bad_request"
  end

  test "outcome is unknown only when Alma may have executed the request" do
    assert Error.outcome_unknown?(Error.transport(%Req.TransportError{reason: :timeout}))
    assert Error.outcome_unknown?(Error.protocol(201, "garbage"))
    assert Error.outcome_unknown?(Error.api(500, nil))
    assert Error.outcome_unknown?(Error.api(408, nil))
    refute Error.outcome_unknown?(Error.api(400, nil))
    refute Error.outcome_unknown?(Error.api(429, nil))
    refute Error.outcome_unknown?(Error.validation("bad"))
  end

  test "transport reasons that are not atoms are reduced to :unknown" do
    assert %Error{reason: :unknown} = Error.transport(%Req.TransportError{reason: {:tls, "x"}})
    assert %Error{reason: :unknown} = Error.transport(:other)
  end
end
