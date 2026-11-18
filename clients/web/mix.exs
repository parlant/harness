defmodule HWeb.MixProject do
  use Mix.Project

  def project do
    [
      app: :harness_web,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  def application do
    [
      mod: {HWeb.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      test: "test --no-start"
    ]
  end

  defp deps do
    [
      {:harness, path: "../.."},
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.2"},
      {:phoenix_html, "~> 4.1"},
      {:jason, "~> 1.4"},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end
end
