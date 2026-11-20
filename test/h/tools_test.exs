defmodule H.ToolsTest do
  use ExUnit.Case, async: true

  alias H.Entry
  alias H.ExecutionEnv
  alias H.ExecutionEnv.Local
  alias H.Tool
  alias H.Tools.{Bash, Edit, Read, SearchHistory, Write}

  setup do
    rand = :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "h-tools-test-#{System.unique_integer([:positive, :monotonic])}-#{rand}"
      )
      |> Path.expand()

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    env = Local.new(tmp_dir)
    context = %{env: env, session_id: "sess-1", conversation_id: 1}
    {:ok, tmp_dir: tmp_dir, env: env, context: context}
  end

  describe "tool metadata and JSV schema validation" do
    test "declares expected names, replay policies, and mutating flags" do
      assert {Read.name(), Read.replay(), Read.mutating?()} == {"read", :safe, false}

      assert {SearchHistory.name(), SearchHistory.replay(), SearchHistory.mutating?()} ==
               {"search_history", :safe, false}

      assert {Write.name(), Write.replay(), Write.mutating?()} == {"write", :unsafe, true}
      assert {Edit.name(), Edit.replay(), Edit.mutating?()} == {"edit", :unsafe, true}
      assert {Bash.name(), Bash.replay(), Bash.mutating?()} == {"bash", :unsafe, true}
    end

    test "validates valid arguments and rejects invalid arguments via H.Tool.validate_args/2" do
      assert {:ok, _} =
               Tool.validate_args(Read, %{"path" => "a.txt", "offset" => 1, "limit" => 10})

      assert {:error, _} = Tool.validate_args(Read, %{"path" => "a.txt", "offset" => 0})
      assert {:error, _} = Tool.validate_args(Read, %{"path" => "a.txt", "extra" => true})

      assert {:ok, _} =
               Tool.validate_args(SearchHistory, %{
                 "query" => "needle",
                 "limit" => 10,
                 "before_id" => 5
               })

      assert {:error, _} = Tool.validate_args(SearchHistory, %{"query" => ""})
      assert {:error, _} = Tool.validate_args(SearchHistory, %{"query" => "x", "limit" => 101})

      assert {:ok, _} = Tool.validate_args(Write, %{"path" => "a.txt", "content" => "hi"})
      assert {:error, _} = Tool.validate_args(Write, %{"path" => "a.txt"})

      assert {:ok, _} =
               Tool.validate_args(Edit, %{
                 "path" => "a.txt",
                 "edits" => [%{"old_text" => "a", "new_text" => "b"}]
               })

      assert {:error, _} = Tool.validate_args(Edit, %{"path" => "a.txt", "edits" => []})

      assert {:ok, _} = Tool.validate_args(Bash, %{"command" => "echo hi", "timeout_ms" => 500})
      assert {:ok, _} = Tool.validate_args(Bash, %{"command" => ":", "cwd" => "/work/tree"})

      assert {:error, _} =
               Tool.validate_args(Bash, %{
                 "command" => ":",
                 "cwd" => "/work/tree",
                 "cwd_scope" => "turn"
               })

      assert {:error, _} = Tool.validate_args(Bash, %{"command" => "echo hi", "timeout_ms" => 50})
    end
  end

  describe "H.Tools.Read" do
    test "formats UTF-8 text with line numbers and pagination footer", %{
      env: env,
      context: context
    } do
      :ok = ExecutionEnv.write_file(env, "notes.txt", "alpha\nbeta\ngamma\ndelta\n")

      assert {:ok, res1} =
               Read.execute(%{"path" => "notes.txt", "offset" => 1, "limit" => 2}, context)

      assert res1.is_error == false
      assert res1.diagnostic == nil
      assert [%{"type" => "text", "text" => text1}] = res1.content
      assert text1 =~ "1: alpha\n2: beta"
      assert text1 =~ "Pass offset: 3 to read more."

      assert {:ok, res2} =
               Read.execute(%{"path" => "notes.txt", "offset" => 3, "limit" => 2}, context)

      assert [%{"type" => "text", "text" => text2}] = res2.content
      assert text2 == "3: gamma\n4: delta"
    end

    test "returns base64 image content for supported image formats <= 4.5 MiB", %{
      env: env,
      context: context
    } do
      png_bytes = <<137, 80, 78, 71, 13, 10, 26, 10, 0, 1, 2, 3>>
      :ok = ExecutionEnv.write_file(env, "pic.png", png_bytes)

      assert {:ok, res} = Read.execute(%{"path" => "pic.png"}, context)
      assert res.is_error == false

      assert [
               %{
                 "type" => "image",
                 "mime_type" => "image/png",
                 "data" => Base.encode64(png_bytes)
               }
             ] == res.content
    end

    test "rejects images larger than 4.5 MiB and missing or binary files", %{
      env: env,
      context: context
    } do
      oversized = :binary.copy(<<1>>, 4_718_593)
      :ok = ExecutionEnv.write_file(env, "huge.jpg", oversized)
      :ok = ExecutionEnv.write_file(env, "data.bin", <<1, 0, 2, 3>>)

      assert {:error, %{is_error: true, diagnostic: "file_too_large"}} =
               Read.execute(%{"path" => "huge.jpg"}, context)

      assert {:error, %{is_error: true, diagnostic: "binary_file"}} =
               Read.execute(%{"path" => "data.bin"}, context)

      assert {:error, %{is_error: true, diagnostic: "not_found"}} =
               Read.execute(%{"path" => "missing.txt"}, context)
    end
  end

  describe "H.Tools.Write" do
    test "writes file atomically with parent directory creation", %{
      tmp_dir: tmp_dir,
      context: context
    } do
      assert {:ok, res} =
               Write.execute(
                 %{"path" => "sub/dir/file.ex", "content" => "defmodule A do\nend\n"},
                 context
               )

      assert res.is_error == false
      assert res.diagnostic == nil
      assert File.read!(Path.join(tmp_dir, "sub/dir/file.ex")) == "defmodule A do\nend\n"
    end
  end

  describe "H.Tools.Edit" do
    test "applies multiple non-overlapping edits matched against the original file", %{
      env: env,
      tmp_dir: tmp_dir,
      context: context
    } do
      :ok = ExecutionEnv.write_file(env, "code.txt", "first = 1\nsecond = 2\nthird = 3\n")

      # Swapping first and third proves all matches run against the original file.
      assert {:ok, res} =
               Edit.execute(
                 %{
                   "path" => "code.txt",
                   "edits" => [
                     %{"old_text" => "first = 1", "new_text" => "third = 3"},
                     %{"old_text" => "third = 3", "new_text" => "first = 1"}
                   ]
                 },
                 context
               )

      assert res.is_error == false
      assert res.details.edits_applied == 2
      assert File.read!(Path.join(tmp_dir, "code.txt")) == "third = 3\nsecond = 2\nfirst = 1\n"
    end

    test "preserves CRLF line endings of untouched lines and adapted edits", %{
      env: env,
      tmp_dir: tmp_dir,
      context: context
    } do
      :ok = ExecutionEnv.write_file(env, "win.txt", "a\r\nb\r\nc\r\nd\r\n")

      assert {:ok, _} =
               Edit.execute(
                 %{
                   "path" => "win.txt",
                   "edits" => [%{"old_text" => "b\nc", "new_text" => "B\nC"}]
                 },
                 context
               )

      assert File.read!(Path.join(tmp_dir, "win.txt")) == "a\r\nB\r\nC\r\nd\r\n"
    end

    test "fails cleanly without modifying file on missing, duplicate, empty, or overlapping edits",
         %{
           env: env,
           tmp_dir: tmp_dir,
           context: context
         } do
      original = "aaa\nrepeat\nrepeat\nend\n"
      :ok = ExecutionEnv.write_file(env, "target.txt", original)

      assert {:error, %{is_error: true, diagnostic: "empty_old_text"}} =
               Edit.execute(
                 %{"path" => "target.txt", "edits" => [%{"old_text" => "", "new_text" => "x"}]},
                 context
               )

      assert {:error, %{is_error: true, diagnostic: "old_text_not_found"}} =
               Edit.execute(
                 %{
                   "path" => "target.txt",
                   "edits" => [%{"old_text" => "nope", "new_text" => "x"}]
                 },
                 context
               )

      assert {:error, %{is_error: true, diagnostic: "old_text_not_unique"}} =
               Edit.execute(
                 %{
                   "path" => "target.txt",
                   "edits" => [%{"old_text" => "repeat", "new_text" => "x"}]
                 },
                 context
               )

      # Overlapping self-match ("aa" appears twice in "aaa")
      assert {:error, %{is_error: true, diagnostic: "old_text_not_unique"}} =
               Edit.execute(
                 %{"path" => "target.txt", "edits" => [%{"old_text" => "aa", "new_text" => "x"}]},
                 context
               )

      # Two edits whose spans overlap
      assert {:error, %{is_error: true, diagnostic: "overlapping_edits"}} =
               Edit.execute(
                 %{
                   "path" => "target.txt",
                   "edits" => [
                     %{"old_text" => "aaa\n", "new_text" => "x"},
                     %{"old_text" => "aa\nrepeat", "new_text" => "y"}
                   ]
                 },
                 context
               )

      assert File.read!(Path.join(tmp_dir, "target.txt")) == original
    end
  end

  describe "H.Tools.Bash" do
    test "returns is_error: false on exit_code 0 and is_error: true with diagnostic exit_code otherwise",
         %{context: context} do
      parent = self()

      ctx =
        Map.put(context, :on_output, fn chunk, total ->
          send(parent, {:streamed, chunk, total})
        end)

      assert {:ok, ok_res} = Bash.execute(%{"command" => "printf 'hello'"}, ctx)
      assert ok_res.is_error == false
      assert ok_res.diagnostic == nil
      assert ok_res.details.exit_code == 0
      assert [%{"type" => "text", "text" => "hello"}] = ok_res.content
      assert_receive {:streamed, "hello", 5}

      assert {:ok, err_res} = Bash.execute(%{"command" => "echo boom; exit 7"}, context)
      assert err_res.is_error == true
      assert err_res.diagnostic == "exit_code"
      assert err_res.details.exit_code == 7
      assert [%{"type" => "text", "text" => text}] = err_res.content
      assert text =~ "boom"
      assert text =~ "7"
    end

    test "reports spill truncation path when output exceeds default window", %{context: context} do
      cmd = "i=1; while [ $i -le 2100 ]; do echo \"line-$i\"; i=$((i+1)); done"

      assert {:ok, res} = Bash.execute(%{"command" => cmd}, context)

      on_exit(fn ->
        if res.details.full_output_path, do: File.rm(res.details.full_output_path)
      end)

      assert res.is_error == false
      assert res.details.truncated == true
      assert res.details.skipped_bytes > 0
      assert is_binary(res.details.full_output_path)
      assert [%{"type" => "text", "text" => text}] = res.content
      assert text =~ res.details.full_output_path
    end

    test "returns timeout error diagnostic when command exceeds timeout_ms", %{context: context} do
      assert {:error, res} =
               Bash.execute(%{"command" => "echo before; sleep 30", "timeout_ms" => 150}, context)

      assert res.is_error == true
      assert res.diagnostic == "timeout"
      assert [%{"type" => "text", "text" => text}] = res.content
      assert text =~ "before"
      assert text =~ "timed out"
    end
  end

  describe "H.Tools.SearchHistory" do
    test "scans multiple pages and finds raw entries including pre-compaction history", %{
      context: context
    } do
      # Build 250 entries across 2 pages (200 per page), including compaction markers and forked ids.
      entries =
        for id <- 1..250 do
          cond do
            id == 5 ->
              %Entry{
                id: id,
                conversation_id: 1,
                kind: "user",
                data: %{"text" => "Ancient Secret Token Alpha"}
              }

            id == 100 ->
              %Entry{
                id: id,
                conversation_id: 1,
                kind: "compaction",
                data: %{"summary" => "Compacted prior work"}
              }

            id == 220 ->
              %Entry{
                id: id,
                conversation_id: 2,
                kind: "assistant",
                data: %{"text" => "Fork mentioned token beta"}
              }

            true ->
              %Entry{
                id: id,
                conversation_id: 1,
                kind: "assistant",
                data: %{"text" => "routine msg #{id}"}
              }
          end
        end
        |> Enum.reverse()

      parent = self()

      scan_entries = fn %{order: :desc, cursor: cursor, limit: limit} = query ->
        send(parent, {:scan, query})

        filtered =
          if cursor do
            Enum.filter(entries, &(&1.id < cursor))
          else
            entries
          end

        page = Enum.take(filtered, limit)
        next_cursor = if length(filtered) > limit, do: List.last(page).id, else: nil
        {:ok, %{items: page, next_cursor: next_cursor}}
      end

      ctx = Map.put(context, :scan_entries, scan_entries)

      assert {:ok, res} = SearchHistory.execute(%{"query" => "TOKEN", "limit" => 10}, ctx)
      assert res.is_error == false
      assert res.details["count"] == 2

      assert [%{"id" => 220, "kind" => "assistant"}, %{"id" => 5, "kind" => "user"}] =
               Enum.map(res.details["matches"], &Map.take(&1, ["id", "kind"]))

      assert_received {:scan, %{order: :desc, cursor: nil, limit: 200}}
      assert_received {:scan, %{order: :desc, cursor: 51, limit: 200}}

      # before_id excludes entry 220 and still finds entry 5
      assert {:ok, older} =
               SearchHistory.execute(%{"query" => "token", "before_id" => 220}, ctx)

      assert [%{"id" => 5}] = Enum.map(older.details["matches"], &Map.take(&1, ["id"]))
    end

    test "returns unavailable error when context.scan_entries is missing", %{context: context} do
      assert {:error, %{is_error: true, diagnostic: "unavailable"}} =
               SearchHistory.execute(%{"query" => "anything"}, context)
    end

    test "never exposes excluded user_shell command or output while still returning included ones",
         %{context: context} do
      entries =
        [
          %Entry{
            id: 1,
            conversation_id: 1,
            kind: "user_shell",
            data: %{
              "command" => "echo needle_secret_cmd",
              "output" => "needle_secret_output",
              "full_output_path" => "/tmp/needle_secret_path.log",
              "include_in_context" => false
            }
          },
          %Entry{
            id: 2,
            conversation_id: 1,
            kind: "compaction",
            data: %{"summary" => "Compacted"}
          },
          %Entry{
            id: 3,
            conversation_id: 1,
            kind: "user_shell",
            data: %{
              "command" => "echo needle_missing_flag",
              "output" => "needle_missing_output"
            }
          },
          %Entry{
            id: 4,
            conversation_id: 1,
            kind: "user_shell",
            data: %{
              "command" => "echo needle_public_cmd",
              "output" => "needle_public_output",
              "include_in_context" => true
            }
          }
        ]
        |> Enum.reverse()

      scan_entries = fn %{order: :desc, cursor: cursor, limit: limit} ->
        filtered =
          if cursor do
            Enum.filter(entries, &(&1.id < cursor))
          else
            entries
          end

        page = Enum.take(filtered, limit)
        next_cursor = if length(filtered) > limit, do: List.last(page).id, else: nil
        {:ok, %{items: page, next_cursor: next_cursor}}
      end

      ctx = Map.put(context, :scan_entries, scan_entries)

      assert {:ok, res} = SearchHistory.execute(%{"query" => "needle"}, ctx)
      assert res.details["count"] == 1
      assert [%{"id" => 4, "kind" => "user_shell", "snippet" => snippet}] = res.details["matches"]
      assert snippet =~ "needle_public"
      refute snippet =~ "secret"

      assert {:ok, secret_res} = SearchHistory.execute(%{"query" => "secret"}, ctx)
      assert secret_res.details["count"] == 0
      assert secret_res.details["matches"] == []

      assert {:ok, kind_res} = SearchHistory.execute(%{"query" => "include_in_context"}, ctx)
      assert Enum.map(kind_res.details["matches"], & &1["id"]) == [4]
    end
  end
end
