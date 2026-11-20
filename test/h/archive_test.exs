defmodule H.ArchiveTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    suffix = System.unique_integer([:positive])
    catalog = :"archive_catalog_#{suffix}"
    table = :"archive_table_#{suffix}"
    auth_table = :"archive_auth_#{suffix}"
    start_supervised!({H.Catalog, data_dir: dir, name: catalog, table: table, pubsub: nil})
    start_supervised!({H.Auth, data_dir: dir, name: nil, table: auth_table})
    opts = [data_dir: dir, catalog: catalog, catalog_table: table, pubsub: nil]

    %{
      opts: opts,
      router: [daemon_opts: opts, auth_table: auth_table],
      token: H.Auth.owner_token(auth_table)
    }
  end

  test "upserts one archived session, keeps branch history, rejects commands and stale uploads",
       ctx do
    rows = [entry(nil, "root"), entry(2, "main"), entry(2, "fork")]
    assert %{"status" => "created", "session_id" => sid} = upload(ctx, 1, rows)
    assert %{"status" => "unchanged", "session_id" => ^sid} = upload(ctx, 1, rows)

    assert {:ok,
            %{session: %{status: "archived", active: false}, tasks: [], conversations: [_, fork]}} =
             H.Daemon.get_session_detail(sid, ctx.opts)

    assert {:ok, %{items: items}} =
             H.Daemon.scan_entries(sid, fork.id, %{"order" => "asc"}, ctx.opts)

    assert Enum.map(items, & &1["data"]["text"]) == ["root", "fork"]

    assert {:error, {:conflict, "session is archived"}} =
             H.Daemon.execute_command(sid, %{}, ctx.opts)

    assert %{"status" => "updated", "session_id" => ^sid} =
             upload(ctx, 2, rows ++ [entry(4, "new")])

    assert %{"status" => "stale"} = upload(ctx, 1, rows)
    assert request(ctx, 3, rows, ctx.token, false).status == 422

    assert [%{session_id: ^sid, title: "Example", attention: "archived"}] =
             H.Daemon.list_sessions(ctx.opts)

    assert {:ok, %{items: [%{"id" => "8"}], next_cursor: "8"}} =
             H.Daemon.scan_entries(sid, "1", %{"limit" => "1"}, ctx.opts)

    assert {:ok, %{items: [%{"id" => "4"}, %{"id" => "2"}], next_cursor: nil}} =
             H.Daemon.scan_entries(sid, "1", %{"cursor" => "8"}, ctx.opts)

    assert {:ok, {:snapshot, 2, payload}} =
             H.Daemon.subscribe_conversation(sid, "1", self(), nil, ctx.opts)

    assert Enum.map(JSON.decode!(payload)["entries"], & &1["data"]["text"]) == [
             "root",
             "main",
             "new"
           ]
  end

  test "rejects unauthenticated or broken uploads and does not publish a partial archive", ctx do
    assert request(ctx, 1, [entry(nil, "root")], "bad token").status == 401
    assert request(ctx, 1, [entry(20, "unknown parent")], ctx.token).status == 422
    assert H.Daemon.list_sessions(ctx.opts) == []
  end

  defp upload(ctx, rev, rows) do
    response = request(ctx, rev, rows, ctx.token)
    assert response.status == 200, response.resp_body
    JSON.decode!(response.resp_body)
  end

  test "never replaces a native session even on an ID collision", ctx do
    sid = "archive-" <> Base.encode16(:crypto.hash(:sha256, "pi\0pi-id"), case: :lower)

    assert {:ok, _} =
             H.Catalog.insert_session(ctx.opts[:catalog], %{session_id: sid, cwd: "/native"})

    assert request(ctx, 1, [entry(nil, "root")], ctx.token).status == 409
    assert [%{session_id: ^sid, cwd: "/native", status: "ok"}] = H.Daemon.list_sessions(ctx.opts)
  end

  defp request(ctx, revision, rows, token, complete? \\ true) do
    header = %{
      source: "pi",
      source_id: "pi-id",
      cwd: "/does/not/exist",
      created_at: 100,
      revision: revision,
      size: length(rows)
    }

    body =
      Enum.map_join(
        [header | rows] ++ if(complete?, do: [%{"end" => length(rows)}], else: []),
        "",
        &(JSON.encode!(&1) <> "\n")
      )

    %{conn(:post, "/api/v1/archives", body) | req_headers: [{"host", "127.0.0.1:80"}]}
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/x-ndjson")
    |> H.HTTP.Router.call(ctx.router)
  end

  defp entry(parent, text),
    do: %{parent: parent, kind: "user", data: %{text: text}, title: "Example", created_at: 102}
end
