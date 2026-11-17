defmodule H.Tools.SearchHistory do
  @moduledoc """
  Core `search_history` tool for searching raw un-truncated transcript entries.
  """

  @behaviour H.Tool

  @default_limit 20
  @max_limit 100
  @page_size 200
  @max_snippet_chars 240

  @impl true
  def name, do: "search_history"

  @impl true
  def description do
    "Search raw conversation history entries (including entries before compaction or reset markers) by case-insensitive substring."
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{
          "type" => "string",
          "minLength" => 1,
          "description" => "Case-insensitive substring to search for across raw history entries"
        },
        "limit" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => @max_limit,
          "description" => "Maximum number of matching entries to return (1..100, default 20)"
        },
        "before_id" => %{
          "type" => "integer",
          "minimum" => 1,
          "description" => "Only search entries with ID strictly less than this entry ID"
        }
      },
      "required" => ["query"],
      "additionalProperties" => false
    }
  end

  @impl true
  def replay, do: :safe

  @impl true
  def mutating?, do: false

  @impl true
  def execute(args, context) when is_map(args) and is_map(context) do
    query = fetch_arg(args, "query", :query)
    limit = fetch_arg(args, "limit", :limit) || @default_limit
    before_id = fetch_arg(args, "before_id", :before_id)
    scan_entries = Map.get(context, :scan_entries)

    cond do
      not (is_binary(query) and byte_size(query) > 0) ->
        error_result("Search query must be a non-empty string.", %{}, "invalid_query")

      not is_function(scan_entries, 1) ->
        error_result(
          "History search is not available in this context.",
          %{},
          "unavailable"
        )

      true ->
        down_query = String.downcase(query)
        collect_matches(scan_entries, down_query, query, before_id, before_id, limit, [])
    end
  end

  defp collect_matches(_scan_fn, _down_query, query, _before_id, _cursor, limit, acc)
       when length(acc) >= limit do
    finish_search(query, Enum.take(Enum.reverse(acc), limit))
  end

  defp collect_matches(scan_fn, down_query, query, before_id, cursor, limit, acc) do
    case scan_fn.(%{order: :desc, cursor: cursor, limit: @page_size}) do
      {:ok, page} when is_map(page) ->
        items = Map.get(page, :items) || Map.get(page, :entries) || []
        next_cursor = Map.get(page, :next_cursor)

        new_acc =
          Enum.reduce_while(items, acc, fn entry, matches ->
            if length(matches) >= limit do
              {:halt, matches}
            else
              entry_id = entry_field(entry, :id, "id")

              if is_nil(before_id) or (is_integer(entry_id) and entry_id < before_id) do
                case match_entry(entry, down_query) do
                  {:match, match_info} -> {:cont, [match_info | matches]}
                  :nomatch -> {:cont, matches}
                end
              else
                {:cont, matches}
              end
            end
          end)

        if length(new_acc) >= limit or is_nil(next_cursor) or items == [] or next_cursor == cursor do
          finish_search(query, Enum.take(Enum.reverse(new_acc), limit))
        else
          collect_matches(scan_fn, down_query, query, before_id, next_cursor, limit, new_acc)
        end

      {:error, reason} ->
        error_result(
          "Failed to search history: #{inspect(reason)}",
          %{reason: inspect(reason)},
          "scan_failed"
        )
    end
  end

  defp finish_search(query, matches) do
    text =
      case matches do
        [] ->
          "No matching entries found for #{inspect(query)}."

        _ ->
          Enum.map_join(matches, "\n", fn m ->
            "[##{m["id"]} #{m["kind"]}] #{m["snippet"]}"
          end)
      end

    {:ok,
     %{
       content: [%{"type" => "text", "text" => text}],
       details: %{
         "query" => query,
         "count" => length(matches),
         "matches" => matches
       },
       is_error: false,
       diagnostic: nil
     }}
  end

  defp match_entry(entry, down_query) do
    id = entry_field(entry, :id, "id")
    kind = entry_field(entry, :kind, "kind") |> to_string()
    data = entry_field(entry, :data, "data")

    serialized =
      %{"kind" => kind, "data" => sanitize_json(data)}
      |> JSON.encode!()

    readable = extract_readable_text(data)

    cond do
      String.contains?(String.downcase(readable), down_query) ->
        {:match, %{"id" => id, "kind" => kind, "snippet" => build_snippet(readable, down_query)}}

      String.contains?(String.downcase(serialized), down_query) ->
        {:match,
         %{"id" => id, "kind" => kind, "snippet" => build_snippet(serialized, down_query)}}

      true ->
        :nomatch
    end
  end

  defp extract_readable_text(data) do
    data
    |> collect_strings([])
    |> Enum.reverse()
    |> Enum.join(" ")
  end

  defp collect_strings(val, acc) when is_binary(val), do: [val | acc]

  defp collect_strings(list, acc) when is_list(list) do
    Enum.reduce(list, acc, &collect_strings/2)
  end

  defp collect_strings(map, acc) when is_map(map) do
    map = if is_struct(map), do: Map.from_struct(map), else: map

    map
    |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
    |> Enum.reduce(acc, fn {_k, v}, inner_acc -> collect_strings(v, inner_acc) end)
  end

  defp collect_strings(_other, acc), do: acc

  defp sanitize_json(val) when is_binary(val) or is_number(val) or is_boolean(val) or is_nil(val),
    do: val

  defp sanitize_json(val) when is_atom(val), do: Atom.to_string(val)

  defp sanitize_json(list) when is_list(list), do: Enum.map(list, &sanitize_json/1)

  defp sanitize_json(map) when is_map(map) do
    map = if is_struct(map), do: Map.from_struct(map), else: map
    Map.new(map, fn {k, v} -> {to_string(k), sanitize_json(v)} end)
  end

  defp sanitize_json(other), do: inspect(other)

  defp build_snippet(text, down_query) do
    normalized = String.replace(text, ~r/\s+/, " ") |> String.trim()
    down_norm = String.downcase(normalized)

    case String.split(down_norm, down_query, parts: 2) do
      [prefix_str, _rest] ->
        prefix_chars = String.length(prefix_str)
        total_chars = String.length(normalized)

        if total_chars <= @max_snippet_chars do
          normalized
        else
          half = div(@max_snippet_chars, 2)
          start_char = max(0, prefix_chars - half)
          start_char = min(start_char, max(0, total_chars - @max_snippet_chars))
          slice = String.slice(normalized, start_char, @max_snippet_chars)

          prefix = if start_char > 0, do: "...", else: ""
          suffix = if start_char + @max_snippet_chars < total_chars, do: "...", else: ""
          prefix <> slice <> suffix
        end

      [_] ->
        if String.length(normalized) <= @max_snippet_chars do
          normalized
        else
          String.slice(normalized, 0, @max_snippet_chars - 3) <> "..."
        end
    end
  end

  defp entry_field(entry, atom_key, str_key) when is_map(entry) do
    case Map.fetch(entry, atom_key) do
      {:ok, val} -> val
      :error -> Map.get(entry, str_key)
    end
  end

  defp error_result(message, details, diagnostic) do
    {:error,
     %{
       content: [%{"type" => "text", "text" => message}],
       details: details,
       is_error: true,
       diagnostic: diagnostic
     }}
  end

  defp fetch_arg(args, str_key, atom_key) do
    case Map.fetch(args, str_key) do
      {:ok, val} -> val
      :error -> Map.get(args, atom_key)
    end
  end
end
