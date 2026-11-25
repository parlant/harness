defmodule Extensions.EditorHost do
  @moduledoc """
  Optional live tool-host broker extension (`"editor_host"`, API 1).

  Provides:
    * `Extensions.EditorHost.Broker`: owner-paired short-lived host grants
      (SHA-256 + `Plug.Crypto.secure_compare/2`, single-claim, workspace-scoped),
      single live host generation fencing per workspace, concurrency-capped
      dispatch, and prompt `tool_unavailable` / `host_disconnected` /
      `tool_timeout` handling.
    * `Extensions.EditorHost.Harness` (`id: "editor_coding"`): standard coding
      tools plus `editor_buffer_summary`.
    * `Extensions.EditorHost.BufferSummaryTool` (`name: "editor_buffer_summary"`):
      read-only live editor buffer summary proxy requiring an `expected_revision`
      precondition.
    * `H.Extension.StatusProjection` (`namespace: "editor_host"`): cached,
      read-only host connection projection.
  """

  @behaviour H.Extension
  @behaviour H.Extension.StatusProjection

  alias Extensions.EditorHost.{Broker, Harness}

  @default_grant_ttl_ms 60_000
  @default_invocation_timeout_ms 5_000
  @default_max_summary_bytes 16_384
  @default_max_concurrency 4

  @allowed_setting_keys [
    "grant_ttl_ms",
    "invocation_timeout_ms",
    "max_summary_bytes",
    "max_concurrency",
    "socket_path",
    "http_port"
  ]

  @impl H.Extension
  def configure(settings, context) when is_map(settings) and is_map(context) do
    with [] <- Map.keys(settings) -- @allowed_setting_keys,
         {:ok, grant_ttl_ms} <-
           validate_int_range(settings, "grant_ttl_ms", 1_000..300_000, @default_grant_ttl_ms),
         {:ok, invocation_timeout_ms} <-
           validate_int_range(
             settings,
             "invocation_timeout_ms",
             500..60_000,
             @default_invocation_timeout_ms
           ),
         {:ok, max_summary_bytes} <-
           validate_int_range(
             settings,
             "max_summary_bytes",
             256..65_536,
             @default_max_summary_bytes
           ),
         {:ok, max_concurrency} <-
           validate_int_range(settings, "max_concurrency", 1..32, @default_max_concurrency),
         {:ok, socket_path} <- validate_socket_path(Map.get(settings, "socket_path")),
         {:ok, http_port} <- validate_http_port(Map.get(settings, "http_port")) do
      broker_opts = [
        grant_ttl_ms: grant_ttl_ms,
        invocation_timeout_ms: invocation_timeout_ms,
        max_summary_bytes: max_summary_bytes,
        max_concurrency: max_concurrency,
        socket_path: socket_path,
        http_port: http_port
      ]

      {:ok,
       %{
         harnesses: [Harness],
         status_projections: [%{namespace: "editor_host", module: __MODULE__}],
         children: [{Broker, broker_opts}]
       }}
    else
      _ -> {:error, :invalid_editor_host_settings}
    end
  end

  def configure(_, _), do: {:error, :invalid_editor_host_settings}

  @doc """
  Trusted owner operation to mint a short-lived, single-claim tool-host grant
  for `workspace_cwd`. Never returns or exposes the daemon owner token.
  """
  @spec issue_grant(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def issue_grant(workspace_cwd, opts \\ []) when is_binary(workspace_cwd) and is_list(opts) do
    Broker.issue_grant(workspace_cwd, opts)
  end

  @doc """
  Claims a previously issued host grant for a live editor host process or
  connection transport, binding it to a monotonic `host_generation`.
  """
  @spec claim_grant(String.t(), pid() | term(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def claim_grant(grant_token, host_ref, metadata, opts \\ [])
      when is_binary(grant_token) and is_map(metadata) and is_list(opts) do
    Broker.claim_grant(grant_token, host_ref, metadata, opts)
  end

  @doc """
  Returns the read-only `editor_host` status projection for `scope`.
  """
  @impl H.Extension.StatusProjection
  def project(scope) when is_map(scope) do
    if Process.whereis(Broker) do
      Broker.project_status(scope)
    else
      :omit
    end
  end

  def project(_), do: :omit

  defp validate_int_range(settings, key, range, default) do
    case Map.get(settings, key, default) do
      val when is_integer(val) ->
        if val in range, do: {:ok, val}, else: :error

      _ ->
        :error
    end
  end

  defp validate_socket_path(nil), do: {:ok, nil}

  defp validate_socket_path(path) when is_binary(path) do
    if byte_size(path) in 1..100 and String.valid?(path) and not String.contains?(path, <<0>>) and
         Path.type(path) == :absolute do
      {:ok, path}
    else
      :error
    end
  end

  defp validate_socket_path(_), do: :error

  defp validate_http_port(nil), do: {:ok, nil}

  defp validate_http_port(port) when is_integer(port) and port in 0..65_535, do: {:ok, port}
  defp validate_http_port(_), do: :error
end
