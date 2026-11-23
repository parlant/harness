defmodule H.Archive do
  @moduledoc "Read-only imported session snapshots, stored separately from live session WALs."

  alias H.{Catalog, Schema, Session.Tree}

  @kinds ~w(user assistant tool_result user_shell compaction system)
  @page_bytes 12 * 1024 * 1024
  @max_entries 500_000

  def stage(header, fd) do
    with {:ok, attrs} <-
           Schema.validate_map(normalize_timestamp(header), [
             {:source, :session_id, required: true},
             {:source_id, :non_empty_string, required: true},
             {:cwd, :non_empty_string, required: true},
             {:created_at, {:int, min: 0}, required: true},
             {:revision, {:int, min: 0}, required: true},
             {:size, {:int, min: 0}, required: true}
           ]),
         true <- byte_size(attrs.source_id) <= 512 and byte_size(attrs.cwd) <= 4096,
         true <- String.starts_with?(attrs.cwd, "/") and not String.contains?(attrs.cwd, <<0>>) do
      sid =
        "archive-" <>
          Base.encode16(:crypto.hash(:sha256, [attrs.source, <<0>>, attrs.source_id]),
            case: :lower
          )

      {:ok,
       %{
         attrs: %{
           session_id: sid,
           title: nil,
           cwd: attrs.cwd,
           created_at: attrs.created_at,
           updated_at: attrs.created_at,
           archive: Map.take(attrs, [:source, :source_id, :revision, :size])
         },
         fd: fd,
         offset: 0,
         next_id: 2,
         entries: %{},
         conversations: %{1 => %{parent: nil, head: nil}}
       }}
    else
      _ -> {:error, {:bad_request, "invalid archive header"}}
    end
  end

  def append(state, row) do
    with true <- state.next_id <= @max_entries * 2,
         {:ok, entry} <-
           Schema.validate_map(normalize_timestamp(row), [
             {:parent, :pos_int, required: true, nullable: true},
             {:kind, {:enum, @kinds}, required: true},
             {:data, :map, required: true},
             {:title, :string, required: false, nullable: true},
             {:created_at, {:int, min: 0}, required: true}
           ]),
         true <- is_nil(entry.parent) or Map.has_key?(state.entries, entry.parent),
         {:ok, title} <- Schema.normalize_title(Map.get(entry, :title, state.attrs.title)) do
      id = state.next_id
      parent_cid = if entry.parent, do: elem(Map.fetch!(state.entries, entry.parent), 0), else: 1
      head = state.conversations[parent_cid].head
      cid = if head == entry.parent, do: parent_cid, else: id + 1

      branch =
        if cid == parent_cid do
          %{state.conversations[cid] | head: id}
        else
          %{head: id, parent: if(entry.parent, do: {parent_cid, entry.parent})}
        end

      bin =
        JSON.encode!(%{
          "id" => Integer.to_string(id),
          "conversation_id" => Integer.to_string(cid),
          "kind" => entry.kind,
          "data" => entry.data,
          "created_at" => entry.created_at
        })

      with :ok <- :file.write(state.fd, bin) do
        size = byte_size(bin)

        {:ok,
         %{
           state
           | next_id: id + 2,
             entries: Map.put(state.entries, id, {cid, entry.parent, state.offset, size}),
             conversations: Map.put(state.conversations, cid, branch),
             offset: state.offset + size,
             attrs: %{
               state.attrs
               | title: title,
                 updated_at: max(state.attrs.updated_at, entry.created_at)
             }
         }}
      end
    else
      _ -> {:error, {:bad_request, "invalid archive entry or parent"}}
    end
  end

  def finish(state, count) do
    if count == map_size(state.entries) do
      index = :erlang.term_to_binary({state.entries, state.conversations})

      with :ok <- :file.write(state.fd, [index, <<state.offset::64>>]),
           :ok <- :file.sync(state.fd) do
        {:ok, state.attrs}
      end
    else
      {:error, {:bad_request, "incomplete archive"}}
    end
  end

  def path(dir, sid, generation), do: Path.join(dir, "#{sid}.#{generation}.archive")

  def detail(entry, opts) do
    read(entry, opts, fn _fd, _entries, conversations, current ->
      branches =
        conversations
        |> Enum.sort()
        |> Enum.map(fn {id, branch} ->
          parent =
            case branch.parent do
              nil -> nil
              {cid, at} -> %{conversation_id: to_string(cid), at: to_string(at)}
            end

          %{id: to_string(id), parent: parent, owner: "ownerless"}
        end)

      {:ok, %{session: Catalog.wire_session(current, opts), conversations: branches, tasks: []}}
    end)
  end

  def tree(entry, opts) do
    read(entry, opts, fn fd, entries, conversations, current ->
      all_ids_asc = entries |> Map.keys() |> Enum.sort()
      {selected_ids, truncated?} = Tree.take_latest(all_ids_asc)

      locations =
        Enum.map(selected_ids, fn id ->
          {_, _, offset, size} = entries[id]
          {offset, size}
        end)

      decoded_result =
        case locations do
          [] ->
            {:ok, []}

          _ ->
            with {:ok, bins} <- :file.pread(fd, locations) do
              {:ok, Enum.map(bins, &JSON.decode!/1)}
            end
        end

      with {:ok, decoded_entries} <- decoded_result do
        {wired_convs, nodes, truncated} =
          Tree.build_archive(conversations, entries, decoded_entries, truncated?)

        {:ok,
         %{
           session: Catalog.wire_session(current, opts),
           conversations: wired_convs,
           nodes: nodes,
           truncated: truncated
         }}
      end
    end)
  end

  def export_branch(entry, cid, at_entry_id, opts) do
    read(entry, opts, fn fd, entries, conversations, _current ->
      case Map.fetch(conversations, cid) do
        {:ok, %{head: head}} ->
          ids = lineage(head, entries, [])

          with {:ok, selected_ids} <- filter_export_cutoff(ids, at_entry_id) do
            locations =
              Enum.map(selected_ids, fn id ->
                {_, _, offset, size} = entries[id]
                {offset, size}
              end)

            case locations do
              [] ->
                {:ok, %{entries: [], agent: %{}}}

              _ ->
                with {:ok, bins} <- :file.pread(fd, locations) do
                  exported = Enum.map(bins, &JSON.decode!/1)
                  {:ok, %{entries: exported, agent: %{}}}
                end
            end
          end

        :error ->
          {:error, :not_found}
      end
    end)
  end

  defp filter_export_cutoff(ids, nil), do: {:ok, ids}

  defp filter_export_cutoff(ids, at_entry_id) when is_integer(at_entry_id) do
    if at_entry_id in ids do
      {:ok, Enum.take_while(ids, &(&1 <= at_entry_id))}
    else
      {:error, {:bad_request, "entry_not_visible"}}
    end
  end

  def scan(entry, cid, query, opts) do
    read(entry, opts, fn fd, entries, conversations, current ->
      case Map.fetch(conversations, cid) do
        {:ok, %{head: head}} ->
          ids = lineage(head, entries, [])
          ids = if query.order == :desc, do: Enum.reverse(ids), else: ids

          ids =
            case {query.order, Map.get(query, :cursor)} do
              {_, nil} -> ids
              {:asc, cursor} -> Enum.drop_while(ids, &(&1 <= cursor))
              {:desc, cursor} -> Enum.drop_while(ids, &(&1 >= cursor))
            end

          {selected, more?} = page(ids, entries, query.limit, @page_bytes, [])

          locations =
            Enum.map(selected, fn id ->
              {_, _, offset, size} = entries[id]
              {offset, size}
            end)

          with {:ok, bins} <- :file.pread(fd, locations) do
            items = Enum.map(bins, &Map.put(JSON.decode!(&1), "seq", current.archive.generation))
            cursor = if more?, do: to_string(List.last(selected))
            {:ok, %{items: items, next_cursor: cursor, seq: current.archive.generation}}
          end

        :error ->
          {:error, :not_found}
      end
    end)
  end

  def snapshot(entry, cid, opts) do
    with {:ok, result} <- scan(entry, cid, %{order: :desc, cursor: nil, limit: 50}, opts) do
      payload = %{
        version: 1,
        session_id: entry.session_id,
        conversation_id: to_string(cid),
        seq: result.seq,
        entries: Enum.reverse(result.items),
        before_entry_id: result.next_cursor,
        docs: %{agent: %{}, live: %{}, inbox: [], usage: %{}}
      }

      {:ok, {:snapshot, result.seq, JSON.encode!(payload)}}
    end
  end

  defp read(entry, opts, fun) do
    dir = Path.join(Keyword.fetch!(opts, :data_dir), "archives")
    filename = path(dir, entry.session_id, entry.archive.generation)

    case :file.open(filename, [:raw, :binary, :read]) do
      {:ok, fd} ->
        try do
          with {:ok, size} <- :file.position(fd, :eof),
               {:ok, <<offset::64>>} when offset <= size - 8 <- :file.pread(fd, size - 8, 8),
               {:ok, index} <- :file.pread(fd, offset, size - 8 - offset) do
            {entries, conversations} = :erlang.binary_to_term(index, [:safe])
            fun.(fd, entries, conversations, entry)
          else
            _ -> {:error, :archive_unavailable}
          end
        after
          :file.close(fd)
        end

      {:error, :enoent} ->
        # A replace may retire the old snapshot between the catalog lookup and open.
        case Catalog.get_session(entry.session_id, opts[:catalog_table] || :h_catalog) do
          {:ok, %{archive: %{generation: gen}} = latest} when gen > entry.archive.generation ->
            read(latest, opts, fun)

          _ ->
            {:error, :archive_unavailable}
        end

      {:error, _} ->
        {:error, :archive_unavailable}
    end
  end

  defp normalize_timestamp(%{"created_at" => text} = attrs) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, timestamp, _} ->
        Map.put(attrs, "created_at", DateTime.to_unix(timestamp, :millisecond))

      _ ->
        attrs
    end
  end

  defp normalize_timestamp(attrs), do: attrs

  defp lineage(nil, _entries, acc), do: acc
  defp lineage(id, entries, acc), do: lineage(elem(entries[id], 1), entries, [id | acc])

  defp page([], _entries, _limit, _bytes, acc), do: {Enum.reverse(acc), false}
  defp page(_ids, _entries, 0, _bytes, acc), do: {Enum.reverse(acc), true}

  defp page([id | rest], entries, limit, bytes, acc) do
    size = elem(entries[id], 3)

    if size <= bytes or acc == [],
      do: page(rest, entries, limit - 1, bytes - size, [id | acc]),
      else: {Enum.reverse(acc), true}
  end
end
