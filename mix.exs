defmodule H.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://gitlab.com/parlant-co/harness"

  def project do
    [
      app: :harness,
      version: @version,
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: [test: "test --no-start"],
      releases: [harness: [include_erts: true]],
      description: "Local Elixir/OTP coding-agent daemon with durable branched sessions",
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      deps: deps()
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitLab" => @source_url,
        "GitHub" => "https://github.com/parlant/harness"
      },
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {H.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:bandit, "~> 1.14"},
      {:plug, "~> 1.20.4"},
      {:req, "~> 0.7.5"},
      {:req_llm, "~> 1.30.0"}
    ]
  end
end
