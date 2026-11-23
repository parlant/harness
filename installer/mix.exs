defmodule HSetup.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://gitlab.com/parlant-co/harness"

  def project do
    [
      app: :h_setup,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      aliases: [test: "test --no-start"],
      deps: [],
      description: "Mix archive installer for Harness (H) signed release bundles",
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :public_key, :inets, :ssl]
    ]
  end

  defp package do
    [
      name: "h_setup",
      licenses: ["MIT"],
      links: %{
        "GitLab" => @source_url,
        "GitHub" => "https://github.com/parlant/harness"
      },
      files: ~w(lib .formatter.exs mix.exs README.md)
    ]
  end
end
