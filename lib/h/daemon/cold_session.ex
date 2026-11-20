defmodule H.Daemon.ColdSession do
  @moduledoc """
  Side-effect-free cold storage reader for archived native sessions.

  Serves session detail, cursor-paged entry scans, initial conversation
  snapshots, and cross-directory branch exports directly from `H.Storage`
  without starting `H.Session.Supervisor` / `H.Session.Server` or mutating
  `H.Catalog` archive state.
  """

  alias H.{Document, Storage, Task}
  alias H.Session.Server.{Recovery, State}

  def detail(entry, opts, wire_session_fn, wire_conversation_fn) do
    with_cold_store(entry, opts, fn store ->
      with {:ok, bootstrap, _store} <- Storage.read_bootstrap(store) do
        conversations =
          bootstrap.conversations ||
            %{1 => %{id: 1, parent: nil, owner: :ownerless, entry_ids: []}}

        tasks =
          (bootstrap.tasks || %{})
          |> Map.values()
          |> Enum.map(&Task.from_storage/1)
          |> Enum.sort_by(& &1.id)

        meta = bootstrap.session_meta || %{}

        session_entry =
          cond do
            Map.has_key?(meta, :title) -> %{entry | title: meta.title}
            Map.has_key?(meta, "title") -> %{entry | title: meta["title"]}
            true -> entry
          end

        sorted_convs = conversations |> Map.values() |> Enum.sort_by(& &1.id)

        {:ok,
         %{
           session: wire_session_fn.(session_entry),
           conversations: Enum.map(sorted_convs, wire_conversation_fn),
           tasks: Enum.map(tasks, &Task.to_wire/1)
         }}
      end
    end)
  end

  def scan(entry, cid, query, opts, wire_entry_fn) do
    with_cold_store(entry, opts, fn store ->
      with {:ok, bootstrap, store} <- Storage.read_bootstrap(store) do
        conversations =
          bootstrap.conversations ||
            %{1 => %{id: 1, parent: nil, owner: :ownerless, entry_ids: []}}

        if Map.has_key?(conversations, cid) do
          full_query = Map.put(query, :conversation_id, cid)

          with {:ok, %{items: items, next_cursor: next_cursor}, _store} <-
                 Storage.scan_entries(store, full_query) do
            {:ok,
             %{
               items: Enum.map(items, wire_entry_fn),
               next_cursor: if(next_cursor, do: to_string(next_cursor), else: nil)
             }}
          end
        else
          {:error, :not_found}
        end
      end
    end)
  end

  def snapshot(entry, cid, opts, default_model) do
    with_cold_store(entry, opts, fn store ->
      with {:ok, bootstrap, store} <- Storage.read_bootstrap(store) do
        conversations =
          bootstrap.conversations ||
            %{1 => %{id: 1, parent: nil, owner: :ownerless, entry_ids: []}}

        if Map.has_key?(conversations, cid) do
          with {:ok, %{items: newest_first, next_cursor: next_cursor}, _store} <-
                 Storage.scan_entries(store, %{conversation_id: cid, order: :desc, limit: 50}) do
            seq = bootstrap.seq || 0

            entries_oldest_first =
              newest_first
              |> Enum.reverse()
              |> Enum.map(&State.wire_entry(&1, &1.seq))

            docs = Recovery.build_docs_map(conversations, bootstrap.docs || %{}, default_model)
            conv_docs = docs[cid]

            payload = %{
              "version" => 1,
              "session_id" => entry.session_id,
              "conversation_id" => to_string(cid),
              "seq" => seq,
              "before_entry_id" => if(next_cursor, do: to_string(next_cursor), else: nil),
              "entries" => entries_oldest_first,
              "docs" => %{
                "live" => conv_docs["live"],
                "inbox" => conv_docs["inbox"],
                "agent" => conv_docs["agent"],
                "usage" => conv_docs["usage"]
              }
            }

            {:ok, {:snapshot, seq, IO.iodata_to_binary(JSON.encode_to_iodata!(payload))}}
          end
        else
          {:error, :not_found}
        end
      end
    end)
  end

  def export_branch(entry, cid, at_entry_id, opts, default_model) do
    with_cold_store(entry, opts, fn store ->
      with {:ok, bootstrap, store} <- Storage.read_bootstrap(store) do
        conversations =
          bootstrap.conversations ||
            %{1 => %{id: 1, parent: nil, owner: :ownerless, entry_ids: []}}

        if Map.has_key?(conversations, cid) do
          with {:ok, %{items: all_entries}, store} <-
                 load_all_visible_asc(store, cid, nil, []) do
            docs = Recovery.build_docs_map(conversations, bootstrap.docs || %{}, default_model)

            case at_entry_id do
              nil ->
                {:ok, %{entries: all_entries, agent: get_in(docs, [cid, "agent"]) || %{}}}

              cutoff when is_integer(cutoff) ->
                case Enum.find(all_entries, &(&1.id == cutoff)) do
                  nil ->
                    {:error, {:bad_request, "entry_not_visible"}}

                  at_entry ->
                    prefix = Enum.filter(all_entries, &(&1.id <= cutoff))

                    with {:ok, fork_docs, _store} <-
                           Document.fork_docs(store, cid, at_entry.seq,
                             default_model: default_model
                           ) do
                      {:ok, %{entries: prefix, agent: fork_docs["agent"]}}
                    end
                end
            end
          end
        else
          {:error, :not_found}
        end
      end
    end)
  end

  defp load_all_visible_asc(store, cid, cursor, acc) do
    query = %{conversation_id: cid, order: :asc, cursor: cursor, limit: 200}

    with {:ok, %{items: page, next_cursor: next_cursor}, next_store} <-
           Storage.scan_entries(store, query) do
      combined = acc ++ page

      if is_nil(next_cursor) do
        {:ok, %{items: combined}, next_store}
      else
        load_all_visible_asc(next_store, cid, next_cursor, combined)
      end
    end
  end

  defp with_cold_store(entry, opts, fun) do
    storage_mod = Keyword.get(opts, :storage_mod, H.Storage.File)
    data_dir = Keyword.get(opts, :data_dir) || Application.get_env(:harness, :data_dir)

    full_opts =
      opts
      |> Keyword.put(:cwd, entry.cwd)
      |> then(fn kw -> if data_dir, do: Keyword.put(kw, :data_dir, data_dir), else: kw end)

    storage_opts = Recovery.build_storage_opts(full_opts, entry.session_id)

    opened =
      if storage_mod == H.Storage.File do
        H.Storage.File.open_read_only(storage_opts)
      else
        Storage.open(storage_mod, storage_opts)
      end

    with {:ok, store} <- opened do
      try do
        fun.(store)
      after
        Storage.close(store)
      end
    end
  end
end
