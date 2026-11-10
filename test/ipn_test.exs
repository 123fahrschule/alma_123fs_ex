defmodule Alma123FS.IPNTest do
  use ExUnit.Case, async: true
  alias Alma123FS.IPN

  @php_signature "0dd3cb4632c074ead0d0f346c75015c76ad4e1e115f01c7e0850dd5accb7b4b0"

  test "a signature computed like PHP hash_hmac('sha256', pid, key) is valid" do
    assert IPN.valid_signature?("merchant_id_test", "api_key_test", @php_signature)
    assert IPN.signature("merchant_id_test", "api_key_test") == @php_signature
  end

  test "an independently computed signature for a realistic payment id is valid" do
    assert IPN.valid_signature?(
             "payment_11uPRjP4a3cFQvoM1lehDnpxa2tYm2Hy0I",
             "sk_test_fake_key",
             "b44933e7166587cc79678b1a3ca76f52bd57fa058b4ab81166f611ea6bd63044"
           )
  end

  test "altered signatures, ids and keys are rejected" do
    altered = String.replace_suffix(@php_signature, "0", "1")
    refute IPN.valid_signature?("merchant_id_test", "api_key_test", altered)
    refute IPN.valid_signature?("merchant_id_test", "api_key_test", String.upcase(@php_signature))
    refute IPN.valid_signature?("merchant_id_test", "api_key_test", @php_signature <> "0")
    refute IPN.valid_signature?("merchant_id_tesT", "api_key_test", @php_signature)
    refute IPN.valid_signature?("merchant_id_test", "api_key_tesT", @php_signature)
  end

  test "the PHP client's invalid-data cases are rejected" do
    refute IPN.valid_signature?("payment_id_test", "api_key_test", "wrong_signature")
    refute IPN.valid_signature?("", "api_key_test", "wrong_signature")
    refute IPN.valid_signature?("payment_id_test", "", "wrong_signature")
    refute IPN.valid_signature?("payment_id_test", "api_key_test", "")
  end

  test "missing or non-string arguments are rejected" do
    refute IPN.valid_signature?(nil, "api_key_test", @php_signature)
    refute IPN.valid_signature?("merchant_id_test", nil, @php_signature)
    refute IPN.valid_signature?("merchant_id_test", "api_key_test", nil)
    refute IPN.valid_signature?("merchant_id_test", "api_key_test", ["x"])
  end

  test "the header name is lowercase for Plug" do
    assert IPN.header() == "x-alma-signature"
  end
end
