defmodule HSetup.SshSigTest do
  use ExUnit.Case, async: true

  alias HSetup.SshSig

  @moduletag :tmp_dir

  test "verifies a real ssh-keygen -Y sign Ed25519 signature", %{tmp_dir: tmp_dir} do
    {key_path, pubkey} = generate_ed25519_keypair!(tmp_dir, "signer")

    data =
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  harness-v0.1.0-darwin-arm64.tar.gz\n"

    sig = sign_with_ssh_keygen!(tmp_dir, key_path, "SHA256SUMS", data)

    assert :ok = SshSig.verify(data, sig, pubkey, "file")
  end

  test "rejects tampered payload bytes", %{tmp_dir: tmp_dir} do
    {key_path, pubkey} = generate_ed25519_keypair!(tmp_dir, "signer")
    data = "deadbeef  harness-v0.1.0-darwin-arm64.tar.gz\n"
    sig = sign_with_ssh_keygen!(tmp_dir, key_path, "SHA256SUMS", data)

    assert {:error, msg} = SshSig.verify(data <> " ", sig, pubkey, "file")
    assert msg =~ "verification failed"
  end

  test "rejects signature made by a different Ed25519 key", %{tmp_dir: tmp_dir} do
    {signer_key, _signer_pub} = generate_ed25519_keypair!(tmp_dir, "actual")
    {_other_key, trusted_pub} = generate_ed25519_keypair!(tmp_dir, "trusted")
    data = "deadbeef  harness-v0.1.0-darwin-arm64.tar.gz\n"
    sig = sign_with_ssh_keygen!(tmp_dir, signer_key, "SHA256SUMS", data)

    assert {:error, msg} = SshSig.verify(data, sig, trusted_pub, "file")
    assert msg =~ "does not match trusted release signer"
  end

  test "rejects mismatched namespace", %{tmp_dir: tmp_dir} do
    {key_path, pubkey} = generate_ed25519_keypair!(tmp_dir, "signer")
    data = "hello"
    sig = sign_with_ssh_keygen!(tmp_dir, key_path, "msg", data, "git")

    assert {:error, msg} = SshSig.verify(data, sig, pubkey, "file")
    assert msg =~ "unexpected SSHSIG namespace"
  end

  test "rejects malformed armor and garbage input" do
    pub = SshSig.default_signer_pubkey()

    assert {:error, msg} = SshSig.verify("hello", "not an armor block", pub)
    assert msg =~ "begin marker"

    bad_b64 = """
    -----BEGIN SSH SIGNATURE-----
    !!!not-base64!!!
    -----END SSH SIGNATURE-----
    """

    assert {:error, msg} = SshSig.verify("hello", bad_b64, pub)
    assert msg =~ "base64"

    truncated = """
    -----BEGIN SSH SIGNATURE-----
    U1NIU0lHAAAAAQ==
    -----END SSH SIGNATURE-----
    """

    assert {:error, msg} = SshSig.verify("hello", truncated, pub)
    assert msg =~ "SSHSIG binary structure"
  end

  test "default pinned release signing key parses cleanly" do
    assert {:error, msg} = SshSig.verify("hello", "bad", SshSig.default_signer_pubkey())
    # Reached armor check, proving the pinned key decoded cleanly
    assert msg =~ "begin marker"
  end

  defp generate_ed25519_keypair!(tmp_dir, name) do
    key_path = Path.join(tmp_dir, name)
    {_, 0} = System.cmd("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", key_path])
    pub = File.read!(key_path <> ".pub") |> String.trim()
    {key_path, pub}
  end

  defp sign_with_ssh_keygen!(tmp_dir, key_path, filename, content, namespace \\ "file") do
    file_path = Path.join(tmp_dir, filename)
    File.write!(file_path, content)

    {_, 0} =
      System.cmd("ssh-keygen", ["-q", "-Y", "sign", "-f", key_path, "-n", namespace, file_path])

    File.read!(file_path <> ".sig")
  end
end
