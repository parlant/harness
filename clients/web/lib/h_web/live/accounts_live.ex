defmodule HWeb.AccountsLive do
  use HWeb, :live_view

  alias H.Accounts
  alias HWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    opts = H.Daemon.instance_options() || Application.get_env(:harness_web, :daemon_opts, [])

    {:ok,
     socket
     |> assign(
       accounts: opts[:accounts],
       codex_account_policy: opts[:codex_account_policy],
       flow: nil,
       sources: [],
       provider_status_note: nil,
       keys: []
     )
     |> refresh()}
  end

  @impl true
  def handle_event("add", %{"source" => source}, socket) do
    result(socket, Accounts.add(socket.assigns.accounts, %{"source" => source}))
  end

  def handle_event("activate", %{"source" => source}, socket) do
    result(socket, Accounts.activate(socket.assigns.accounts, %{"source" => source}))
  end

  def handle_event("login", %{"source" => source}, socket) do
    id = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    params = %{"provider" => "openai_codex", "request_id" => id, "source" => source}
    operation(socket, Accounts.start(socket.assigns.accounts, params))
  end

  def handle_event("cancel", _params, %{assigns: %{flow: %{operation: ref}}} = socket) do
    operation(socket, Accounts.operation(socket.assigns.accounts, :cancel, %{"operation" => ref}))
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:poll, ref}, %{assigns: %{flow: %{operation: ref, state: state}}} = socket)
      when state in ["starting", "pending"] do
    operation(socket, Accounts.operation(socket.assigns.accounts, :status, %{"operation" => ref}))
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp result(socket, {:ok, _}), do: {:noreply, refresh(socket)}
  defp result(socket, {:error, reason}), do: {:noreply, put_flash(socket, :error, error(reason))}

  defp operation(socket, {:ok, %{operation: ref, state: state} = flow}) do
    if state in ["starting", "pending"], do: Process.send_after(self(), {:poll, ref}, 1000)
    {:noreply, socket |> assign(:flow, flow) |> refresh()}
  end

  defp operation(socket, {:error, reason})
       when reason in [:login_not_found, :accounts_unavailable],
       do: result(assign(socket, :flow, nil), {:error, reason})

  defp operation(socket, {:error, reason}), do: result(socket, {:error, reason})

  defp refresh(socket) do
    server = socket.assigns.accounts
    policy = socket.assigns.codex_account_policy

    {sources, provider_status_note} =
      case Accounts.discover(server, policy) do
        {:ok, %{providers: [%{sources: sources} = provider]}} ->
          {sources, provider[:status_note]}

        _ ->
          {[], nil}
      end

    keys =
      case Accounts.api_keys(server) do
        {:ok, %{providers: providers}} -> providers
        _ -> []
      end

    assign(socket, sources: sources, provider_status_note: provider_status_note, keys: keys)
  end

  defp error(:credential_unavailable), do: "Sign into that alias before selecting it."
  defp error(:login_busy), do: "A login or credential refresh is already running."
  defp error(:too_many_account_sources), do: "At most eight aliases can be configured."
  defp error(:invalid_login_request), do: "Enter a valid account alias."
  defp error(_), do: "The daemon could not complete the account operation."

  @impl true
  def render(assigns) do
    ~H"""
    <div class="screen">
      <Layouts.app_bar title="Keys & accounts" section={:accounts} />
      <main class="screen-scroll" aria-label="Keys and accounts">
        <div id="account-settings" class="settings-page">
          <section class="settings-card">
            <h2>API-key profiles</h2>
            <p>Keys are write-only. Saving the first alias selects it for this provider.</p>
            <form
              id="save-api-key"
              action={~p"/settings/accounts/keys"}
              method="post"
              autocomplete="off"
            >
              <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
              <label class="field-group">
                <span class="field-label">Provider</span>
                <select class="input" name="provider" required>
                  <option :for={profile <- @keys} value={profile.provider}>{profile.provider}</option>
                </select>
              </label>
              <label class="field-group"><span class="field-label">Alias</span>
              <input
                class="input"
                name="source"
                required
                maxlength="32"
                pattern="[a-z][a-z0-9_-]{0,31}"
              /></label>
              <label class="field-group"><span class="field-label">API key</span>
              <input
                class="input"
                type="password"
                name="api_key"
                required
                maxlength="2048"
                autocomplete="new-password"
              /></label>
              <button class="btn btn-primary" type="submit">Save key</button>
            </form>
            <ul>
              <li :for={profile <- @keys}>
                <span>{profile.provider}</span>
                <span :if={profile.sources == []}> · no stored key</span>
                <form
                  :for={source <- profile.sources}
                  action={~p"/settings/accounts/keys/use"}
                  method="post"
                >
                  <input
                    type="hidden"
                    name="_csrf_token"
                    value={Plug.CSRFProtection.get_csrf_token()}
                  />
                  <input type="hidden" name="provider" value={profile.provider} />
                  <input type="hidden" name="source" value={source} />
                  <span>{source}</span>
                  <span :if={source == profile.active}> · active</span>
                  <button :if={source != profile.active} type="submit" class="btn btn-sm">Use alias</button>
                </form>
              </li>
            </ul>
          </section>
          <section class="settings-card">
            <h2>Codex device accounts</h2>
            <p>These settings are shared by this daemon's terminal and web clients.</p>
            <p :if={@provider_status_note} id="provider-status-note" class="muted">
              {@provider_status_note}
            </p>
            <form id="add-account" phx-submit="add">
              <label class="field-label" for="account-alias">Account alias</label>
              <input
                id="account-alias"
                class="input"
                name="source"
                type="text"
                maxlength="32"
                pattern="[a-z][a-z0-9_-]{0,31}"
                required
              />
              <button class="btn" type="submit">Add alias</button>
            </form>
            <ul>
              <li :for={source <- @sources} id={"account-#{source.id}"}>
                {source.id} · {String.replace(source.state, "_", " ")}
                <span :if={source[:status_note]} class="badge mono">
                  {source.status_note}
                </span>
                <span :if={source.active}> · stock active</span>
                <button class="btn btn-sm" phx-click="login" phx-value-source={source.id}>Sign in</button>
                <button
                  :if={!source.active}
                  class="btn btn-sm"
                  phx-click="activate"
                  phx-value-source={source.id}
                >Use in stock mode</button>
              </li>
            </ul>
            <button :if={@sources == []} class="btn" phx-click="login" phx-value-source="default">Set up device login</button>
            <section :if={@flow} id="device-flow">
              <p>Login for {@flow.source}: {@flow.state}</p>
              <p :if={Map.has_key?(@flow, :user_code)}>
                Open
                <a
                  href="https://auth.openai.com/codex/device"
                  target="_blank"
                  rel="noopener noreferrer"
                >OpenAI device verification</a>
                and enter <code>{Map.get(@flow, :user_code)}</code>. Approve only the login you initiated.
              </p>
              <button
                :if={@flow.state in ["starting", "pending"]}
                class="btn btn-sm"
                phx-click="cancel"
              >Cancel login</button>
            </section>
          </section>
        </div>
      </main>
    </div>
    """
  end
end
