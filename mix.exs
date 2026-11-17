defmodule H.MixProject do
  use Mix.Project

  def project do
    [
      app: :harness,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      aliases: [test: "test --no-start"],
      deps: []
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end
end
