defmodule H.AuthTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias H.Auth

  setup do
    id = System.unique_integer([:positive])
    tmp_dir = Path.join(System.tmp_dir!(), "h-auth-test-#{id}")
    table = :"h_auth_test_#{id}"
    server = :"H.Auth.Test.#{id}"

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    {:ok, data_dir: tmp_dir, table: table, server: server}
  end

  describe "owner_token/1" do
    test "generates and persists a 32-byte owner token with 0600 permissions", %{
      data_dir: data_dir,
      table: table,
      server: server
    } do
      start_supervised!({Auth, data_dir: data_dir, name: server, table: table})

      token = Auth.owner_token(table)
      assert is_binary(token)
      assert {:ok, raw} = Base.url_decode64(token, padding: false)
      assert byte_size(raw) == 32

      token_path = Path.join(data_dir, "auth.token")
      {:ok, stat} = File.stat(token_path)
      assert (stat.mode &&& 0o777) == 0o600
      assert String.trim(File.read!(token_path)) == token

      stop_supervised!(Auth)

      table2 = :"#{table}_reloaded"
      server2 = :"#{server}.Reloaded"
      start_supervised!({Auth, data_dir: data_dir, name: server2, table: table2})
      assert Auth.owner_token(table2) == token
    end
  end

  describe "verify_bearer/2" do
    test "verifies owner token in constant time and rejects invalid candidates", %{
      data_dir: data_dir,
      table: table,
      server: server
    } do
      start_supervised!({Auth, data_dir: data_dir, name: server, table: table})
      token = Auth.owner_token(table)

      assert Auth.verify_bearer(token, table)
      refute Auth.verify_bearer(token <> "x", table)
      refute Auth.verify_bearer("wrong", table)
      refute Auth.verify_bearer(nil, table)
      refute Auth.verify_bearer(123, table)
    end
  end

  describe "create_browser_session/3 and verify_cookie/2" do
    test "mints a fresh cookie only for a valid owner token", %{
      data_dir: data_dir,
      table: table,
      server: server
    } do
      start_supervised!({Auth, data_dir: data_dir, name: server, table: table})
      token = Auth.owner_token(table)

      assert {:error, :unauthorized} = Auth.create_browser_session("bad-token", server, table)
      assert {:error, :unauthorized} = Auth.create_browser_session(nil, server, table)

      assert {:ok, cookie1} = Auth.create_browser_session(token, server, table)
      assert {:ok, cookie2} = Auth.create_browser_session(token, server, table)
      assert cookie1 != cookie2
      assert cookie1 != token

      assert {:ok, raw} = Base.url_decode64(cookie1, padding: false)
      assert byte_size(raw) == 32

      assert Auth.verify_cookie(cookie1, table)
      assert Auth.verify_cookie(cookie2, table)
      refute Auth.verify_cookie(token, table)
      refute Auth.verify_cookie("invalid-cookie", table)
      refute Auth.verify_cookie(nil, table)
    end
  end

  describe "create_sign_in_code/4 and redeem_sign_in_code/3" do
    test "mints a single-use code that redeems into a valid browser session cookie", %{
      data_dir: data_dir,
      table: table,
      server: server
    } do
      start_supervised!({Auth, data_dir: data_dir, name: server, table: table})
      token = Auth.owner_token(table)

      assert {:error, :unauthorized} = Auth.create_sign_in_code("bad-token", server, table)
      assert {:error, :unauthorized} = Auth.create_sign_in_code(nil, server, table)

      assert {:ok, code} = Auth.create_sign_in_code(token, server, table)
      assert is_binary(code)
      assert code != token
      assert {:ok, raw} = Base.url_decode64(code, padding: false)
      assert byte_size(raw) == 32

      refute Auth.verify_cookie(code, table)

      assert {:ok, cookie} = Auth.redeem_sign_in_code(code, server, table)
      assert cookie != code
      assert cookie != token
      assert Auth.verify_cookie(cookie, table)

      # Single-use: a second redemption of the same code must fail.
      assert {:error, :unauthorized} = Auth.redeem_sign_in_code(code, server, table)
      assert {:error, :unauthorized} = Auth.redeem_sign_in_code("bogus-code", server, table)
      assert {:error, :unauthorized} = Auth.redeem_sign_in_code("", server, table)
      assert {:error, :unauthorized} = Auth.redeem_sign_in_code(nil, server, table)
    end

    test "expires unredeemed sign-in codes after their TTL", %{
      data_dir: data_dir,
      table: table,
      server: server
    } do
      start_supervised!({Auth, data_dir: data_dir, name: server, table: table})
      token = Auth.owner_token(table)

      assert {:ok, code} = Auth.create_sign_in_code(token, server, table, 20)
      Process.sleep(40)
      assert {:error, :unauthorized} = Auth.redeem_sign_in_code(code, server, table)
    end
  end

  describe "allowed_host?/3" do
    test "accepts strict loopback IP literals and gates localhost behind allow_localhost" do
      assert Auth.allowed_host?("127.0.0.1:4000", 4000)
      assert Auth.allowed_host?("[::1]:4000", 4000)
      refute Auth.allowed_host?("localhost:4000", 4000)
      assert Auth.allowed_host?("localhost:4000", 4000, allow_localhost: true)

      refute Auth.allowed_host?("127.0.0.1:4001", 4000)
      refute Auth.allowed_host?("evil.example:4000", 4000)
      refute Auth.allowed_host?(nil, 4000)
    end
  end

  describe "allowed_origin?/3" do
    test "accepts strict loopback HTTP origins" do
      assert Auth.allowed_origin?("http://127.0.0.1:4000", 4000)
      assert Auth.allowed_origin?("http://[::1]:4000", 4000)
      refute Auth.allowed_origin?("http://localhost:4000", 4000)
      assert Auth.allowed_origin?("http://localhost:4000", 4000, allow_localhost: true)

      refute Auth.allowed_origin?("https://127.0.0.1:4000", 4000)
      refute Auth.allowed_origin?("http://127.0.0.1:4001", 4000)
      refute Auth.allowed_origin?("http://evil.example:4000", 4000)
      refute Auth.allowed_origin?(nil, 4000)
    end
  end
end
