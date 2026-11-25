defmodule HSetup.MixProject do
  use Mix.Project

  @version "0.3.1"
  @source_url "https://github.com/parlant/harness"
  @gitlab_url "https://gitlab.com/parlant-co/harness"
  @homepage_url "https://hiness.dev"
  @macos_app_url "https://hiness.app"

  def project do
    [
      app: :h_setup,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      aliases: [test: "test --no-start"],
      deps: deps(),
      name: "h_setup",
      source_url: @source_url,
      homepage_url: @homepage_url,
      description: "Zero-dependency Mix archive installer for signed H release bundles",
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :public_key, :inets, :ssl]
    ]
  end

  defp deps do
    [{:ex_doc, "~> 0.40", only: :docs, runtime: false}]
  end

  defp package do
    [
      name: "h_setup",
      licenses: ["MIT"],
      links: %{
        "Website & Manual" => @homepage_url,
        "macOS App (H.app)" => @macos_app_url,
        "Install Guide" => "#{@homepage_url}/docs/setup/",
        "Core Library (hiness)" => "https://hex.pm/packages/hiness",
        "GitHub" => @source_url,
        "GitLab" => @gitlab_url
      },
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE mark.svg)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      source_url_pattern: "#{@source_url}/blob/v#{@version}/installer/%{path}#L%{line}",
      homepage_url: @homepage_url,
      logo: "mark.svg",
      extras: [
        "README.md": [title: "Overview"],
        LICENSE: [title: "License"]
      ]
    ]
  end
end
