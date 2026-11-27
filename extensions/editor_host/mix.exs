defmodule EditorHostExtension.MixProject do
  use Mix.Project

  def project do
    [
      app: :editor_host_extension,
      version: "0.5.2",
      elixir: "~> 1.20",
      aliases: [
        check: ["format --check-formatted", "compile --warnings-as-errors"],
        test: "test --no-start"
      ],
      deps: [{:harness, path: System.get_env("H_SOURCE", "../.."), runtime: false}]
    ]
  end
end
