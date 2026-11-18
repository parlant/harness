defmodule HWeb.Layouts do
  @moduledoc """
  Application and root HTML layouts for `HWeb`.
  """
  use HWeb, :html

  embed_templates("layouts/*")
end
