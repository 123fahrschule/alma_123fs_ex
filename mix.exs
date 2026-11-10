defmodule Alma123FS.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/123fahrschule/alma_123fs_ex"

  def project do
    [
      app: :alma_123fs_ex,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      test_paths: ["test", "integration"],
      test_coverage: [threshold: 90],
      dialyzer: [plt_local_path: "_build/plts", plt_core_path: "_build/plts"],
      deps: deps(),
      name: "Alma123FS",
      description: "A Req-based Alma API client for Elixir",
      source_url: @source_url,
      docs: [
        main: "readme",
        source_ref: @version,
        extras: [
          "README.md",
          "CHANGELOG.md",
          "guides/integration.md",
          "guides/ipn.md",
          "guides/unknown_outcome.md",
          "guides/webhooks_beta.md",
          "CONTRIBUTING.md"
        ]
      ]
    ]
  end

  def application, do: [extra_applications: [:crypto]]

  defp deps do
    [
      {:req, "~> 0.7"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.16", optional: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false}
    ]
  end
end
