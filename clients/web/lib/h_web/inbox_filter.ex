defmodule HWeb.InboxFilter do
  @moduledoc "URL-backed filters shared by the inbox and the session attention carousel."

  use HWeb, :verified_routes

  alias HWeb.CatalogState

  @modes ~w(inbox attention archived all)

  defstruct mode: "inbox", query: "", workspace: nil, tag: nil

  def from_params(params) do
    %__MODULE__{
      mode: if(params["filter"] in @modes, do: params["filter"], else: "inbox"),
      query: text(params["q"]) || "",
      workspace: workspace(params["env_id"] || "host", params["cwd"]),
      tag: text(params["tag"])
    }
  end

  def from_form(filter, params) do
    {env_id, cwd} =
      case is_binary(params["workspace"]) && JSON.decode(params["workspace"]) do
        {:ok, [env_id, cwd]} -> {env_id, cwd}
        _ -> {nil, nil}
      end

    from_params(%{
      "filter" => Map.get(params, "filter", filter.mode),
      "q" => params["q"],
      "env_id" => env_id,
      "cwd" => cwd,
      "tag" => params["tag"]
    })
  end

  def params(filter) do
    %{}
    |> put_nondefault(:filter, filter.mode, "inbox")
    |> put_nondefault(:q, filter.query, "")
    |> put_nondefault(:tag, filter.tag, nil)
    |> then(fn params ->
      case filter.workspace do
        {env_id, cwd} -> params |> Map.put(:cwd, cwd) |> put_nondefault(:env_id, env_id, "host")
        nil -> params
      end
    end)
  end

  def inbox_path(filter), do: ~p"/inbox?#{params(filter)}"

  def session_path(sid, filter, from_inbox? \\ true, cid \\ nil) do
    params =
      filter |> params() |> then(&if(from_inbox?, do: Map.put(&1, :from, "inbox"), else: &1))

    if cid do
      ~p"/sessions/#{sid}/conversations/#{cid}?#{params}"
    else
      ~p"/sessions/#{sid}?#{params}"
    end
  end

  def scope(filter, sessions) do
    sessions
    |> Enum.filter(fn s ->
      (is_nil(filter.workspace) or filter.workspace == {s.env_id, s.cwd}) and
        (is_nil(filter.tag) or filter.tag in s.tags)
    end)
    |> CatalogState.filter_sessions("all", filter.query)
  end

  def options(filter, sessions) do
    workspaces =
      [filter.workspace | Enum.map(sessions, &{&1.env_id, &1.cwd})]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.map(fn {env_id, cwd} = workspace ->
        {CatalogState.format_workspace_label(env_id, cwd, System.user_home()),
         workspace_value(workspace)}
      end)
      |> Enum.sort()

    tags =
      [filter.tag | Enum.flat_map(sessions, & &1.tags)]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    %{workspaces: workspaces, tags: tags}
  end

  def workspace_value(nil), do: ""
  def workspace_value({env_id, cwd}), do: JSON.encode!([env_id, cwd])

  defp workspace(env_id, "/" <> _ = cwd) do
    if text(env_id) && text(cwd), do: {env_id, cwd}
  end

  defp workspace(_, _), do: nil

  defp text(value) when is_binary(value) and value != "" do
    if String.valid?(value) and not String.contains?(value, <<0>>), do: value
  end

  defp text(_), do: nil

  defp put_nondefault(params, _, value, value), do: params
  defp put_nondefault(params, key, value, _), do: Map.put(params, key, value)
end
