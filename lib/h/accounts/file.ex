defmodule H.Accounts.File do
  @moduledoc false

  def replace(dir, path, bytes) do
    tmp = path <> "." <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    with {:ok, file} <- File.open(tmp, [:write, :binary, :exclusive]) do
      try do
        result =
          with :ok <- File.chmod(tmp, 0o600),
               :ok <- IO.binwrite(file, bytes),
               do: :file.sync(file)

        with :ok <- File.close(file),
             :ok <- result,
             {:ok, directory} <- :file.open(String.to_charlist(dir), [:directory, :read, :raw]) do
          try do
            with :ok <- File.rename(tmp, path), do: :file.sync(directory)
          after
            :file.close(directory)
          end
        end
      after
        File.rm(tmp)
      end
    end
  end
end
