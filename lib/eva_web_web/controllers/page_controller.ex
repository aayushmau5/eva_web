defmodule EvaWebWeb.PageController do
  use EvaWebWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
