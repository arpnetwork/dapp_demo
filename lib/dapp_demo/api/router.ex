defmodule DappDemo.API.Router do
  @moduledoc """
  Define routes.
  """

  use Plug.Router
  use Plug.ErrorHandler

  require Logger

  alias DappDemo.API.Controller

  plug(:match)
  plug(Plug.Static, at: "/", from: "public", only_matching: ["images"])
  plug(Plug.Parsers, parsers: [:json], json_decoder: Poison)
  plug(:dispatch)

  get("/app/list", do: Controller.app_list(conn))

  post("/device/request", do: Controller.device_request(conn, conn.params))
  post("/device/report", do: Controller.device_report(conn, conn.params))

  match _ do
    send_resp(conn, :not_found, "Not Found")
  end

  def handle_errors(conn, %{kind: _kind, reason: _reason, stack: _stack}) do
    send_resp(conn, :internal_server_error, "Internal Server Error")
  end
end
