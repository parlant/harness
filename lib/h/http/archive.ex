defmodule H.HTTP.Archive do
  @moduledoc false
  import Plug.Conn
  alias H.{Archive, Catalog}

  @max_upload 1024 * 1024 * 1024
  @max_line 24 * 1024 * 1024
  @read_size 256 * 1024

  def upload(conn, opts) do
    dir = Path.join(Keyword.fetch!(opts, :data_dir), "archives")

    temp =
      Path.join(
        dir,
        ".upload-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      )

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         {:ok, fd} <- :file.open(temp, [:raw, :binary, :write, :exclusive]) do
      try do
        with {:ok, attrs, conn} <- receive_rows(conn, fd, nil, <<>>, 0),
             {:ok, status} <-
               H.Daemon.Maintenance.admit(opts, fn ->
                 Catalog.publish_archive(opts[:catalog] || Catalog, attrs, temp)
               end) do
          {:ok, %{status: status, session_id: attrs.session_id}, conn}
        end
      after
        :file.close(fd)
        File.rm(temp)
      end
    end
  end

  defp receive_rows(conn, fd, state, pending, size) do
    case read_body(conn, length: @read_size, read_length: @read_size, read_timeout: 15_000) do
      {status, bytes, conn}
      when status in [:ok, :more] and size + byte_size(bytes) <= @max_upload ->
        case consume(pending <> bytes, fd, state) do
          {:ok, %{done: attrs}, <<>>} when status == :ok ->
            {:ok, attrs, conn}

          {:ok, next, rest} when status == :more ->
            receive_rows(conn, fd, next, rest, size + byte_size(bytes))

          {:ok, _, _} ->
            {:error, {:bad_request, "missing archive footer or newline"}}

          {:error, _} = error ->
            error
        end

      {status, _, _} when status in [:ok, :more] ->
        {:error, :archive_too_large}

      {:error, _} ->
        {:error, {:bad_request, "could not read archive upload"}}
    end
  end

  defp consume(bytes, fd, state) do
    case :binary.match(bytes, "\n") do
      :nomatch when byte_size(bytes) <= @max_line ->
        {:ok, state, bytes}

      {len, 1} when len <= @max_line ->
        <<line::binary-size(^len), _newline, rest::binary>> = bytes

        with {:ok, row} when is_map(row) <- JSON.decode(line),
             {:ok, next} <- store_row(state, row, fd) do
          consume(rest, fd, next)
        else
          {:error, {kind, _}} = error when kind == :bad_request -> error
          _ -> {:error, {:bad_request, "invalid archive JSON record"}}
        end

      _ ->
        {:error, :archive_too_large}
    end
  end

  defp store_row(nil, header, fd), do: Archive.stage(header, fd)

  defp store_row(%{done: _}, _row, _fd),
    do: {:error, {:bad_request, "archive footer must be last"}}

  defp store_row(state, %{"end" => count}, _fd) do
    with {:ok, attrs} <- Archive.finish(state, count), do: {:ok, %{done: attrs}}
  end

  defp store_row(state, row, _fd), do: Archive.append(state, row)
end
