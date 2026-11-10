defmodule Alma123FS do
  @moduledoc """
  A small Alma API client: eligibility, payments, IPN signature and the beta webhooks.

  Payment state and persistence belong to the application. A redirect, an IPN call or
  a webhook is never a payment confirmation; confirm by fetching the payment with
  `Alma123FS.Payments.fetch/2`.

  ## Configuration

  Build a client explicitly with `Alma123FS.Client.new/1`, or read the caller's
  application configuration at runtime with `client/1`:

      # config/runtime.exs
      config :alma_123fs_ex,
        api_key: System.fetch_env!("ALMA_API_KEY"),
        environment: :sandbox

      # config/test.exs
      config :alma_123fs_ex, api_key: "sk_test_fake", environment: :sandbox,
        plug: {Req.Test, Alma123FS}
  """

  @config_keys [:api_key, :environment, :receive_timeout, :connect_timeout, :plug]

  @doc """
  Build a client from `config :alma_123fs_ex, …`, read at call time.

  `overrides` take precedence over the configuration. Raises `ArgumentError`
  when the resulting configuration is invalid (see `Alma123FS.Client.new/1`).
  """
  @spec client(keyword()) :: Alma123FS.Client.t()
  def client(overrides \\ []) do
    :alma_123fs_ex
    |> Application.get_all_env()
    |> Keyword.take(@config_keys)
    |> Keyword.merge(overrides)
    |> Alma123FS.Client.new()
  end
end
