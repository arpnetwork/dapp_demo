defmodule DappDemo.API.Controller do
  @moduledoc """
  Response the user request.
  """

  alias DappDemo.API.Response
  alias DappDemo.API.Error
  alias DappDemo.{App, Device, DevicePool}

  @doc """
  Response the app list.
  """
  def app_list(conn) do
    resp_data = %{
      code: 0,
      data: App.list()
    }

    Response.render(conn, resp_data)
  end

  def device_request(conn, params) do
    with {:ok, dev} <- DevicePool.request(params["package"]) do
      App.start(dev)

      resp_data = %{
        code: 0,
        data: %{
          session: dev.session,
          ip: dev.ip,
          port: dev.port
        }
      }

      Response.render(conn, resp_data)
    else
      {:error, err} ->
        Response.render(conn, Error.new(err))
    end
  end

  def device_report(conn, params) do
    case DevicePool.lookup_by_session(params["session"]) do
      {:ok, dev} ->
        Device.report(dev.pid, params["session"], params["state"])

      _ ->
        nil
    end

    Response.render(conn, %{
      code: 0
    })
  end
end
