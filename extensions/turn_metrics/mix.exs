defmodule TurnMetricsExtension.MixProject do
  use Mix.Project

  def project do
    [
      app: :turn_metrics_extension,
      version: "0.5.2",
      elixir: "~> 1.20",
      aliases: [
        check: ["format --check-formatted", "compile --warnings-as-errors"],
        test: "test --no-start"
      ],
      deps: deps()
    ]
  end

  defp deps do
    root = System.get_env("H_SOURCE", "../..")

    [
      {:harness, path: root, runtime: false},
      {:harness_web, path: Path.join(root, "clients/web"), runtime: false},
      {:phoenix_live_view, "~> 1.2.15", runtime: false}
    ]
  end
end
