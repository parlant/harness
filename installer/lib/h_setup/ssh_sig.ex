defmodule HSetup.SshSig do
  @moduledoc """
  Pure-Erlang verifier for OpenSSH `SSHSIG` (`-----BEGIN SSH SIGNATURE-----`) Ed25519 signatures.

  Implements the `PROTOCOL.sshsig` wire format using Erlang `:crypto.verify/5`, requiring no
  external `ssh-keygen` binary.
  """

  @default_signer_pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKsOhoxQkZ8pxWeObg2Q10fJ/Gcg0uL4pt1Oy/3vgLuN"
  @begin_marker "-----BEGIN SSH SIGNATURE-----"
  @end_marker "-----END SSH SIGNATURE-----"

  @doc """
  Returns the pinned Harness release signing public key.
  """
  @spec default_signer_pubkey() :: String.t()
  def default_signer_pubkey, do: @default_signer_pubkey

  @doc """
  Verifies an armored OpenSSH `SSHSIG` signature over `data` against an expected
  `ssh-ed25519 <base64>` public key and namespace (default `"file"`).
  """
  @spec verify(binary(), String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def verify(data, armored_sig, expected_pubkey \\ @default_signer_pubkey, namespace \\ "file")
      when is_binary(data) and is_binary(armored_sig) and is_binary(expected_pubkey) and
             is_binary(namespace) do
    with {:ok, expected_blob, expected_raw_pk} <- parse_ed25519_pubkey(expected_pubkey),
         {:ok, raw_sig_struct} <- decode_armor(armored_sig),
         {:ok, parsed} <- parse_sshsig(raw_sig_struct),
         :ok <- check_signer(parsed.pubkey_blob, expected_blob),
         :ok <- check_namespace(parsed.namespace, namespace),
         {:ok, hash_alg} <- parse_hash_alg(parsed.hash_alg),
         {:ok, raw_sig} <- parse_ed25519_sig_blob(parsed.signature_blob) do
      digest = :crypto.hash(hash_alg, data)
      signed_data = build_signed_data(parsed.namespace, parsed.reserved, parsed.hash_alg, digest)

      if :crypto.verify(:eddsa, :none, signed_data, raw_sig, [expected_raw_pk, :ed25519]) do
        :ok
      else
        {:error, "Ed25519 signature verification failed"}
      end
    end
  end

  defp parse_ed25519_pubkey(pubkey_str) do
    case String.split(String.trim(pubkey_str)) do
      ["ssh-ed25519", b64 | _] ->
        case Base.decode64(b64) do
          {:ok, <<11::32, "ssh-ed25519", 32::32, raw_pk::binary-size(32)>> = blob} ->
            {:ok, blob, raw_pk}

          _ ->
            {:error, "invalid ssh-ed25519 public key encoding"}
        end

      _ ->
        {:error, "expected an ssh-ed25519 public key"}
    end
  end

  defp decode_armor(armored) do
    lines =
      armored
      |> String.split(~r/\r?\n/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case lines do
      [@begin_marker | rest] ->
        case List.pop_at(rest, -1) do
          {@end_marker, body_lines} when body_lines != [] ->
            body_lines
            |> Enum.join()
            |> Base.decode64()
            |> case do
              {:ok, bin} -> {:ok, bin}
              :error -> {:error, "malformed base64 in SSH signature armor"}
            end

          _ ->
            {:error, "missing SSH signature end marker"}
        end

      _ ->
        {:error, "missing SSH signature begin marker"}
    end
  end

  defp parse_sshsig(
         <<"SSHSIG", 1::32, pk_len::32, pk_blob::binary-size(pk_len), ns_len::32,
           ns::binary-size(ns_len), res_len::32, res::binary-size(res_len), ha_len::32,
           ha::binary-size(ha_len), sig_len::32, sig_blob::binary-size(sig_len)>>
       ) do
    {:ok,
     %{
       pubkey_blob: pk_blob,
       namespace: ns,
       reserved: res,
       hash_alg: ha,
       signature_blob: sig_blob
     }}
  end

  defp parse_sshsig(_), do: {:error, "malformed SSHSIG binary structure"}

  defp check_signer(actual_blob, expected_blob) when actual_blob === expected_blob, do: :ok

  defp check_signer(_, _),
    do: {:error, "signature public key does not match trusted release signer"}

  defp check_namespace(actual, expected) when actual === expected, do: :ok

  defp check_namespace(actual, expected),
    do: {:error, "unexpected SSHSIG namespace #{inspect(actual)} (expected #{inspect(expected)})"}

  defp parse_hash_alg("sha512"), do: {:ok, :sha512}
  defp parse_hash_alg("sha256"), do: {:ok, :sha256}
  defp parse_hash_alg(other), do: {:error, "unsupported SSHSIG hash algorithm: #{inspect(other)}"}

  defp parse_ed25519_sig_blob(<<11::32, "ssh-ed25519", 64::32, raw_sig::binary-size(64)>>) do
    {:ok, raw_sig}
  end

  defp parse_ed25519_sig_blob(_), do: {:error, "malformed ssh-ed25519 signature blob"}

  defp build_signed_data(ns, reserved, hash_alg, digest) do
    <<"SSHSIG", byte_size(ns)::32, ns::binary, byte_size(reserved)::32, reserved::binary,
      byte_size(hash_alg)::32, hash_alg::binary, byte_size(digest)::32, digest::binary>>
  end
end
