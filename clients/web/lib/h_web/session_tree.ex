defmodule HWeb.SessionTree do
  @moduledoc """
  Pure `pi`-inspired session turn-step tree layout, filtering, search, and
  branch folding for `HWeb`.

  Consumes the response map of `HWeb.Backend.get_session_tree/1`
  (`%{session, conversations, nodes, truncated}`) and produces flat display
  rows with tree connectors (`│  `, `├─ `, `└─ `), active-path markers,
  conversation leaf badges, and fold controls.
  """

  @filter_modes ~w(default no-tools user-only all)

  @doc "Supported tree filter modes."
  @spec filter_modes() :: [String.t()]
  def filter_modes, do: @filter_modes

  @doc "Normalizes a filter mode string to a supported value."
  @spec normalize_filter(term()) :: String.t()
  def normalize_filter(mode) when mode in @filter_modes, do: mode
  def normalize_filter(_), do: "default"

  @doc """
  Builds a rendered tree projection from `tree_data` (`%{conversations, nodes, ...}`).

  Options:
  - `:current_conversation_id` — active conversation ID string (default `"1"`)
  - `:filter` — `"default"` | `"no-tools"` | `"user-only"` | `"all"` (default `"default"`)
  - `:query` — optional whitespace-separated search query (default `""`)
  - `:folded_ids` — `MapSet` of folded entry IDs (default `MapSet.new()`)
  """
  @spec project(map() | nil, keyword()) :: map()
  def project(tree_data, opts \\ [])

  def project(nil, opts) do
    project(%{conversations: [], nodes: [], truncated: false}, opts)
  end

  def project(tree_data, opts) when is_map(tree_data) and is_list(opts) do
    current_cid = to_string(Keyword.get(opts, :current_conversation_id, "1"))
    filter = normalize_filter(Keyword.get(opts, :filter, "default"))
    query = Keyword.get(opts, :query, "") |> to_string() |> String.trim()
    folded_ids = Keyword.get(opts, :folded_ids, MapSet.new())

    raw_convs = fetch(tree_data, :conversations) || []
    raw_nodes = fetch(tree_data, :nodes) || []
    truncated? = fetch(tree_data, :truncated) == true

    convs = Enum.map(raw_convs, &normalize_conversation/1)
    nodes = Enum.map(raw_nodes, &normalize_node/1)

    node_by_id = Map.new(nodes, &{&1.id, &1})

    current_conv = Enum.find(convs, &(&1.id == current_cid))
    current_leaf_id = current_conv && current_conv.leaf_entry_id

    leaf_badges_by_node =
      convs
      |> Enum.filter(&(is_binary(&1.leaf_entry_id) and &1.leaf_entry_id != ""))
      |> Enum.group_by(& &1.leaf_entry_id)
      |> Map.new(fn {leaf_id, conv_list} ->
        badges =
          conv_list
          |> Enum.sort_by(fn c ->
            {if(c.id == current_cid, do: 0, else: 1), parse_int_or_zero(c.id)}
          end)
          |> Enum.map(fn c ->
            %{
              id: c.id,
              current?: c.id == current_cid,
              parent: c.parent
            }
          end)

        {leaf_id, badges}
      end)

    active_path_ids = build_active_path(current_leaf_id, node_by_id)

    {roots, children_map} = build_full_graph(nodes, node_by_id)
    contains_active = compute_contains_active(roots, children_map, current_leaf_id)

    # Full DFS pre-order with active branch prioritized first.
    ordered_ids = dfs_order(roots, children_map, contains_active)

    # Filter entries according to filter mode and search query.
    search_tokens =
      query
      |> String.downcase()
      |> String.split(~r/\s+/, trim: true)

    unfolded_visible_ids =
      Enum.filter(ordered_ids, fn id ->
        node = Map.fetch!(node_by_id, id)

        passes_filter?(node, filter, current_leaf_id) and
          matches_search?(node, Map.get(leaf_badges_by_node, id, []), search_tokens)
      end)

    unfolded_visible_set = MapSet.new(unfolded_visible_ids)

    # Build nearest-visible-ancestor graph BEFORE applying folds so we know which
    # nodes actually have visible descendants and can show a fold button.
    {_vis_parent_full, vis_children_full} =
      build_visible_graph(unfolded_visible_ids, unfolded_visible_set, node_by_id)

    foldable_ids =
      vis_children_full
      |> Enum.reduce(MapSet.new(), fn
        {parent_id, children}, acc when is_binary(parent_id) ->
          if length(children) > 1 or (MapSet.member?(folded_ids, parent_id) and children != []) do
            MapSet.put(acc, parent_id)
          else
            acc
          end

        _, acc ->
          acc
      end)

    # Apply folding: hide all descendants of any folded node.
    hidden_by_fold = compute_hidden_by_fold(ordered_ids, node_by_id, folded_ids)

    visible_ids =
      Enum.reject(unfolded_visible_ids, &MapSet.member?(hidden_by_fold, &1))

    visible_set = MapSet.new(visible_ids)

    {_visible_parent, visible_children} =
      build_visible_graph(visible_ids, visible_set, node_by_id)

    visible_roots = Map.get(visible_children, nil, [])
    multiple_roots? = length(visible_roots) > 1

    layout_entries =
      compute_layout(visible_roots, visible_children, multiple_roots?)

    rows =
      Enum.map(layout_entries, fn item ->
        node = Map.fetch!(node_by_id, item.id)
        tips = Map.get(leaf_badges_by_node, node.id, [])
        folded? = MapSet.member?(folded_ids, node.id)
        foldable? = MapSet.member?(foldable_ids, node.id)

        hidden_count =
          if folded?, do: count_hidden_visible_descendants(node.id, vis_children_full), else: 0

        %{
          id: node.id,
          parent_id: node.parent_id,
          conversation_id: node.conversation_id,
          kind: node.kind,
          preview: node.preview,
          has_text: node.has_text,
          tool_name: node.tool_name,
          aborted: node.aborted,
          is_error: node.is_error,
          created_at: node.created_at,
          active_path?: MapSet.member?(active_path_ids, node.id),
          current_leaf?: node.id == current_leaf_id,
          conversation_tips: tips,
          indent: item.indent,
          show_connector?: item.show_connector?,
          is_last?: item.is_last?,
          prefix: item.prefix,
          foldable?: foldable?,
          folded?: folded?,
          hidden_descendants: hidden_count
        }
      end)

    %{
      rows: rows,
      total_nodes: length(nodes),
      visible_count: length(rows),
      conversations: convs,
      current_conversation_id: current_cid,
      current_leaf_id: current_leaf_id,
      filter: filter,
      query: query,
      folded_ids: folded_ids,
      truncated?: truncated?
    }
  end

  # Graph building

  defp build_active_path(nil, _node_by_id), do: MapSet.new()

  defp build_active_path(leaf_id, node_by_id) do
    walk_ancestors(leaf_id, node_by_id, MapSet.new())
  end

  defp walk_ancestors(nil, _node_by_id, acc), do: acc

  defp walk_ancestors(id, node_by_id, acc) do
    if MapSet.member?(acc, id) do
      acc
    else
      case Map.get(node_by_id, id) do
        nil -> acc
        node -> walk_ancestors(node.parent_id, node_by_id, MapSet.put(acc, id))
      end
    end
  end

  defp build_full_graph(nodes, node_by_id) do
    # Preserve ascending ID order for deterministic sibling ordering.
    sorted = Enum.sort_by(nodes, &parse_int_or_zero(&1.id))

    {roots_rev, children_rev} =
      Enum.reduce(sorted, {[], %{}}, fn node, {roots_acc, map_acc} ->
        parent_id = node.parent_id

        if is_binary(parent_id) and Map.has_key?(node_by_id, parent_id) and parent_id != node.id do
          {roots_acc, Map.update(map_acc, parent_id, [node.id], &[node.id | &1])}
        else
          {[node.id | roots_acc], map_acc}
        end
      end)

    roots = Enum.reverse(roots_rev)

    children_map =
      Map.new(children_rev, fn {parent_id, ids_rev} -> {parent_id, Enum.reverse(ids_rev)} end)

    {roots, children_map}
  end

  defp compute_contains_active(_roots, _children_map, nil), do: MapSet.new()

  defp compute_contains_active(roots, children_map, leaf_id) do
    # Post-order traversal via explicit stack.
    pre_order = collect_preorder(roots, children_map, [])

    Enum.reduce(pre_order, MapSet.new(), fn id, acc ->
      children = Map.get(children_map, id, [])

      if id == leaf_id or Enum.any?(children, &MapSet.member?(acc, &1)) do
        MapSet.put(acc, id)
      else
        acc
      end
    end)
  end

  defp collect_preorder([], _children_map, acc), do: acc

  defp collect_preorder([id | rest], children_map, acc) do
    children = Map.get(children_map, id, [])
    collect_preorder(children ++ rest, children_map, [id | acc])
  end

  defp dfs_order(roots, children_map, contains_active) do
    ordered_roots = prioritize_active(roots, contains_active)
    dfs_walk(ordered_roots, children_map, contains_active, []) |> Enum.reverse()
  end

  defp dfs_walk([], _children_map, _contains_active, acc), do: acc

  defp dfs_walk([id | rest], children_map, contains_active, acc) do
    children =
      children_map
      |> Map.get(id, [])
      |> prioritize_active(contains_active)

    dfs_walk(children ++ rest, children_map, contains_active, [id | acc])
  end

  defp prioritize_active(ids, contains_active) do
    {active, other} = Enum.split_with(ids, &MapSet.member?(contains_active, &1))
    active ++ other
  end

  # Filtering & search

  defp passes_filter?(node, filter, current_leaf_id) do
    current_leaf? = node.id == current_leaf_id

    cond do
      node.kind == "usage" ->
        false

      filter == "all" ->
        true

      filter == "user-only" ->
        node.kind == "user"

      # Skip tool-only assistant entries (no text, not error/aborted) unless current leaf or "all"
      node.kind == "assistant" and not current_leaf? and not node.has_text and not node.aborted and
          not node.is_error ->
        false

      filter == "no-tools" ->
        node.kind not in ["tool_result", "model_change", "thinking_level_change", "session_info"]

      true ->
        # default mode
        node.kind not in ["model_change", "thinking_level_change", "session_info"]
    end
  end

  defp matches_search?(_node, _tips, []), do: true

  defp matches_search?(node, tips, tokens) do
    tip_text = Enum.map_join(tips, " ", &"conv ##{&1.id}")

    haystack =
      [
        "##{node.id}",
        node.id,
        node.kind,
        node.tool_name || "",
        node.preview,
        tip_text
      ]
      |> Enum.join(" ")
      |> String.downcase()

    Enum.all?(tokens, &String.contains?(haystack, &1))
  end

  defp compute_hidden_by_fold(ordered_ids, node_by_id, folded_ids) do
    if MapSet.size(folded_ids) == 0 do
      MapSet.new()
    else
      Enum.reduce(ordered_ids, MapSet.new(), fn id, skip ->
        parent_id = Map.fetch!(node_by_id, id).parent_id

        if is_binary(parent_id) and
             (MapSet.member?(folded_ids, parent_id) or MapSet.member?(skip, parent_id)) do
          MapSet.put(skip, id)
        else
          skip
        end
      end)
    end
  end

  defp build_visible_graph(visible_ids, visible_set, node_by_id) do
    {parent_map, children_rev} =
      Enum.reduce(visible_ids, {%{}, %{nil => []}}, fn id, {p_acc, c_acc} ->
        ancestor = find_visible_ancestor(id, visible_set, node_by_id)
        next_p = Map.put(p_acc, id, ancestor)
        next_c = Map.update(c_acc, ancestor, [id], &[id | &1])
        {next_p, next_c}
      end)

    children_map =
      Map.new(children_rev, fn {parent_id, ids_rev} -> {parent_id, Enum.reverse(ids_rev)} end)

    {parent_map, children_map}
  end

  defp find_visible_ancestor(id, visible_set, node_by_id) do
    parent_id = Map.fetch!(node_by_id, id).parent_id
    walk_for_visible(parent_id, visible_set, node_by_id, MapSet.new([id]))
  end

  defp walk_for_visible(nil, _visible_set, _node_by_id, _seen), do: nil

  defp walk_for_visible(curr, visible_set, node_by_id, seen) do
    cond do
      MapSet.member?(seen, curr) ->
        nil

      MapSet.member?(visible_set, curr) ->
        curr

      true ->
        case Map.get(node_by_id, curr) do
          nil ->
            nil

          node ->
            walk_for_visible(node.parent_id, visible_set, node_by_id, MapSet.put(seen, curr))
        end
    end
  end

  defp count_hidden_visible_descendants(node_id, vis_children_map) do
    children = Map.get(vis_children_map, node_id, [])
    count_descendants(children, vis_children_map, 0)
  end

  defp count_descendants([], _map, acc), do: acc

  defp count_descendants([id | rest], map, acc) do
    children = Map.get(map, id, [])
    count_descendants(children ++ rest, map, acc + 1)
  end

  # Visual layout matching pi's tree-selector.ts indentation & connector semantics:
  # - Single-child chains stay flat (indent unchanged).
  # - Branch points (multiple children) shift children +1 with ├─ / └─ connectors.
  # - First generation after a branch point (just_branched? and indent > 0) shifts +1
  #   for visual grouping, then subsequent single-child descendants stay flat.

  defp compute_layout(visible_roots, visible_children, multiple_roots?) do
    root_count = length(visible_roots)

    initial_stack =
      visible_roots
      |> Enum.with_index()
      |> Enum.map(fn {root_id, idx} ->
        is_last? = idx == root_count - 1

        {
          root_id,
          if(multiple_roots?, do: 1, else: 0),
          multiple_roots?,
          multiple_roots?,
          is_last?,
          [],
          multiple_roots?
        }
      end)

    layout_dfs(initial_stack, visible_children, multiple_roots?, [])
    |> Enum.reverse()
  end

  defp layout_dfs([], _visible_children, _multiple_roots?, acc), do: acc

  defp layout_dfs(
         [
           {id, indent, just_branched?, show_connector?, is_last?, gutters, virtual_root_child?}
           | rest
         ],
         visible_children,
         multiple_roots?,
         acc
       ) do
    display_indent = if(multiple_roots?, do: max(0, indent - 1), else: indent)
    connector_displayed? = show_connector? and not virtual_root_child?
    prefix = build_prefix(display_indent, connector_displayed?, is_last?, gutters)

    item = %{
      id: id,
      indent: display_indent,
      show_connector?: connector_displayed?,
      is_last?: is_last?,
      prefix: prefix
    }

    children = Map.get(visible_children, id, [])
    multiple_children? = length(children) > 1

    child_indent =
      cond do
        multiple_children? -> indent + 1
        just_branched? and indent > 0 -> indent + 1
        true -> indent
      end

    connector_position = max(0, display_indent - 1)

    child_gutters =
      if connector_displayed? do
        gutters ++ [%{position: connector_position, show: not is_last?}]
      else
        gutters
      end

    child_count = length(children)

    child_items =
      children
      |> Enum.with_index()
      |> Enum.map(fn {child_id, idx} ->
        {
          child_id,
          child_indent,
          multiple_children?,
          multiple_children?,
          idx == child_count - 1,
          child_gutters,
          false
        }
      end)

    layout_dfs(child_items ++ rest, visible_children, multiple_roots?, [item | acc])
  end

  defp build_prefix(display_indent, connector_displayed?, is_last?, gutters) do
    connector_slot = if connector_displayed?, do: max(0, display_indent - 1), else: -1

    gutter_by_pos = Map.new(gutters, &{&1.position, &1.show})

    if display_indent == 0 do
      ""
    else
      0..(display_indent - 1)
      |> Enum.map_join("", fn pos ->
        cond do
          connector_displayed? and pos == connector_slot ->
            if is_last?, do: "└─ ", else: "├─ "

          Map.get(gutter_by_pos, pos) == true ->
            "│  "

          true ->
            "   "
        end
      end)
    end
  end

  # Normalizers

  defp normalize_conversation(conv) do
    parent =
      case fetch(conv, :parent) do
        nil ->
          nil

        p when is_map(p) ->
          %{
            conversation_id: to_string(fetch(p, :conversation_id) || ""),
            at: to_string(fetch(p, :at) || "")
          }
      end

    leaf =
      case fetch(conv, :leaf_entry_id) do
        nil -> nil
        val -> to_string(val)
      end

    %{
      id: to_string(fetch(conv, :id) || ""),
      parent: parent,
      owner: fetch(conv, :owner) || "ownerless",
      leaf_entry_id: leaf
    }
  end

  defp normalize_node(node) do
    parent_id =
      case fetch(node, :parent_id) do
        nil -> nil
        "" -> nil
        val -> to_string(val)
      end

    %{
      id: to_string(fetch(node, :id) || ""),
      parent_id: parent_id,
      conversation_id: to_string(fetch(node, :conversation_id) || "1"),
      kind: to_string(fetch(node, :kind) || "unknown"),
      preview: to_string(fetch(node, :preview) || ""),
      has_text: fetch(node, :has_text) == true,
      tool_name: fetch(node, :tool_name),
      aborted: fetch(node, :aborted) == true,
      is_error: fetch(node, :is_error) == true or fetch(node, :error) == true,
      created_at: fetch(node, :created_at)
    }
  end

  defp fetch(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, val} -> val
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp fetch(_, _), do: nil

  defp parse_int_or_zero(str) do
    case Integer.parse(to_string(str)) do
      {n, ""} -> n
      _ -> 0
    end
  end
end
