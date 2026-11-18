defmodule H.ExecutionEnv.Local do
  @moduledoc """
  Compatibility wrapper delegating to `H.ExecutionEnv.Host`.
  """

  @behaviour H.ExecutionEnv

  alias H.ExecutionEnv.Host

  @spec new(String.t(), keyword()) :: H.ExecutionEnv.t()
  def new(cwd \\ System.user_home!(), opts \\ []) when is_binary(cwd) and is_list(opts) do
    Host.new(cwd, opts)
  end

  @impl true
  defdelegate env_id(state), to: Host

  @impl true
  defdelegate kind(state), to: Host

  @impl true
  defdelegate cwd(state), to: Host

  @impl true
  defdelegate bind_cwd(state, cwd), to: Host

  @impl true
  defdelegate resolve_path(state, path), to: Host

  @impl true
  defdelegate canonical_path(state, path), to: Host

  @impl true
  defdelegate read_file_lines(state, path, opts \\ []), to: Host

  @impl true
  defdelegate read_file_bytes(state, path, opts \\ []), to: Host

  @impl true
  defdelegate write_file(state, path, content), to: Host

  @impl true
  defdelegate list_dir(state, path, opts \\ []), to: Host

  @impl true
  defdelegate list_files(state, path, opts \\ []), to: Host

  @impl true
  defdelegate exec(state, command, opts \\ []), to: Host
end
