defmodule HWeb.Router do
  use HWeb, :router

  import HWeb.Auth, only: [require_authenticated_owner: 2]

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {HWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :owner_auth do
    plug(:require_authenticated_owner)
  end

  scope "/", HWeb do
    pipe_through(:browser)

    get("/login", AuthController, :new)
    post("/login", AuthController, :create)
    post("/logout", AuthController, :delete)
    delete("/logout", AuthController, :delete)
  end

  scope "/", HWeb do
    pipe_through([:browser, :owner_auth])

    post("/settings/providers", ProviderConfigController, :create)
    post("/settings/accounts/keys", AccountKeyController, :create)
    post("/settings/accounts/keys/use", AccountKeyController, :use)

    live_session :owner, on_mount: [{HWeb.Auth, :require_owner}] do
      live("/", WorkspaceLive, :index)
      live("/workspaces", WorkspaceLive, :index)
      live("/inbox", InboxLive, :index)
      live("/settings/providers", ProvidersLive, :index)
      live("/settings/accounts", AccountsLive, :index)
      live("/sessions/:session_id", SessionLive, :show)
      live("/sessions/:session_id/conversations/:conversation_id", SessionLive, :show)
    end
  end
end
