defmodule HSetup.SetupTaskTest do
  use ExUnit.Case, async: false

  alias HSetup.Installer

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    # Capture Mix shell output cleanly without printing to stdout
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    key_good = Path.join(tmp_dir, "good_ed25519")
    key_bad = Path.join(tmp_dir, "bad_ed25519")
    {_, 0} = System.cmd("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", key_good])
    {_, 0} = System.cmd("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", key_bad])
    good_pub = File.read!(key_good <> ".pub") |> String.trim()

    {:ok, %{key_good: key_good, key_bad: key_bad, good_pub: good_pub}}
  end

  test "end-to-end fresh install, upgrade, rollback retention, and refusal on bad checksum/sig",
       %{
         tmp_dir: tmp_dir,
         key_good: key_good,
         key_bad: key_bad,
         good_pub: good_pub
       } do
    {:ok, {os, arch}} = Installer.detect_target()
    target = "#{os}-#{arch}"

    v1_tar = build_fixture_tarball!(tmp_dir, "0.1.0", target)
    v2_tar = build_fixture_tarball!(tmp_dir, "0.2.0", target)

    v1_name = "harness-v0.1.0-#{target}.tar.gz"
    v2_name = "harness-v0.2.0-#{target}.tar.gz"

    v1_sha = sha256_hex(v1_tar)
    v2_sha = sha256_hex(v2_tar)

    v1_sums = "#{v1_sha}  #{v1_name}\n"
    v2_sums = "#{v2_sha}  #{v2_name}\n"
    v1_sig = sign_bytes!(tmp_dir, key_good, "v1_sums", v1_sums)
    v2_sig = sign_bytes!(tmp_dir, key_good, "v2_sums", v2_sums)
    bad_sig = sign_bytes!(tmp_dir, key_bad, "bad_sums", v2_sums)

    routes = %{
      "/v1/SHA256SUMS" => v1_sums,
      "/v1/SHA256SUMS.sig" => v1_sig,
      "/v1/#{v1_name}" => v1_tar,
      "/v2/SHA256SUMS" => v2_sums,
      "/v2/SHA256SUMS.sig" => v2_sig,
      "/v2/#{v2_name}" => v2_tar,
      "/corrupt/SHA256SUMS" => v2_sums,
      "/corrupt/SHA256SUMS.sig" => v2_sig,
      "/corrupt/#{v2_name}" => "corrupted-bytes",
      "/badsig/SHA256SUMS" => v2_sums,
      "/badsig/SHA256SUMS.sig" => bad_sig,
      "/badsig/#{v2_name}" => v2_tar
    }

    {port, stop_server} = start_loopback_http!(routes)
    on_exit(stop_server)

    prefix = Path.join(tmp_dir, "prefix")
    bin_dir = Path.join(tmp_dir, "bin")

    # 1. Fresh install via Mix.Tasks.H.Setup.run/1
    assert :ok =
             Mix.Tasks.H.Setup.run([
               "--release-url",
               "http://127.0.0.1:#{port}/v1",
               "--prefix",
               prefix,
               "--bin-dir",
               bin_dir,
               "--signer-pubkey",
               good_pub
             ])

    current = Path.join(prefix, "current")
    assert {:ok, rel1_target} = File.read_link(current)
    rel1_dir = Path.expand(rel1_target, prefix)
    assert File.dir?(rel1_dir)

    hi_link = Path.join(bin_dir, "hi")
    import_link = Path.join(bin_dir, "hi-import")
    assert {:ok, _} = File.read_link(hi_link)
    assert {:ok, _} = File.read_link(import_link)
    assert {"hi-0.1.0\n", 0} = System.cmd(hi_link, [])
    assert {"hi-import-0.1.0\n", 0} = System.cmd(import_link, [])

    # 2. Upgrade to v2 switches current atomically and retains v1
    assert :ok =
             Mix.Tasks.H.Setup.run([
               "--release-url",
               "http://127.0.0.1:#{port}/v2",
               "--prefix",
               prefix,
               "--bin-dir",
               bin_dir,
               "--signer-pubkey",
               good_pub
             ])

    assert {:ok, rel2_target} = File.read_link(current)
    rel2_dir = Path.expand(rel2_target, prefix)
    assert rel2_dir != rel1_dir
    assert File.dir?(rel1_dir)
    assert File.dir?(rel2_dir)
    assert {"hi-0.2.0\n", 0} = System.cmd(hi_link, [])

    # 3. Corrupted tarball is rejected; current stays on v2
    assert_raise Mix.Error, ~r/SHA-256 mismatch/, fn ->
      Mix.Tasks.H.Setup.run([
        "--release-url",
        "http://127.0.0.1:#{port}/corrupt",
        "--prefix",
        prefix,
        "--bin-dir",
        bin_dir,
        "--signer-pubkey",
        good_pub
      ])
    end

    assert {:ok, ^rel2_target} = File.read_link(current)

    # 4. Wrong signer signature is rejected; fresh prefix not created
    bad_prefix = Path.join(tmp_dir, "bad_prefix")
    bad_bin = Path.join(tmp_dir, "bad_bin")

    assert_raise Mix.Error, ~r/does not match trusted release signer/, fn ->
      Mix.Tasks.H.Setup.run([
        "--release-url",
        "http://127.0.0.1:#{port}/badsig",
        "--prefix",
        bad_prefix,
        "--bin-dir",
        bad_bin,
        "--signer-pubkey",
        good_pub
      ])
    end

    refute File.exists?(bad_prefix)
  end

  test "rejects tarballs containing path traversal entries", %{
    tmp_dir: tmp_dir,
    key_good: key_good,
    good_pub: good_pub
  } do
    tar_path = Path.join(tmp_dir, "evil.tar.gz")

    :ok =
      :erl_tar.create(String.to_charlist(tar_path), [{~c"../escape.txt", "boom"}], [:compressed])

    evil_tar = File.read!(tar_path)
    name = "harness-v0.1.0-linux-x86_64.tar.gz"
    sums = "#{sha256_hex(evil_tar)}  #{name}\n"
    sig = sign_bytes!(tmp_dir, key_good, "evil_sums", sums)

    routes = %{
      "/SHA256SUMS" => sums,
      "/SHA256SUMS.sig" => sig,
      "/#{name}" => evil_tar
    }

    {port, stop_server} = start_loopback_http!(routes)
    on_exit(stop_server)

    prefix = Path.join(tmp_dir, "evil_prefix")
    bin_dir = Path.join(tmp_dir, "evil_bin")

    assert_raise Mix.Error, ~r/path traversal/, fn ->
      Mix.Tasks.H.Setup.run([
        "--release-url",
        "http://127.0.0.1:#{port}",
        "--target",
        "linux-x86_64",
        "--prefix",
        prefix,
        "--bin-dir",
        bin_dir,
        "--signer-pubkey",
        good_pub
      ])
    end

    refute File.exists?(prefix)
  end

  test "installs Linux systemd --user unit when --service is passed", %{
    tmp_dir: tmp_dir,
    key_good: key_good,
    good_pub: good_pub
  } do
    tar = build_fixture_tarball!(tmp_dir, "0.1.0", "linux-x86_64")
    name = "harness-v0.1.0-linux-x86_64.tar.gz"
    sums = "#{sha256_hex(tar)}  #{name}\n"
    sig = sign_bytes!(tmp_dir, key_good, "linux_sums", sums)

    routes = %{
      "/SHA256SUMS" => sums,
      "/SHA256SUMS.sig" => sig,
      "/#{name}" => tar
    }

    {port, stop_server} = start_loopback_http!(routes)
    on_exit(stop_server)

    fake_bin = Path.join(tmp_dir, "fake_bin")
    File.mkdir_p!(fake_bin)
    log_file = Path.join(tmp_dir, "systemctl.log")
    fake_sc = Path.join(fake_bin, "systemctl")
    File.write!(fake_sc, "#!/bin/sh\necho \"$*\" >> \"#{log_file}\"\n")
    File.chmod!(fake_sc, 0o755)

    old_path = System.get_env("PATH")
    old_xdg = System.get_env("XDG_CONFIG_HOME")
    xdg = Path.join(tmp_dir, "xdg")

    System.put_env("PATH", "#{fake_bin}:#{old_path}")
    System.put_env("XDG_CONFIG_HOME", xdg)

    on_exit(fn ->
      System.put_env("PATH", old_path)

      if old_xdg do
        System.put_env("XDG_CONFIG_HOME", old_xdg)
      else
        System.delete_env("XDG_CONFIG_HOME")
      end
    end)

    prefix = Path.join(tmp_dir, "linux_prefix")
    bin_dir = Path.join(tmp_dir, "linux_bin")
    data_dir = Path.join(tmp_dir, "linux_data")

    assert :ok =
             Mix.Tasks.H.Setup.run([
               "--release-url",
               "http://127.0.0.1:#{port}",
               "--target",
               "linux-x86_64",
               "--prefix",
               prefix,
               "--bin-dir",
               bin_dir,
               "--data-dir",
               data_dir,
               "--service",
               "--signer-pubkey",
               good_pub
             ])

    unit_path = Path.join(xdg, "systemd/user/harness-daemon.service")
    assert File.regular?(unit_path)
    unit_text = File.read!(unit_path)

    assert unit_text =~
             ~s(ExecStart="#{Path.join(prefix, "current/bin/h-daemon")}" --data-dir "#{data_dir}")

    assert unit_text =~ "Restart=on-failure"
    assert unit_text =~ "TimeoutStopSec=660"

    assert File.read!(log_file) |> String.split("\n", trim: true) == [
             "--user daemon-reload",
             "--user enable harness-daemon.service",
             "--user restart harness-daemon.service"
           ]
  end

  test "cascades writable PATH bin directories and falls back to ~/.bin last", %{tmp_dir: tmp_dir} do
    home = Path.join(tmp_dir, "home")
    pref1 = Path.join(tmp_dir, "usr_local_bin")
    pref2 = Path.join(tmp_dir, "opt_local_bin")
    pref3 = Path.join(tmp_dir, "opt_homebrew_bin")
    custom_path_bin = Path.join(tmp_dir, "user_bin")
    shim_bin = Path.join(tmp_dir, "asdf/shims")
    cargo_bin = Path.join(home, ".cargo/bin")
    local_bin = Path.join(home, ".local/bin")
    home_bin = Path.join(home, ".bin")

    for dir <- [home, pref1, pref2, pref3, custom_path_bin, shim_bin, cargo_bin, home_bin] do
      File.mkdir_p!(dir)
    end

    on_exit(fn ->
      File.chmod(pref1, 0o755)
      File.chmod(pref2, 0o755)
      File.chmod(pref3, 0o755)
    end)

    preferred = [pref1, pref2, pref3]

    # 1. Explicit bin_dir always wins
    assert Path.join(tmp_dir, "explicit") ==
             Installer.select_bin_dir(
               explicit: Path.join(tmp_dir, "explicit"),
               home: home,
               path: "#{pref1}:#{home_bin}",
               preferred: preferred
             )

    # 2. Writable preferred dir on PATH wins over ~/.bin even if ~/.bin appears earlier in PATH
    assert pref1 ==
             Installer.select_bin_dir(
               home: home,
               path: "#{home_bin}:#{pref2}:#{pref1}",
               preferred: preferred
             )

    # 3. Non-writable first preferred dir is skipped in favor of next writable preferred dir.
    #    (In root CI containers, chmod 0555 remains writable by UID 0, so also support missing/unwritable paths.)
    File.chmod!(pref1, 0o555)

    unwritable_pref1 =
      if File.stat!(pref1).access in [:read_write, :write],
        do: Path.join(tmp_dir, "missing/usr_local_bin"),
        else: pref1

    unwritable_pref2 = Path.join(tmp_dir, "missing/opt_local_bin")
    unwritable_pref3 = Path.join(tmp_dir, "missing/opt_homebrew_bin")

    assert pref2 ==
             Installer.select_bin_dir(
               home: home,
               path: "#{unwritable_pref1}:#{pref2}:#{home_bin}",
               preferred: [unwritable_pref1, pref2, pref3]
             )

    # 4. ~/.local/bin on PATH (creatable under writable home) wins over arbitrary PATH dirs and ~/.bin
    File.chmod!(pref2, 0o555)
    File.chmod!(pref3, 0o555)

    unwritable_preferred =
      if File.stat!(pref2).access in [:read_write, :write],
        do: [unwritable_pref1, unwritable_pref2, unwritable_pref3],
        else: preferred

    assert local_bin ==
             Installer.select_bin_dir(
               home: home,
               path:
                 "#{unwritable_pref1}:#{unwritable_pref2}:#{custom_path_bin}:#{local_bin}:#{home_bin}",
               preferred: unwritable_preferred
             )

    # 5. Shims / .cargo/bin / relative dirs are skipped; other writable PATH dir beats ~/.bin
    assert custom_path_bin ==
             Installer.select_bin_dir(
               home: home,
               path: ".:#{shim_bin}:#{cargo_bin}:#{home_bin}:#{custom_path_bin}",
               preferred: unwritable_preferred
             )

    # 6. ~/.bin is selected when it is the only writable non-excluded dir on PATH
    assert home_bin ==
             Installer.select_bin_dir(
               home: home,
               path: "#{unwritable_pref1}:#{shim_bin}:#{cargo_bin}:#{home_bin}",
               preferred: unwritable_preferred
             )

    # 7. When nothing writable is on PATH and no preferred/local_bin is writable, falls back to ~/.bin last
    assert home_bin ==
             Installer.select_bin_dir(
               home: home,
               path: "/usr/bin:/bin",
               preferred: unwritable_preferred
             )
  end

  test "refuses non-HTTPS remote URLs" do
    assert_raise Mix.Error, ~r/refusing insecure URL/, fn ->
      Mix.Tasks.H.Setup.run([
        "--release-url",
        "http://example.com/releases"
      ])
    end
  end

  defp build_fixture_tarball!(tmp_dir, version, target) do
    stage = Path.join(tmp_dir, "fixture-#{version}-#{target}")
    root_name = "harness-v#{version}-#{target}"
    bundle_dir = Path.join(stage, root_name)
    File.mkdir_p!(Path.join(bundle_dir, "bin"))
    File.mkdir_p!(Path.join(bundle_dir, "releases"))

    hi = Path.join(bundle_dir, "bin/hi")
    File.write!(hi, "#!/bin/sh\necho hi-#{version}\n")
    File.chmod!(hi, 0o755)

    hi_import = Path.join(bundle_dir, "bin/hi-import")
    File.write!(hi_import, "#!/bin/sh\necho hi-import-#{version}\n")
    File.chmod!(hi_import, 0o755)

    daemon = Path.join(bundle_dir, "bin/h-daemon")
    File.write!(daemon, "#!/bin/sh\necho h-daemon-#{version}\n")
    File.chmod!(daemon, 0o755)

    File.write!(Path.join(bundle_dir, "releases/start_erl.data"), "17.1.1 0.1.0\n")
    File.write!(Path.join(bundle_dir, "BUILD_MANIFEST.json"), ~s({"version":"#{version}"}\n))

    tar_path = Path.join(tmp_dir, "#{root_name}.tar.gz")

    :ok =
      :erl_tar.create(
        String.to_charlist(tar_path),
        [{String.to_charlist(root_name), String.to_charlist(bundle_dir)}],
        [:compressed]
      )

    File.read!(tar_path)
  end

  defp sha256_hex(bin), do: :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)

  defp sign_bytes!(tmp_dir, key_path, name, bytes) do
    file = Path.join(tmp_dir, name)
    File.write!(file, bytes)
    {_, 0} = System.cmd("ssh-keygen", ["-q", "-Y", "sign", "-f", key_path, "-n", "file", file])
    File.read!(file <> ".sig")
  end

  defp start_loopback_http!(routes) do
    {:ok, listen_sock} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :http_bin,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen_sock)
    pid = spawn_link(fn -> accept_loop(listen_sock, routes) end)

    stop = fn ->
      :gen_tcp.close(listen_sock)
      Process.unlink(pid)
      Process.exit(pid, :normal)
    end

    {port, stop}
  end

  defp accept_loop(listen_sock, routes) do
    case :gen_tcp.accept(listen_sock) do
      {:ok, sock} ->
        spawn(fn -> handle_conn(sock, routes) end)
        accept_loop(listen_sock, routes)

      {:error, _} ->
        :ok
    end
  end

  defp handle_conn(sock, routes) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, {:http_request, :GET, {:abs_path, path}, _}} ->
        drain_headers(sock)

        {status, body} =
          case Map.fetch(routes, path) do
            {:ok, payload} -> {"200 OK", payload}
            :error -> {"404 Not Found", "not found"}
          end

        response = [
          "HTTP/1.1 ",
          status,
          "\r\nContent-Length: ",
          Integer.to_string(byte_size(body)),
          "\r\nConnection: close\r\n\r\n",
          body
        ]

        :gen_tcp.send(sock, response)

      _ ->
        :ok
    end

    :gen_tcp.close(sock)
  end

  defp drain_headers(sock) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, :http_eoh} -> :ok
      {:ok, {:http_header, _, _, _, _}} -> drain_headers(sock)
      _ -> :ok
    end
  end
end
