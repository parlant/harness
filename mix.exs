defmodule H.MixProject do
  use Mix.Project

  @version "0.3.0"
  @source_url "https://github.com/parlant/harness"
  @gitlab_url "https://gitlab.com/parlant-co/harness"
  @homepage_url "https://hiness.dev"
  @macos_app_url "https://hiness.app"

  def project do
    [
      app: :harness,
      version: @version,
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: [test: "test --no-start"],
      releases: [harness: [include_erts: true]],
      name: "H",
      description: "Local Elixir/OTP coding-agent daemon with durable branched sessions",
      source_url: @source_url,
      homepage_url: @homepage_url,
      package: package(),
      docs: docs(),
      deps: deps()
    ]
  end

  defp package do
    [
      name: "hiness",
      licenses: ["MIT"],
      links: %{
        "Website & Manual" => @homepage_url,
        "macOS App (H.app)" => @macos_app_url,
        "Install H" => "#{@homepage_url}/#install",
        "GitHub" => @source_url,
        "GitLab" => @gitlab_url
      },
      # The native bundle Mix tasks need a source checkout (clients/, scripts/, rel/).
      files:
        ~w(lib/h lib/h.ex docs/hexdocs.md docs/hexdocs-logo.svg .formatter.exs mix.exs LICENSE)
    ]
  end

  defp docs do
    [
      main: "overview",
      source_ref: "v#{@version}",
      source_url: @source_url,
      homepage_url: @homepage_url,
      logo: "docs/hexdocs-logo.svg",
      extras: [
        "docs/hexdocs.md": [filename: "overview", title: "Overview"],
        LICENSE: [title: "License"]
      ],
      groups_for_modules: [
        "Daemon & Entry Points": [
          H,
          H.Application,
          H.Daemon,
          H.Daemon.Validation,
          H.Daemon.Workspace,
          H.Daemon.ColdSession,
          H.Catalog,
          H.StoreLock,
          H.Auth,
          H.Accounts,
          H.Accounts.Vault,
          H.Credentials
        ],
        "Sessions & Domain": [
          H.Session,
          H.Conversation,
          H.Entry,
          H.Task,
          H.Submission,
          H.Document,
          H.Transcript,
          H.Context,
          H.Archive,
          H.Schema
        ],
        "Session Runtime": [
          H.Session.Supervisor,
          H.Session.Server,
          H.Session.Server.State,
          H.Session.Server.Commands,
          H.Session.Server.Generation,
          H.Session.Server.Tools,
          H.Session.Server.Submissions,
          H.Session.Server.Stream,
          H.Session.Server.Recovery,
          H.Session.Server.WorkspaceWait,
          H.Session.Compaction,
          H.Session.Subagents,
          H.Session.UserShell
        ],
        "Extensions, Harnesses & Tools": [
          H.Extension,
          H.Harness,
          H.Harness.Coding,
          H.Tool,
          H.Tools.Read,
          H.Tools.Write,
          H.Tools.Edit,
          H.Tools.Bash,
          H.Tools.SearchHistory,
          H.Tools.Subagent
        ],
        "Execution Environments": [
          H.EnvRegistry,
          H.ExecutionEnv,
          H.ExecutionEnv.Host,
          H.ExecutionEnv.Host.FS,
          H.ExecutionEnv.Host.Exec,
          H.ExecutionEnv.Local,
          H.ExecutionEnv.Remote,
          H.RemoteAgent,
          H.WorkspaceLease
        ],
        Storage: [
          H.Storage,
          H.Storage.Engine,
          H.Storage.File,
          H.Storage.File.WAL,
          H.Storage.File.Snapshot,
          H.Storage.Memory
        ],
        Providers: [
          H.Provider,
          H.Provider.AccountPolicy,
          H.Provider.ReqLLM,
          H.Provider.ReqLLM.Catalog,
          H.Provider.ReqLLM.CodexPool,
          H.Provider.Fake,
          H.Provider.Fake.UnscriptedRequestError
        ],
        "HTTP & SSE Transport": [
          H.HTTP.Router,
          H.HTTP.SSE,
          H.HTTP.SecurityPlug
        ]
      ]
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
      {:req_llm, "~> 1.30.0"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end
end
