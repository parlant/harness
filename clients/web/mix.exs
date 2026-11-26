defmodule HWeb.MixProject do
  use Mix.Project

  def project do
    [
      app: :harness_web,
      version: "0.5.1",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      listeners: [Phoenix.CodeReloader],
      releases: [harness: [include_erts: true, rel_templates_path: "../../rel"]]
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
      {:phoenix, "~> 1.8.17"},
      {:phoenix_live_view, "~> 1.2.15"},
      {:phoenix_live_reload, "~> 1.7", only: :dev},
      {:phoenix_html, "~> 4.1"},
      {:jason, "~> 1.4"},
      {:earmark_parser, "~> 1.4.46"},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end
end
