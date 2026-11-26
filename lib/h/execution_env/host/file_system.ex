defmodule H.ExecutionEnv.Host.FileSystem do
  @moduledoc """
  Workspace metadata must not enter OTP's shared file server: a privacy prompt
  or unavailable mount there can block unrelated storage and code loading.

  Bundles enumerate directories in the bounded, native `hi-exec` worker. Raw
  metadata calls stay local to their caller. Unbundled development uses
  `:prim_file` for enumeration/readlink because `:file` has no raw variant.
  """

  @timeout_ms 3_000
  @max_output_bytes 8_388_608
  @errors ~w(enoent eacces eperm enotdir einval eloop eio timeout file_too_large)a

  def stat(path), do: File.stat(path, [:raw])
  def lstat(path), do: File.lstat(path, [:raw])
  def dir?(path), do: match?({:ok, %File.Stat{type: :directory}}, stat(path))
  def regular?(path), do: match?({:ok, %File.Stat{type: :regular}}, stat(path))
  def exists?(path), do: match?({:ok, _}, stat(path))

  # Avoid privacy prompts merely to decorate a parent directory listing. This
  # is a UX policy, not a sandbox: explicitly opening these folders is allowed.
  def automatic_probe?(path, home \\ System.user_home!(), os \\ :os.type())

  def automatic_probe?(path, home, {:unix, :darwin}) do
    expanded = Path.expand(path)

    Enum.all?(["Desktop", "Documents", "Downloads", "Library"], fn name ->
      protected = Path.join(home, name)
      expanded != protected and not String.starts_with?(expanded, protected <> "/")
    end)
  end

  def automatic_probe?(_path, _home, _os), do: true

  def ls(path) do
    case System.get_env("H_FS_EXECUTABLE") do
      nil ->
        with {:ok, names} <- :prim_file.list_dir(path) do
          {:ok, Enum.map(names, &IO.chardata_to_string/1)}
        end

      executable ->
        native_ls(executable, path)
    end
  end

  def mkdir_p(path) do
    case :prim_file.make_dir(path) do
      :ok ->
        :ok

      {:error, :eexist} ->
        if dir?(path), do: :ok, else: {:error, :eexist}

      {:error, :enoent} ->
        parent = Path.dirname(path)

        if parent == path do
          {:error, :enoent}
        else
          with :ok <- mkdir_p(parent), do: mkdir_p(path)
        end

      error ->
        error
    end
  end

  def rename(source, target), do: :prim_file.rename(source, target)
  def rm(path), do: :file.delete(path, [:raw])

  def chmod(path, mode) do
    info =
      %File.Stat{mode: mode}
      |> File.Stat.to_record()
      |> Tuple.to_list()
      |> Enum.map(fn
        nil -> :undefined
        value -> value
      end)
      |> List.to_tuple()

    :file.write_file_info(path, info, [:raw])
  end

  def read_link(path) do
    with {:ok, target} <- :prim_file.read_link(path) do
      {:ok, IO.chardata_to_string(target)}
    end
  end

  defp native_ls(executable, path) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        args: ["fs", "ls", path]
      ])

    deadline = System.monotonic_time(:millisecond) + @timeout_ms

    try do
      receive_output(port, <<>>, deadline)
    after
      if Port.info(port), do: Port.close(port)
    end
  rescue
    ArgumentError -> {:error, :eio}
    ErlangError -> {:error, :eio}
  end

  defp receive_output(port, output, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^port, {:data, data}} when byte_size(output) + byte_size(data) <= @max_output_bytes ->
        receive_output(port, output <> data, deadline)

      {^port, {:data, _}} ->
        {:error, :file_too_large}

      {^port, {:exit_status, 0}} ->
        case JSON.decode(output) do
          {:ok, %{"ok" => names}} when is_list(names) ->
            if Enum.all?(names, &is_binary/1), do: {:ok, names}, else: {:error, :eio}

          {:ok, %{"error" => error}} ->
            {:error, Enum.find(@errors, :eio, &(Atom.to_string(&1) == error))}

          _ ->
            {:error, :eio}
        end

      {^port, {:exit_status, _}} ->
        {:error, :eio}
    after
      remaining -> {:error, :timeout}
    end
  end
end
