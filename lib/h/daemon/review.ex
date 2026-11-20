defmodule H.Daemon.Review do
  @moduledoc false

  alias H.{ExecutionEnv, WorkspaceLease}

  @page_size 200
  @history_page_size 30
  @max_text 512 * 1024
  @max_media 16 * 1024 * 1024
  @max_git_output 256 * 1024
  @max_changes 1000
  @git_options ~w(--no-ext-diff --no-textconv --no-renames --ignore-submodules=all --relative)
  @git_env Map.new(
             ~w(GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_CONFIG GIT_GLOB_PATHSPECS GIT_NOGLOB_PATHSPECS GIT_ICASE_PATHSPECS),
             &{&1, false}
           )
           |> Map.merge(%{
             "LC_ALL" => "C",
             "GIT_CONFIG_NOSYSTEM" => "1",
             "GIT_CONFIG_GLOBAL" => "/dev/null",
             "GIT_NO_LAZY_FETCH" => "1",
             "GIT_ALLOW_PROTOCOL" => "",
             "GIT_NO_REPLACE_OBJECTS" => "1",
             "GIT_OPTIONAL_LOCKS" => "0",
             "GIT_TERMINAL_PROMPT" => "0"
           })

  def browse(%{env: env}, %{history: page}) when is_integer(page) and page in 0..100_000 do
    with {:ok, %{exit_code: 0, truncated: false, output: output}} <-
           git(
             env,
             [
               "log",
               "--all",
               "--skip=#{page * @history_page_size}",
               "--max-count=#{@history_page_size + 1}" | log_options()
             ],
             @max_git_output
           ) do
      commits = parse_commits(output)

      {:ok,
       %{
         commits: Enum.take(commits, @history_page_size),
         next?: length(commits) > @history_page_size
       }}
    else
      _ -> {:error, :git_unavailable}
    end
  end

  def browse(%{env: env}, %{commit: hash, dir: dir, page: page})
      when is_integer(page) and page in 0..100_000 do
    with true <- object_id?(hash) || {:error, :invalid_commit},
         true <- (dir == "" or valid_path?(dir)) || {:error, :invalid_path},
         {:ok, %{exit_code: 0, truncated: false, output: output}} <-
           git(
             env,
             ["ls-tree", "--full-tree", "-z", hash <> "^{commit}:./" <> dir],
             @max_git_output
           ) do
      entries =
        output
        |> nul_fields()
        |> Enum.flat_map(fn record ->
          case tree_entry(record) do
            {type, name, _id} when type in ["dir", "file"] ->
              path = if dir == "", do: name, else: dir <> "/" <> name
              if valid_path?(path), do: [%{name: name, path: path, type: type}], else: []

            _ ->
              []
          end
        end)
        |> Enum.sort_by(& &1.name)
        |> Enum.drop(page * @page_size)
        |> Enum.take(@page_size + 1)

      {:ok, %{entries: Enum.take(entries, @page_size), next?: length(entries) > @page_size}}
    else
      {:ok, %{truncated: true}} -> {:error, :tree_too_large}
      {:ok, _} -> {:error, :enoent}
      {:error, _} = error -> error
    end
  end

  def browse(%{env: env}, %{commit: ref}) do
    with true <- commit_input?(ref) || {:error, :invalid_commit},
         {:ok, %{exit_code: 0, truncated: false, output: id_line}} <-
           git(env, ["rev-parse", "--disambiguate=" <> ref], @max_git_output),
         [hash, ""] <- :binary.split(id_line, "\n", [:global]),
         true <- object_id?(hash),
         {:ok, %{exit_code: 0, truncated: false, output: output}} <-
           git(
             env,
             ["log", "--no-walk", "--max-count=1", hash <> "^{commit}" | log_options()],
             @max_git_output
           ),
         [%{id: ^hash} = commit] <- parse_commits(output),
         {:ok, base} <- commit_base(env, commit) do
      {:ok, %{commit: Map.put(commit, :base, base), git: commit_changes(env, hash, base)}}
    else
      {:error, _} = error -> error
      _ -> {:error, :commit_unavailable}
    end
  end

  def browse(%{env: env}, %{dir: dir, page: page, changes?: changes?})
      when is_integer(page) and page in 0..100_000 and is_boolean(changes?) do
    with {:ok, resolved} <- target(env, dir, :directory),
         {:ok, result} <-
           ExecutionEnv.list_dir(env, resolved, limit: @page_size, cursor: page * @page_size) do
      entries =
        for %{type: type, name: name} <- result.entries,
            type in ["file", "dir"],
            path = if(dir == "", do: name, else: dir <> "/" <> name),
            valid_path?(path),
            do: %{type: type, path: path, name: name}

      {:ok,
       %{
         entries: entries,
         next?: not is_nil(result.next_cursor),
         git: if(changes?, do: changes(env), else: nil)
       }}
    end
  end

  def browse(_, _), do: {:error, :invalid_path}

  def read(%{env: env}, path, source) when source in [:working, "working"] do
    with {:ok, resolved} <- target(env, path, :file),
         {:ok, bytes} <-
           ExecutionEnv.read_file_bytes(env, resolved,
             no_follow: true,
             max_bytes: read_limit(path)
           ) do
      classify(path, bytes)
    end
  end

  def read(%{env: env}, path, source) do
    head? = source in [:head, "head"]
    ref = if head?, do: "HEAD", else: source
    missing = if head?, do: :not_in_head, else: :not_in_commit

    with true <- (head? or object_id?(ref)) || {:error, :invalid_commit},
         true <- valid_path?(path) || {:error, :invalid_path},
         {:ok, output} <- blob_entry(env, ref, path, missing),
         [{"file", ^path, id}] <- Enum.map(nul_fields(output), &tree_entry/1),
         {:ok, %{exit_code: 0, truncated: false, output: bytes}} <-
           git(env, ["cat-file", "blob", id], read_limit(path)) do
      classify(path, bytes)
    else
      [{"symlink", ^path, _}] -> {:error, :symlink_not_followed}
      {:ok, %{truncated: true}} -> {:error, :file_too_large}
      {:ok, _} -> {:error, :git_unavailable}
      {:error, _} = error -> error
      _ -> {:error, missing}
    end
  end

  defp blob_entry(env, ref, path, missing) do
    case git(env, ["ls-tree", "-z", ref <> "^{commit}", "--", path], @max_git_output) do
      {:ok, %{exit_code: 0, truncated: false, output: output}} -> {:ok, output}
      {:ok, %{exit_code: 128}} when ref == "HEAD" -> {:error, missing}
      {:ok, %{exit_code: 128}} -> {:error, :commit_unavailable}
      _ -> {:error, :git_unavailable}
    end
  end

  def save(%{env: env, env_id: id, cwd: cwd} = workspace, path, rev, text, {lease, holder})
      when is_binary(text) and byte_size(text) <= @max_text and is_binary(rev) do
    key = {id, cwd}

    with true <- text?(text) || {:error, :not_text},
         true <- not is_nil(GenServer.whereis(lease)) || {:error, :workspace_unavailable},
         :ok <- WorkspaceLease.acquire(lease, key, holder, self()) do
      try do
        with {:ok, _} <- ExecutionEnv.bind_canonical_cwd(env, cwd, exact: true),
             {:ok, %{kind: :text, revision: ^rev}} <- read(workspace, path, :working),
             {:ok, resolved} <- target(env, path, :file),
             :ok <- ExecutionEnv.write_file(env, resolved, text) do
          {:ok, revision(text)}
        else
          {:ok, _} -> {:error, :file_changed}
          {:error, :enoent} -> {:error, :file_changed}
          {:error, _} = error -> error
        end
      after
        WorkspaceLease.release(lease, key, holder)
      end
    else
      {:error, {:workspace_busy, _}} -> {:error, :workspace_busy}
      {:error, _} = error -> error
    end
  end

  def save(_, _, _, _, _), do: {:error, :invalid_edit}

  def revision(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp target(env, path, :directory) when path == "", do: ExecutionEnv.canonical_path(env, ".")

  defp target(env, path, _kind) do
    with true <- valid_path?(path) || {:error, :invalid_path},
         {:ok, root} <- ExecutionEnv.canonical_path(env, "."),
         expected = Path.join(root, path),
         {:ok, ^expected} <- ExecutionEnv.canonical_path(env, expected) do
      {:ok, expected}
    else
      {:ok, _} -> {:error, :symlink_not_followed}
      {:error, _} = error -> error
    end
  end

  defp valid_path?(path) when is_binary(path) and byte_size(path) in 1..4096 do
    String.valid?(path) and not String.contains?(path, [<<0>>, <<13>>, <<10>>]) and
      Enum.all?(:binary.split(path, "/", [:global]), fn part ->
        part not in ["", ".", ".."] and String.downcase(part) != ".git"
      end)
  end

  defp valid_path?(_), do: false

  defp read_limit(path) do
    case media_type(path) do
      {kind, _} when kind not in [:html, :svg] -> @max_media
      _ -> @max_text
    end
  end

  defp classify(path, bytes) do
    digest = revision(bytes)

    case media_type(path) do
      {mode, mime} when mode not in [:html, :svg] ->
        {:ok, %{kind: :media, mode: mode, mime: mime, bytes: bytes, revision: digest}}

      type ->
        if text?(bytes) do
          preview =
            case type do
              {:svg, mime} -> {:image, mime}
              other -> other
            end

          {:ok, %{kind: :text, text: bytes, revision: digest, preview: preview}}
        else
          {:error, :unsupported_binary}
        end
    end
  end

  defp text?(bytes), do: String.valid?(bytes) and not String.contains?(bytes, <<0>>)

  defp media_type(path) do
    if valid_path?(path) do
      ext = path |> Path.extname() |> String.downcase()
      mime = MIME.from_path("file" <> ext)

      case mime do
        "image/svg+xml" -> {:svg, mime}
        "image/" <> _ -> {:image, mime}
        "audio/" <> _ -> {:audio, mime}
        "video/" <> _ -> {:video, mime}
        "text/html" -> {:html, mime}
        "application/xhtml+xml" -> {:html, mime}
        "application/ogg" -> {:video, mime}
        _ -> nil
      end
    end
  end

  # Avoid status/refresh-index/ls-files -m: they can invoke configured clean
  # filters. These plumbing commands compare the worktree stat data and index
  # without invoking filters, diff drivers, hooks or an fsmonitor program.
  defp changes(env) do
    case git(env, ["rev-parse", "--is-inside-work-tree"], 1024) do
      {:ok, %{exit_code: 0, output: "true\n"}} -> git_changes(env)
      {:ok, %{exit_code: 0, output: "false\n"}} -> :not_git
      {:ok, %{exit_code: 128, output: "fatal: not a git repository" <> _}} -> :not_git
      {:error, {:enoent, "git"}} -> :not_git
      _ -> :git_unavailable
    end
  end

  defp git_changes(env) do
    commands = [
      {:staged, ["diff", "--cached", "--name-status", "-z"] ++ @git_options ++ ["--", "."]},
      {:working, ["diff-files", "--name-status", "-z"] ++ @git_options ++ ["--", "."]},
      {:untracked, ~w(ls-files --others --exclude-standard -z -- .)}
    ]

    with {:ok, statuses, truncated?} <-
           Enum.reduce_while(commands, {:ok, %{}, false}, fn {kind, args}, {:ok, acc, clipped?} ->
             case git(env, args, @max_git_output) do
               {:ok, %{exit_code: 0, output: output, truncated: truncated?}} ->
                 # A bounded tail may start partway through a status record.
                 # Drop that command's results rather than mislabel paths.
                 entries = if truncated?, do: acc, else: merge_changes(acc, kind, output)
                 {:cont, {:ok, entries, clipped? or truncated?}}

               _ ->
                 {:halt, :git_unavailable}
             end
           end) do
      entries = statuses |> Map.values() |> Enum.sort_by(& &1.path)

      %{
        entries: Enum.take(entries, @max_changes),
        truncated?: truncated? or length(entries) > @max_changes
      }
    end
  end

  defp log_options do
    ~w(--no-color --no-show-signature --no-notes --no-decorate --no-patch --encoding=UTF-8 --format=%H%x00%P%x00%cs%x00%s -z --)
  end

  defp parse_commits(output) do
    for [id, parents, date, subject] <- Enum.chunk_every(nul_fields(output), 4),
        object_id?(id),
        do: %{
          id: id,
          parent: List.first(String.split(parents, " ", trim: true)),
          date: String.replace_invalid(date),
          subject: subject |> String.replace_invalid() |> String.slice(0, 250)
        }
  end

  defp commit_base(_env, %{parent: parent}) when is_binary(parent), do: {:ok, parent}

  # Log hides the recorded parent at a shallow boundary. Don't mistake it for
  # a root commit and present every path as newly added.
  defp commit_base(env, %{id: id}) do
    case git(env, ["cat-file", "commit", id], @max_git_output) do
      {:ok, %{exit_code: 0, truncated: false, output: output}} ->
        [headers | _] = :binary.split(output, "\n\n")
        shallow? = Enum.any?(:binary.split(headers, "\n", [:global]), &match?("parent " <> _, &1))
        {:ok, if(shallow?, do: nil, else: "empty")}

      _ ->
        {:error, :commit_unavailable}
    end
  end

  defp commit_changes(_env, _id, nil), do: :parent_unavailable

  defp commit_changes(env, id, base) do
    revisions = if base == "empty", do: ["--root", id], else: [base, id]

    args =
      ~w(diff-tree --name-status -z -r --no-commit-id) ++ @git_options ++ revisions ++ ["--", "."]

    case git(env, args, @max_git_output) do
      {:ok, %{exit_code: 0, truncated: false, output: output}} ->
        entries =
          for {status, path} <- status_pairs(output),
              valid_path?(path),
              do: %{status: status, path: path}

        %{entries: Enum.take(entries, @max_changes), truncated?: length(entries) > @max_changes}

      {:ok, %{exit_code: 0, truncated: true}} ->
        %{entries: [], truncated?: true}

      _ ->
        :git_unavailable
    end
  end

  defp tree_entry(record) do
    case :binary.split(record, "\t") do
      ["040000 tree " <> id, name] ->
        {"dir", name, id}

      ["120000 blob " <> id, name] ->
        {"symlink", name, id}

      [<<mode::binary-size(6), " blob ", id::binary>>, name] when mode in ["100644", "100755"] ->
        if object_id?(id), do: {"file", name, id}

      _ ->
        nil
    end
  end

  defp commit_input?(id) when is_binary(id) and byte_size(id) in 4..64,
    do: Regex.match?(~r/\A[0-9a-fA-F]+\z/, id)

  defp commit_input?(_), do: false

  defp object_id?(id) when is_binary(id) and byte_size(id) in [40, 64], do: commit_input?(id)
  defp object_id?(_), do: false

  defp nul_fields(output), do: :binary.split(output, <<0>>, [:global]) |> Enum.drop(-1)

  defp status_pairs(output) do
    for [status, path] <- Enum.chunk_every(nul_fields(output), 2),
        status in ~w(A D M T U X B),
        do: {status, path}
  end

  defp merge_changes(acc, kind, output) do
    pairs =
      if kind == :untracked do
        Enum.map(nul_fields(output), &{"?", &1})
      else
        status_pairs(output)
      end

    Enum.reduce(pairs, acc, fn {status, path}, map ->
      if valid_path?(path),
        do: Map.update(map, path, %{kind => status, path: path}, &Map.put(&1, kind, status)),
        else: map
    end)
  end

  defp git(env, args, limit) do
    ExecutionEnv.exec(
      env,
      {:argv,
       [
         "git",
         "--no-pager",
         "--literal-pathspecs",
         "-c",
         "core.fsmonitor=false",
         "-c",
         "core.warnAmbiguousRefs=false",
         "-c",
         "core.untrackedCache=false" | args
       ]},
      env: @git_env,
      timeout_ms: 850,
      window_bytes: limit,
      window_lines: limit + 1,
      raw_output: true,
      spill_output: false
    )
  end
end
