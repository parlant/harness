defmodule AnalyticsExtension.MixProject do
  use Mix.Project

  def project do
    root = System.get_env("H_SOURCE", "../..")

    [
      app: :analytics_extension,
      version: "0.5.2",
      elixir: "~> 1.20",
      aliases: [
        check: ["format --check-formatted", "compile --warnings-as-errors"],
        test: "test --no-start"
      ],
      deps: [
        {:harness, path: root, runtime: false},
        {:harness_web, path: Path.join(root, "clients/web"), runtime: false},
        {:phoenix_live_view, "~> 1.2.15", runtime: false},
        {:jason, "~> 1.4", runtime: false},
        {:lazy_html, ">= 0.1.0", only: :test}
      ]
    ]
  end
end
