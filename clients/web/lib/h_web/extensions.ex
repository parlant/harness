defmodule HWeb.Extensions do
  @moduledoc """
  Runtime registry and pure ordering/asset lookup helpers for `:web`
  extensions in `HWeb`.
  """

  @ext_id_regex ~r/\A[a-z][a-z0-9._-]{0,79}\z/
  @segment_regex ~r/\A[a-zA-Z0-9._-]+\z/

  @content_types %{
    ".js" => "text/javascript; charset=utf-8",
    ".mjs" => "text/javascript; charset=utf-8",
    ".css" => "text/css; charset=utf-8",
    ".svg" => "image/svg+xml",
    ".json" => "application/json",
    ".woff2" => "font/woff2",
    ".png" => "image/png"
  }

  @doc """
  Returns the active `:web` extension registrations from daemon options,
  falling back to `:harness_web`'s `:web_extensions` application env.
  """
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    case Keyword.get(HWeb.Backend.InVM.daemon_opts(opts), :web_extensions) do
      items when is_list(items) and items != [] ->
        items

      _ ->
        case Application.get_env(:harness_web, :web_extensions, []) do
          items when is_list(items) -> items
          _ -> []
        end
    end
  end

  @doc """
  Returns registered main-menu nav items sorted stably by `{order, label, id}`.
  """
  @spec nav_items(keyword()) :: [map()]
  def nav_items(opts \\ []) do
    opts
    |> list()
    |> Enum.flat_map(&Map.get(&1, :nav_items, []))
    |> Enum.sort_by(&{Map.get(&1, :order, 50), &1.label, &1.id})
  end

  @doc """
  Looks up a registered custom page by `slug`.
  """
  @spec find_page(String.t(), keyword()) :: {:ok, map()} | :error
  def find_page(slug, opts \\ [])

  def find_page(slug, opts) when is_binary(slug) do
    opts
    |> list()
    |> Enum.flat_map(&Map.get(&1, :pages, []))
    |> Enum.find(&(&1.slug == slug))
    |> case do
      nil -> :error
      page -> {:ok, page}
    end
  end

  def find_page(_slug, _opts), do: :error

  @doc """
  Returns deduplicated stylesheet specs across active `:web` extensions.
  """
  @spec stylesheets(keyword()) :: [map()]
  def stylesheets(opts \\ []) do
    opts
    |> list()
    |> Enum.flat_map(&Map.get(&1, :stylesheets, []))
    |> Enum.uniq_by(& &1.href)
  end

  @doc """
  Returns deduplicated script specs across active `:web` extensions.
  """
  @spec scripts(keyword()) :: [map()]
  def scripts(opts \\ []) do
    opts
    |> list()
    |> Enum.flat_map(&Map.get(&1, :scripts, []))
    |> Enum.uniq_by(& &1.src)
  end

  @doc """
  Returns registered session sidebar items across active `:web` extensions.
  """
  @spec sidebar_items(keyword()) :: [map()]
  def sidebar_items(opts \\ []) do
    opts
    |> list()
    |> Enum.flat_map(&Map.get(&1, :session_sidebar, []))
  end

  @doc """
  Resolves a static file path for `ext_id` and `path_segments` strictly inside
  the registered extension's `static_dir`, rejecting traversal and symlinks.
  """
  @spec static_file(String.t(), [String.t()], keyword()) ::
          {:ok, String.t(), String.t()} | :error
  def static_file(ext_id, path_segments, opts \\ [])

  def static_file(ext_id, path_segments, opts)
      when is_binary(ext_id) and is_list(path_segments) and path_segments != [] do
    with true <- Regex.match?(@ext_id_regex, ext_id),
         true <- Enum.all?(path_segments, &valid_segment?/1),
         %{static_dir: static_dir} when is_binary(static_dir) <-
           Enum.find(list(opts), &(Map.get(&1, :ext_id) == ext_id)),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(static_dir),
         {:ok, full_path} <- walk_regular_no_symlink(static_dir, path_segments),
         true <- contained_within?(full_path, static_dir),
         content_type when is_binary(content_type) <-
           Map.get(@content_types, Path.extname(full_path)) do
      {:ok, full_path, content_type}
    else
      _ -> :error
    end
  end

  def static_file(_ext_id, _path_segments, _opts), do: :error

  @doc """
  Orders built-in session sidebar anchors together with extension sidebar items.

  `builtin_items` is an ordered list of anchor maps (`%{id: ..., kind: :builtin}`).
  `:top` items (sorted by `{order, id}`) are placed before the built-ins, `:bottom`
  items (sorted by `{order, id}`) are placed after the built-ins, and `{:before, id}` /
  `{:after, id}` items are inserted iteratively until convergence so chains like
  `C after B` where `B after "session-tags"` resolve cleanly. Unresolved targets or
  cycles are appended at the end sorted by `{order, id}`.
  """
  @spec order_sidebar_items([map()], [map()]) :: [map()]
  def order_sidebar_items(builtin_items, extension_items)
      when is_list(builtin_items) and is_list(extension_items) do
    sorted_ext = Enum.sort_by(extension_items, &{Map.get(&1, :order, 50), &1.id})

    {top_items, rest} = Enum.split_with(sorted_ext, &(Map.get(&1, :position) == :top))
    {bottom_items, relative_items} = Enum.split_with(rest, &(Map.get(&1, :position) == :bottom))

    base = top_items ++ builtin_items ++ bottom_items
    {placed, remaining} = resolve_relative_passes(base, relative_items)

    placed ++ remaining
  end

  defp resolve_relative_passes(list, []), do: {list, []}

  defp resolve_relative_passes(list, pending) do
    present_ids = MapSet.new(list, & &1.id)

    {ready, deferred} =
      Enum.split_with(pending, fn item ->
        case item.position do
          {dir, target_id} when dir in [:before, :after] -> MapSet.member?(present_ids, target_id)
          _ -> false
        end
      end)

    if ready == [] do
      {list, pending}
    else
      next_list = insert_ready_items(list, ready)
      resolve_relative_passes(next_list, deferred)
    end
  end

  defp insert_ready_items(list, ready) do
    by_before =
      ready
      |> Enum.filter(&match?({:before, _}, &1.position))
      |> Enum.group_by(fn %{position: {:before, target_id}} -> target_id end)

    by_after =
      ready
      |> Enum.filter(&match?({:after, _}, &1.position))
      |> Enum.group_by(fn %{position: {:after, target_id}} -> target_id end)

    Enum.flat_map(list, fn item ->
      befores = Map.get(by_before, item.id, [])
      afters = Map.get(by_after, item.id, [])
      befores ++ [item] ++ afters
    end)
  end

  defp valid_segment?(segment) when is_binary(segment) do
    byte_size(segment) in 1..255 and String.valid?(segment) and
      not String.contains?(segment, <<0>>) and
      segment not in [".", ".."] and
      Regex.match?(@segment_regex, segment)
  end

  defp valid_segment?(_), do: false

  defp walk_regular_no_symlink(dir, [file]) do
    target = Path.join(dir, file)

    case File.lstat(target) do
      {:ok, %File.Stat{type: :regular}} -> {:ok, target}
      _ -> :error
    end
  end

  defp walk_regular_no_symlink(dir, [segment | rest]) do
    next = Path.join(dir, segment)

    case File.lstat(next) do
      {:ok, %File.Stat{type: :directory}} -> walk_regular_no_symlink(next, rest)
      _ -> :error
    end
  end

  defp contained_within?(full_path, base_dir) do
    expanded_base = Path.expand(base_dir)
    expanded_full = Path.expand(full_path)
    String.starts_with?(expanded_full, expanded_base <> "/")
  end
end
