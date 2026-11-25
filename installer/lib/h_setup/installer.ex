defmodule HSetup.Installer do
  @moduledoc """
  Downloads, verifies, and atomically installs signed Harness (H) release bundles.
  """

  alias HSetup.SshSig

  @default_latest_url "https://gitlab.com/parlant-co/harness/-/releases/permalink/latest/downloads"
  @default_tag_template "https://gitlab.com/parlant-co/harness/-/releases/v%{version}/downloads"
  @max_redirects 5
  @default_preferred_bin_dirs ["/usr/local/bin", "/opt/local/bin", "/opt/homebrew/bin"]

  @type options :: %{
          version: String.t(),
          release_url: String.t() | nil,
          prefix: String.t(),
          bin_dir: String.t(),
          data_dir: String.t(),
          service: boolean(),
          signer_pubkey: String.t(),
          target: {String.t(), String.t()} | nil,
          log: (String.t() -> any())
        }

  @doc """
  Runs the full verified download, extraction, atomic switch, and optional service setup.
  """
  @spec run(options()) :: {:ok, map()} | {:error, String.t()}
  def run(opts) do
    log = Map.get(opts, :log, fn _ -> :ok end)

    with {:ok, {os, arch}} <- resolve_target(Map.get(opts, :target)),
         {:ok, base_url} <- resolve_base_url(opts),
         :ok <- ensure_http_started(),
         _ <- log.("Fetching release manifest from #{base_url}"),
         {:ok, sums_bin} <- http_get("#{base_url}/SHA256SUMS"),
         {:ok, sig_bin} <- http_get("#{base_url}/SHA256SUMS.sig"),
         :ok <- SshSig.verify(sums_bin, sig_bin, opts.signer_pubkey, "file"),
         {:ok, {expected_sha, tarball}} <- select_artifact(sums_bin, os, arch),
         _ <- log.("Downloading #{tarball}..."),
         {:ok, tarball_bin} <- http_get("#{base_url}/#{tarball}"),
         :ok <- verify_sha256(tarball_bin, expected_sha, tarball),
         {:ok, result} <- install_tarball(tarball_bin, tarball, os, opts, log) do
      {:ok, result}
    end
  end

  @doc """
  Selects the symlink bin directory by cascading writable `PATH` locations:

  1. Preferred standard locations on `PATH` and writable: `/usr/local/bin`, `/opt/local/bin`,
     `/opt/homebrew/bin`, then `~/.local/bin` (writable or creatable under writable `~/.local` / `~`).
  2. Any other existing user-writable directory on `PATH` (excluding OS system directories,
     toolchain shims/cellars/ERTS dirs, relative paths, and `~/.bin`).
  3. `~/.bin` if on `PATH` and writable.
  4. Off-`PATH` fallback: writable preferred standard locations, then existing writable
     `~/.local/bin`, and `~/.bin` strictly as the last resort.
  """
  @spec select_bin_dir(keyword()) :: String.t()
  def select_bin_dir(opts \\ []) do
    explicit = Keyword.get(opts, :explicit) || System.get_env("H_BIN_DIR")

    if is_binary(explicit) and explicit != "" do
      Path.expand(explicit)
    else
      home = Keyword.get(opts, :home) || System.user_home!()
      home_norm = normalize_dir(home)
      raw_path = Keyword.get(opts, :path, System.get_env("PATH") || "")
      path_entries = String.split(raw_path, ":", trim: true)
      norm_entries = Enum.map(path_entries, &normalize_dir/1)
      path_set = MapSet.new(norm_entries)

      preferred =
        Keyword.get_lazy(opts, :preferred, fn ->
          case System.get_env("H_PREFERRED_BIN_DIRS") do
            nil -> @default_preferred_bin_dirs
            "" -> @default_preferred_bin_dirs
            raw -> String.split(raw, ":", trim: true)
          end
        end)
        |> Enum.map(&normalize_dir/1)

      local_bin = normalize_dir(Path.join(home_norm, ".local/bin"))
      home_bin = normalize_dir(Path.join(home_norm, ".bin"))

      find_preferred_on_path(preferred, path_set) ||
        if(MapSet.member?(path_set, local_bin) and local_bin_usable?(local_bin, home_norm),
          do: local_bin
        ) ||
        find_other_writable_on_path(path_entries, norm_entries, home_bin) ||
        if(MapSet.member?(path_set, home_bin) and writable_dir?(home_bin), do: home_bin) ||
        Enum.find(preferred, &writable_dir?/1) ||
        if(writable_dir?(local_bin), do: local_bin) ||
        home_bin
    end
  end

  defp find_preferred_on_path(preferred, path_set) do
    Enum.find(preferred, fn dir ->
      MapSet.member?(path_set, dir) and writable_dir?(dir)
    end)
  end

  defp find_other_writable_on_path(raw_entries, norm_entries, home_bin) do
    Enum.zip(raw_entries, norm_entries)
    |> Enum.find_value(fn {raw, norm} ->
      if not excluded_path_dir?(raw, norm, home_bin) and writable_dir?(norm) do
        norm
      end
    end)
  end

  defp normalize_dir(dir) do
    expanded = Path.expand(dir)

    case String.trim_trailing(expanded, "/") do
      "" -> "/"
      trimmed -> trimmed
    end
  end

  defp writable_dir?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory, access: access}} when access in [:read_write, :write] ->
        true

      _ ->
        false
    end
  end

  defp local_bin_usable?(local_bin, home_norm) do
    cond do
      writable_dir?(local_bin) ->
        true

      match?({:ok, _}, File.lstat(local_bin)) ->
        false

      true ->
        local_dir = Path.join(home_norm, ".local")

        writable_dir?(local_dir) or
          (match?({:error, :enoent}, File.lstat(local_dir)) and writable_dir?(home_norm))
    end
  end

  defp excluded_path_dir?(raw, norm, home_bin) do
    cond do
      raw == "" or not String.starts_with?(raw, "/") ->
        true

      norm in ["/", "/bin", "/usr/bin", "/sbin", "/usr/sbin", home_bin] ->
        true

      String.starts_with?(norm, ["/System/", "/Library/", "/var/run/"]) ->
        true

      String.ends_with?(norm, ["/.cargo/bin", "/node_modules/.bin"]) ->
        true

      true ->
        parts = Path.split(norm)

        "Cellar" in parts or "shims" in parts or
          Enum.any?(parts, &String.starts_with?(&1, "erts-"))
    end
  end

  @doc """
  Detects `{os, arch}` from the running BEAM system architecture.
  """
  @spec detect_target() :: {:ok, {String.t(), String.t()}} | {:error, String.t()}
  def detect_target do
    os =
      case :os.type() do
        {:unix, :darwin} -> {:ok, "darwin"}
        {:unix, :linux} -> {:ok, "linux"}
        other -> {:error, "unsupported OS: #{inspect(other)} (supported: macOS, Linux)"}
      end

    arch_str = :erlang.system_info(:system_architecture) |> List.to_string() |> String.downcase()

    arch =
      cond do
        String.starts_with?(arch_str, "aarch64") or String.starts_with?(arch_str, "arm64") ->
          {:ok, "arm64"}

        String.starts_with?(arch_str, "x86_64") or String.starts_with?(arch_str, "amd64") ->
          {:ok, "x86_64"}

        true ->
          {:error, "unsupported architecture: #{arch_str} (supported: arm64, x86_64)"}
      end

    with {:ok, o} <- os, {:ok, a} <- arch, do: {:ok, {o, a}}
  end

  @doc """
  Parses an authenticated `SHA256SUMS` file and returns `{expected_hex_sha256, filename}`
  for `-{os}-{arch}.tar.gz`.
  """
  @spec select_artifact(binary(), String.t(), String.t()) ::
          {:ok, {String.t(), String.t()}} | {:error, String.t()}
  def select_artifact(sums_bin, os, arch) do
    suffix = "-#{os}-#{arch}.tar.gz"

    sums_bin
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.find_value(fn line ->
      case String.split(String.trim(line), ~r/\s+/, parts: 2) do
        [sha, raw_name] ->
          name = String.trim_leading(raw_name, "*")

          if String.ends_with?(name, suffix) and byte_size(name) > byte_size(suffix) do
            {String.downcase(sha), name}
          end

        _ ->
          nil
      end
    end)
    |> case do
      nil ->
        {:error, "no release artifact for #{os}-#{arch} in SHA256SUMS"}

      {sha, name} ->
        with :ok <- validate_sha_hex(sha),
             :ok <- validate_artifact_name(name) do
          {:ok, {sha, name}}
        end
    end
  end

  defp resolve_target(nil), do: detect_target()

  defp resolve_target({os, arch}) when os in ["darwin", "linux"] and arch in ["arm64", "x86_64"],
    do: {:ok, {os, arch}}

  defp resolve_target(other), do: {:error, "unsupported target: #{inspect(other)}"}

  defp resolve_base_url(%{release_url: url}) when is_binary(url) and url != "" do
    {:ok, String.trim_trailing(url, "/")}
  end

  defp resolve_base_url(%{version: "latest"}), do: {:ok, @default_latest_url}

  defp resolve_base_url(%{version: ver}) when is_binary(ver) do
    clean = String.trim_leading(ver, "v")

    if Regex.match?(~r/^[0-9A-Za-z][0-9A-Za-z._-]*$/, clean) do
      {:ok, String.replace(@default_tag_template, "%{version}", clean)}
    else
      {:error, "invalid version string: #{inspect(ver)}"}
    end
  end

  defp ensure_http_started do
    with {:ok, _} <- Application.ensure_all_started(:inets),
         {:ok, _} <- Application.ensure_all_started(:ssl) do
      :ok
    else
      {:error, reason} -> {:error, "failed to start HTTP/TLS applications: #{inspect(reason)}"}
    end
  end

  defp http_get(url, redirects_left \\ @max_redirects)

  defp http_get(_url, 0), do: {:error, "too many HTTP redirects"}

  defp http_get(url, redirects_left) do
    uri = URI.parse(url)

    with :ok <- validate_url_scheme(uri) do
      http_opts = build_http_opts(uri)
      headers = [{~c"user-agent", ~c"h_setup/0.3.1"}]

      case :httpc.request(:get, {String.to_charlist(url), headers}, http_opts,
             body_format: :binary
           ) do
        {:ok, {{_, status, _}, _resp_headers, body}} when status in 200..299 ->
          {:ok, body}

        {:ok, {{_, status, _}, resp_headers, _body}} when status in [301, 302, 303, 307, 308] ->
          case find_header(resp_headers, "location") do
            nil ->
              {:error, "HTTP #{status} redirect missing Location header for #{url}"}

            location ->
              next_url = URI.merge(uri, location) |> URI.to_string()
              http_get(next_url, redirects_left - 1)
          end

        {:ok, {{_, status, _}, _resp_headers, _body}} ->
          {:error, "HTTP #{status} downloading #{url}"}

        {:error, reason} ->
          {:error, "network error downloading #{url}: #{inspect(reason)}"}
      end
    end
  end

  defp validate_url_scheme(%URI{scheme: "https", host: host}) when is_binary(host) and host != "",
    do: :ok

  defp validate_url_scheme(%URI{scheme: "http", host: host})
       when host in ["127.0.0.1", "localhost", "::1"], do: :ok

  defp validate_url_scheme(%URI{scheme: scheme, host: host}) do
    {:error, "refusing insecure URL #{scheme}://#{host} (HTTPS required except loopback)"}
  end

  defp build_http_opts(%URI{scheme: "https", host: host}) do
    ssl_opts = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]

    [ssl: ssl_opts, autoredirect: false, timeout: 60_000, connect_timeout: 15_000]
  end

  defp build_http_opts(_uri) do
    [autoredirect: false, timeout: 60_000, connect_timeout: 15_000]
  end

  defp find_header(headers, name) do
    target = String.downcase(name)

    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(List.to_string(k)) == target, do: List.to_string(v)
    end)
  end

  defp validate_sha_hex(sha) do
    if Regex.match?(~r/^[0-9a-f]{64}$/, sha) do
      :ok
    else
      {:error, "malformed SHA-256 digest in SHA256SUMS: #{inspect(sha)}"}
    end
  end

  defp validate_artifact_name(name) do
    if String.contains?(name, ["/", "\\", ".."]) or String.starts_with?(name, "-") or name == "" do
      {:error, "invalid artifact filename in SHA256SUMS: #{inspect(name)}"}
    else
      :ok
    end
  end

  defp verify_sha256(bin, expected_sha, tarball) do
    actual = :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)

    if actual === expected_sha do
      :ok
    else
      {:error, "SHA-256 mismatch for #{tarball} (expected #{expected_sha}, got #{actual})"}
    end
  end

  defp install_tarball(tarball_bin, tarball, os, opts, log) do
    prefix = Path.expand(opts.prefix)
    bin_dir = Path.expand(opts.bin_dir)
    data_dir = Path.expand(opts.data_dir)
    releases_dir = Path.join(prefix, "releases")
    current_link = Path.join(prefix, "current")

    with :ok <- check_not_non_symlink(current_link),
         :ok <- check_not_non_symlink(Path.join(bin_dir, "hi")),
         :ok <- check_not_non_symlink(Path.join(bin_dir, "hi-import")) do
      with_temp_dir(fn tmp_dir ->
        extract_dir = Path.join(tmp_dir, "extract")
        File.mkdir_p!(extract_dir)

        with :ok <- safe_extract_tar_gz(tarball_bin, extract_dir),
             {:ok, bundle_src} <- locate_bundle_root(extract_dir),
             :ok <- validate_bundle(bundle_src),
             :ok <- File.mkdir_p(releases_dir),
             :ok <- File.mkdir_p(bin_dir),
             _ <- File.chmod(prefix, 0o700) do
          previous_release = read_current_target(current_link, prefix)
          release_id = make_release_id(tarball)
          dest = Path.join(releases_dir, release_id)

          with :ok <- move_directory(bundle_src, dest),
               :ok <- atomic_switch_symlink(current_link, Path.join("releases", release_id)),
               :ok <- link_tool(Path.join(current_link, "bin/hi"), Path.join(bin_dir, "hi")),
               :ok <- maybe_link_import(dest, current_link, bin_dir),
               :ok <- maybe_setup_service(opts.service, os, current_link, data_dir, log) do
            log.("Installed #{release_id} -> #{current_link}")

            if previous_release do
              log.("Previous release retained: #{previous_release}")
            end

            {:ok,
             %{
               release_id: release_id,
               release_dir: dest,
               current_link: current_link,
               previous_release: previous_release,
               bin_dir: bin_dir
             }}
          end
        end
      end)
    end
  end

  defp safe_extract_tar_gz(tarball_bin, extract_dir) do
    case :erl_tar.table({:binary, tarball_bin}, [:compressed, :verbose]) do
      {:ok, entries} ->
        with :ok <- validate_tar_entries(entries) do
          case :erl_tar.extract({:binary, tarball_bin}, [
                 :compressed,
                 {:cwd, String.to_charlist(extract_dir)}
               ]) do
            :ok -> validate_extracted_symlinks(extract_dir)
            {:error, reason} -> {:error, "failed to extract archive: #{inspect(reason)}"}
          end
        end

      {:error, reason} ->
        {:error, "failed to inspect archive: #{inspect(reason)}"}
    end
  end

  defp validate_tar_entries(entries) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      {name_chars, type, _size, _mtime, _mode, _uid, _gid} = entry
      name = List.to_string(name_chars)

      cond do
        String.starts_with?(name, "/") ->
          {:halt, {:error, "archive contains absolute path: #{name}"}}

        ".." in Path.split(name) ->
          {:halt, {:error, "archive contains path traversal entry: #{name}"}}

        type not in [:regular, :directory, :symlink] ->
          {:halt, {:error, "archive contains unsupported entry type #{inspect(type)}: #{name}"}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_extracted_symlinks(extract_dir) do
    canonical_root = Path.expand(extract_dir)
    root_prefix = canonical_root <> "/"

    extract_dir
    |> walk_paths()
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case File.read_link(path) do
        {:ok, target} ->
          cond do
            Path.type(target) == :absolute ->
              {:halt, {:error, "archive contains absolute symlink: #{path} -> #{target}"}}

            not symlink_within_root?(path, target, canonical_root, root_prefix) ->
              {:halt, {:error, "archive contains escaping symlink: #{path} -> #{target}"}}

            true ->
              {:cont, :ok}
          end

        {:error, _} ->
          {:cont, :ok}
      end
    end)
  end

  defp symlink_within_root?(link_path, target, canonical_root, root_prefix) do
    resolved = Path.expand(target, Path.dirname(link_path))
    resolved == canonical_root or String.starts_with?(resolved, root_prefix)
  end

  defp walk_paths(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          full = Path.join(dir, entry)

          case File.lstat(full) do
            {:ok, %File.Stat{type: :directory}} -> [full | walk_paths(full)]
            {:ok, _} -> [full]
            {:error, _} -> []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp locate_bundle_root(extract_dir) do
    if File.regular?(Path.join(extract_dir, "bin/hi")) do
      {:ok, extract_dir}
    else
      case File.ls(extract_dir) do
        {:ok, entries} ->
          dirs = Enum.filter(entries, &File.dir?(Path.join(extract_dir, &1)))

          case dirs do
            [single] ->
              candidate = Path.join(extract_dir, single)

              if File.regular?(Path.join(candidate, "bin/hi")),
                do: {:ok, candidate},
                else: {:error, "downloaded archive does not contain bin/hi"}

            _ ->
              {:error, "downloaded archive does not contain a valid Harness bundle root"}
          end

        {:error, reason} ->
          {:error, "failed to inspect extracted archive: #{inspect(reason)}"}
      end
    end
  end

  defp validate_bundle(bundle_dir) do
    required_execs = ["bin/hi", "bin/h-daemon"]
    start_erl = Path.join(bundle_dir, "releases/start_erl.data")

    cond do
      not File.regular?(start_erl) ->
        {:error, "downloaded archive is missing releases/start_erl.data"}

      not Enum.all?(required_execs, &executable_file?(Path.join(bundle_dir, &1))) ->
        {:error, "downloaded archive is missing executable bin/hi or bin/h-daemon"}

      true ->
        validate_optional_manifest(bundle_dir)
    end
  end

  defp validate_optional_manifest(bundle_dir) do
    manifest = Path.join(bundle_dir, "BUILD_MANIFEST.json")

    if File.regular?(manifest) do
      case File.read(manifest) do
        {:ok, bin} ->
          case :json.decode(bin) do
            %{} -> :ok
            _ -> {:error, "BUILD_MANIFEST.json is not a JSON object"}
          end

        {:error, reason} ->
          {:error, "failed to read BUILD_MANIFEST.json: #{inspect(reason)}"}
      end
    else
      :ok
    end
  rescue
    _ -> {:error, "BUILD_MANIFEST.json is not valid JSON"}
  end

  defp executable_file?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp check_not_non_symlink(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> :ok
      {:ok, _} -> {:error, "refusing to replace existing non-symlink: #{path}"}
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, "cannot inspect #{path}: #{inspect(reason)}"}
    end
  end

  defp read_current_target(current_link, prefix) do
    case File.read_link(current_link) do
      {:ok, target} -> Path.expand(target, prefix)
      {:error, _} -> nil
    end
  end

  defp make_release_id(tarball) do
    stem = String.replace_suffix(tarball, ".tar.gz", "")
    {{y, mo, d}, {h, mi, s}} = :calendar.universal_time()

    ts =
      :io_lib.format("~4..0B~2..0B~2..0B~2..0B~2..0B~2..0B", [y, mo, d, h, mi, s])
      |> IO.iodata_to_binary()

    rand = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "#{stem}-#{ts}-#{rand}"
  end

  defp move_directory(src, dest) do
    case File.rename(src, dest) do
      :ok ->
        :ok

      {:error, :exdev} ->
        case File.cp_r(src, dest) do
          {:ok, _} -> :ok
          {:error, reason, file} -> {:error, "failed copying #{file}: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "failed moving bundle to #{dest}: #{inspect(reason)}"}
    end
  end

  defp atomic_switch_symlink(link_path, target) do
    parent = Path.dirname(link_path)
    rand = :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
    stage = Path.join(parent, ".current-#{rand}")

    with :ok <- File.ln_s(target, stage) do
      case File.rename(stage, link_path) do
        :ok ->
          :ok

        {:error, reason} ->
          File.rm(stage)
          {:error, "failed to switch symlink #{link_path}: #{inspect(reason)}"}
      end
    else
      {:error, reason} -> {:error, "failed to stage symlink #{stage}: #{inspect(reason)}"}
    end
  end

  defp link_tool(target, link_path) do
    atomic_switch_symlink(link_path, target)
  end

  defp maybe_link_import(dest, current_link, bin_dir) do
    if executable_file?(Path.join(dest, "bin/hi-import")) do
      link_tool(Path.join(current_link, "bin/hi-import"), Path.join(bin_dir, "hi-import"))
    else
      :ok
    end
  end

  defp maybe_setup_service(false, _os, _current_link, _data_dir, _log), do: :ok

  defp maybe_setup_service(true, "darwin", current_link, data_dir, log) do
    with :ok <- File.mkdir_p(data_dir),
         :ok <- File.chmod(data_dir, 0o700) do
      hi = Path.join(current_link, "bin/hi")
      launcher = Path.join(current_link, "bin/h-daemon")

      args =
        case System.cmd(hi, ["daemon", "check-service", "--data-dir", data_dir],
               env: [{"H_DATA_DIR", data_dir}],
               stderr_to_stdout: true
             ) do
          {_, 0} -> ["daemon", "restart-service"]
          _ -> ["daemon", "install-service", "--launcher", launcher]
        end

      case System.cmd(hi, args,
             env: [{"H_DATA_DIR", data_dir}],
             stderr_to_stdout: true
           ) do
        {out, 0} ->
          if String.trim(out) != "", do: log.(String.trim(out))
          :ok

        {out, code} ->
          {:error, "hi #{Enum.join(args, " ")} exited #{code}: #{String.trim(out)}"}
      end
    end
  end

  defp maybe_setup_service(true, "linux", current_link, data_dir, log) do
    xdg = System.get_env("XDG_CONFIG_HOME") || Path.join(System.user_home!(), ".config")
    unit_dir = Path.join(xdg, "systemd/user")
    unit_path = Path.join(unit_dir, "harness-daemon.service")
    launcher = Path.join(current_link, "bin/h-daemon")

    with :ok <- validate_systemd_path(launcher),
         :ok <- validate_systemd_path(data_dir),
         :ok <- File.mkdir_p(data_dir),
         :ok <- File.chmod(data_dir, 0o700),
         :ok <- File.mkdir_p(unit_dir),
         :ok <- File.write(unit_path, systemd_unit_text(launcher, data_dir)),
         :ok <- File.chmod(unit_path, 0o600),
         :ok <- run_systemctl(["--user", "daemon-reload"]),
         :ok <- run_systemctl(["--user", "enable", "harness-daemon.service"]),
         :ok <- run_systemctl(["--user", "restart", "harness-daemon.service"]) do
      log.("Installed systemd user service: #{unit_path}")
      :ok
    end
  end

  defp validate_systemd_path(path) do
    if String.contains?(path, ["\n", "\r", "\""]) do
      {:error, "service path contains unsupported characters: #{inspect(path)}"}
    else
      :ok
    end
  end

  defp systemd_unit_text(launcher, data_dir) do
    """
    [Unit]
    Description=Harness (H) Daemon
    After=network-online.target

    [Service]
    Type=simple
    ExecStart="#{launcher}" --data-dir "#{data_dir}"
    WorkingDirectory=#{data_dir}
    Restart=on-failure
    RestartSec=5
    TimeoutStopSec=660

    [Install]
    WantedBy=default.target
    """
  end

  defp run_systemctl(args) do
    case System.find_executable("systemctl") do
      nil ->
        {:error, "systemctl is required for --service on Linux"}

      exe ->
        case System.cmd(exe, args, stderr_to_stdout: true) do
          {_out, 0} ->
            :ok

          {out, code} ->
            {:error, "systemctl #{Enum.join(args, " ")} exited #{code}: #{String.trim(out)}"}
        end
    end
  end

  defp with_temp_dir(fun) do
    base = System.tmp_dir!()
    rand = :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
    dir = Path.join(base, "h-setup-#{rand}")
    File.mkdir_p!(dir)

    try do
      fun.(dir)
    after
      File.rm_rf(dir)
    end
  end
end
