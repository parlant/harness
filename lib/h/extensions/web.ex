defmodule H.Extensions.Web do
  @moduledoc """
  Validates and normalizes `:web` contributions declared by `H.Extension`
  packages at daemon boot.

  Performs pure manifest/module/static-file checks without creating atoms from
  runtime input or executing extension rendering code. Static asset paths are
  constrained to regular non-symlink files inside `<package_path>/priv/static`.
  """

  @slug_regex ~r/\A[a-z][a-z0-9._-]{0,63}\z/
  @rel_path_regex ~r/\A[a-zA-Z0-9._-]+(\/[a-zA-Z0-9._-]+)*\z/
  @allowed_keys [:pages, :nav_items, :session_sidebar, :stylesheets, :scripts]
  @optional_page_callbacks [mount: 3, handle_params: 3, handle_event: 3, handle_info: 2]

  @doc """
  Validates a `:web` contribution map for `package` (`%{id: ext_id, path: pkg_path}`).

  Returns `{:ok, nil}` when `spec` is `nil`, or `{:ok, normalized_web_spec}` when valid.
  """
  @spec validate(term(), %{required(:id) => String.t(), required(:path) => String.t()}) ::
          {:ok, nil | map()} | {:error, atom()}
  def validate(nil, _package), do: {:ok, nil}

  def validate(spec, %{id: ext_id, path: pkg_path})
      when is_map(spec) and is_binary(ext_id) and is_binary(pkg_path) do
    static_dir = Path.join([pkg_path, "priv", "static"])

    with [] <- Map.keys(spec) -- @allowed_keys,
         {:ok, pages} <- validate_list(Map.get(spec, :pages, []), &validate_page(&1, ext_id)),
         {:ok, nav_items} <-
           validate_list(Map.get(spec, :nav_items, []), &validate_nav_item(&1, ext_id)),
         {:ok, sidebar} <-
           validate_list(Map.get(spec, :session_sidebar, []), &validate_sidebar_item(&1, ext_id)),
         {:ok, stylesheets} <-
           validate_list(
             Map.get(spec, :stylesheets, []),
             &validate_asset(&1, ext_id, static_dir, [".css"], :href)
           ),
         {:ok, scripts} <-
           validate_list(
             Map.get(spec, :scripts, []),
             &validate_asset(&1, ext_id, static_dir, [".js", ".mjs"], :src)
           ) do
      {:ok,
       %{
         ext_id: ext_id,
         static_dir: static_dir,
         pages: pages,
         nav_items: nav_items,
         session_sidebar: sidebar,
         stylesheets: stylesheets,
         scripts: scripts
       }}
    else
      {:error, _} = err -> err
      _ -> {:error, :invalid_web_contribution}
    end
  end

  def validate(_spec, _package), do: {:error, :invalid_web_contribution}

  @doc "Checks whether `value` matches the web extension slug/ID format."
  @spec valid_slug?(term()) :: boolean()
  def valid_slug?(value), do: is_binary(value) and Regex.match?(@slug_regex, value)

  defp validate_list(list, fun) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      {:error, _} = err -> err
    end
  end

  defp validate_list(_other, _fun), do: {:error, :invalid_web_contribution}

  defp validate_page(%{slug: slug, module: mod} = page, ext_id) when is_atom(mod) do
    title = Map.get(page, :title)

    with [] <- Map.keys(page) -- [:slug, :module, :title],
         true <- valid_slug?(slug),
         true <- is_nil(title) or (is_binary(title) and String.valid?(title)),
         true <- Code.ensure_loaded?(mod),
         true <- function_exported?(mod, :render, 1),
         true <- valid_optional_page_callbacks?(mod) do
      {:ok,
       %{
         ext_id: ext_id,
         slug: slug,
         path: "/ext/" <> slug,
         module: mod,
         title: title
       }}
    else
      _ -> {:error, :invalid_web_contribution}
    end
  end

  defp validate_page(_page, _ext_id), do: {:error, :invalid_web_contribution}

  defp valid_optional_page_callbacks?(mod) do
    exported = mod.__info__(:functions)

    Enum.all?(@optional_page_callbacks, fn {name, expected_arity} ->
      Enum.all?(exported, fn
        {^name, arity} -> arity == expected_arity
        _ -> true
      end)
    end)
  end

  defp validate_nav_item(%{id: id, label: label} = item, ext_id) do
    order = Map.get(item, :order, 50)

    with [] <- Map.keys(item) -- [:id, :label, :slug, :path, :order, :section],
         true <- valid_slug?(id),
         true <- is_binary(label) and byte_size(label) in 1..64 and String.valid?(label),
         true <- is_integer(order),
         {:ok, slug} <- nav_slug(item) do
      section = Map.get(item, :section, {:ext, slug})

      {:ok,
       %{
         ext_id: ext_id,
         id: id,
         label: label,
         path: "/ext/" <> slug,
         section: section,
         order: order
       }}
    else
      _ -> {:error, :invalid_web_contribution}
    end
  end

  defp validate_nav_item(_item, _ext_id), do: {:error, :invalid_web_contribution}

  defp nav_slug(%{slug: slug, path: path}) do
    if valid_slug?(slug) and path == "/ext/" <> slug do
      {:ok, slug}
    else
      :error
    end
  end

  defp nav_slug(%{slug: slug}) do
    if valid_slug?(slug), do: {:ok, slug}, else: :error
  end

  defp nav_slug(%{path: "/ext/" <> slug}) do
    if valid_slug?(slug), do: {:ok, slug}, else: :error
  end

  defp nav_slug(_), do: :error

  defp validate_sidebar_item(%{id: id, position: pos, module: mod} = item, ext_id)
       when is_atom(mod) do
    fun = Map.get(item, :function, :render)
    order = Map.get(item, :order, 50)

    with [] <- Map.keys(item) -- [:id, :position, :module, :function, :order],
         true <- valid_slug?(id),
         true <- valid_sidebar_position?(pos),
         true <- is_atom(fun),
         true <- is_integer(order),
         true <- Code.ensure_loaded?(mod),
         true <- function_exported?(mod, fun, 1) do
      {:ok,
       %{
         ext_id: ext_id,
         id: id,
         position: pos,
         module: mod,
         function: fun,
         order: order
       }}
    else
      _ -> {:error, :invalid_web_contribution}
    end
  end

  defp validate_sidebar_item(_item, _ext_id), do: {:error, :invalid_web_contribution}

  defp valid_sidebar_position?(pos) when pos in [:top, :bottom], do: true

  defp valid_sidebar_position?({dir, target_id}) when dir in [:before, :after],
    do: valid_slug?(target_id)

  defp valid_sidebar_position?(_), do: false

  defp validate_asset(rel_path, ext_id, static_dir, allowed_exts, url_key) do
    with true <- valid_rel_path?(rel_path),
         true <- Path.extname(rel_path) in allowed_exts,
         :ok <- verify_static_regular_file(static_dir, rel_path) do
      url_path = "/ext-assets/#{ext_id}/#{rel_path}"
      {:ok, Map.put(%{ext_id: ext_id, file: rel_path}, url_key, url_path)}
    else
      _ -> {:error, :invalid_web_contribution}
    end
  end

  defp valid_rel_path?(path) when is_binary(path) do
    byte_size(path) in 1..255 and String.valid?(path) and
      not String.contains?(path, <<0>>) and
      Regex.match?(@rel_path_regex, path) and
      not Enum.any?(String.split(path, "/"), &(&1 in [".", ".."]))
  end

  defp valid_rel_path?(_), do: false

  defp verify_static_regular_file(static_dir, rel_path) do
    segments = String.split(rel_path, "/")

    with {:ok, %File.Stat{type: :directory}} <- File.lstat(static_dir),
         {:ok, full_path} <- walk_no_symlink(static_dir, segments),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(full_path) do
      :ok
    else
      _ -> {:error, :invalid_web_contribution}
    end
  end

  defp walk_no_symlink(dir, [file]), do: {:ok, Path.join(dir, file)}

  defp walk_no_symlink(dir, [segment | rest]) do
    next = Path.join(dir, segment)

    case File.lstat(next) do
      {:ok, %File.Stat{type: :directory}} -> walk_no_symlink(next, rest)
      _ -> {:error, :invalid_web_contribution}
    end
  end
end
