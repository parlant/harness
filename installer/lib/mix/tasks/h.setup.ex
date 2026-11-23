defmodule Mix.Tasks.H.Setup do
  @shortdoc "Downloads, verifies, and installs a signed Harness (H) release bundle"
  @moduledoc """
  Downloads, cryptographically verifies (Ed25519 SSHSIG + SHA-256), and installs
  a signed Harness (`hi`, `h-daemon`, `hi-import`) release bundle.

  ## Usage

      mix h.setup [options]

  ## Options

    * `--version VERSION` - release version to install (default: `latest`)
    * `--release-url URL` - override release download base URL (env: `H_RELEASE_URL`)
    * `--prefix DIR` - install prefix (default: `~/.local/opt/harness`, env: `H_PREFIX`)
    * `--bin-dir DIR` - symlink directory for `hi`/`hi-import` (default: cascade writable `PATH` locations, falling back to `~/.bin` last; env: `H_BIN_DIR`)
    * `--data-dir DIR` - daemon data directory for `--service` (default: `~/.local/share/h`, env: `H_DATA_DIR`)
    * `--service` - register and start a per-user service (macOS LaunchAgent or Linux `systemd --user`)
    * `--signer-pubkey KEY` - override trusted `ssh-ed25519` public key (env: `H_SIGNER_PUBKEY`)
  """

  use Mix.Task

  alias HSetup.{Installer, SshSig}

  @switches [
    version: :string,
    release_url: :string,
    prefix: :string,
    bin_dir: :string,
    data_dir: :string,
    service: :boolean,
    signer_pubkey: :string,
    target: :string
  ]

  @impl true
  def run(args) do
    {parsed, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      bad = Enum.map_join(invalid, ", ", fn {k, _} -> k end)
      Mix.raise("Unknown option(s) for mix h.setup: #{bad}")
    end

    if positional != [] do
      Mix.raise(
        "Unexpected positional argument(s) for mix h.setup: #{Enum.join(positional, " ")}"
      )
    end

    home = System.user_home!()

    target =
      case parsed[:target] do
        nil -> nil
        str -> parse_target!(str)
      end

    opts = %{
      version: parsed[:version] || System.get_env("H_VERSION") || "latest",
      release_url: parsed[:release_url] || System.get_env("H_RELEASE_URL"),
      prefix:
        parsed[:prefix] || System.get_env("H_PREFIX") || Path.join(home, ".local/opt/harness"),
      bin_dir:
        Installer.select_bin_dir(
          explicit: parsed[:bin_dir] || System.get_env("H_BIN_DIR"),
          home: home
        ),
      data_dir:
        parsed[:data_dir] || System.get_env("H_DATA_DIR") || Path.join(home, ".local/share/h"),
      service: Keyword.get(parsed, :service, false),
      signer_pubkey:
        parsed[:signer_pubkey] || System.get_env("H_SIGNER_PUBKEY") ||
          SshSig.default_signer_pubkey(),
      target: target,
      log: fn msg -> Mix.shell().info(msg) end
    }

    case Installer.run(opts) do
      {:ok, result} ->
        maybe_warn_path(result.bin_dir)
        :ok

      {:error, reason} ->
        Mix.raise("mix h.setup failed: #{reason}")
    end
  end

  defp parse_target!(str) do
    case String.split(str, "-", parts: 2) do
      [os, arch] when os in ["darwin", "linux"] and arch in ["arm64", "x86_64"] ->
        {os, arch}

      _ ->
        Mix.raise(
          "Invalid --target #{inspect(str)} (expected darwin-arm64, linux-arm64, or linux-x86_64)"
        )
    end
  end

  defp maybe_warn_path(bin_dir) do
    expanded = Path.expand(bin_dir)

    path_entries =
      (System.get_env("PATH") || "")
      |> String.split(":", trim: true)
      |> Enum.map(&Path.expand/1)

    unless expanded in path_entries do
      Mix.shell().info("Add #{bin_dir} to PATH in your shell profile, then run: hi")
    end
  end
end
