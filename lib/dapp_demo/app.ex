defmodule DappDemo.App do
  @moduledoc false

  alias JSONRPC2.Client.HTTP
  alias DappDemo.API.Jsonrpc2.Protocol
  alias DappDemo.{Account, Server, ServerRegistry, Device, DevicePool, SendNonce, Utils}

  @app_install_success 0
  @app_download_failed 1
  @app_install_failed 2

  @app_data_file Application.get_env(:dapp_demo, :app_data_file)

  def list() do
    with {:ok, data} <- File.read(@app_data_file),
         {:ok, list} <- Poison.decode(data) do
      list
    else
      _ ->
        []
    end
  end

  def install(dev, package, url, filesize, md5) do
    query(dev.address, dev.ip, dev.api_port, "app_install", [
      package,
      url,
      filesize,
      md5
    ])
  end

  def install_notify(address, result, package) do
    {:ok, dev} = DevicePool.lookup(address)

    DappDemo.Auto.install_finish(address)

    case result do
      @app_install_success ->
        Device.install_success(dev.pid, package)

      @app_download_failed ->
        case ServerRegistry.lookup(dev.server_address) do
          {:ok, pid} ->
            Server.device_release(pid, address)
        end

      @app_install_failed ->
        case ServerRegistry.lookup(dev.server_address) do
          {:ok, pid} ->
            Server.device_release(pid, address)
        end
    end
  end

  def uninstall(dev) do
    Device.uninstall_success(dev.pid)
    query(dev.address, dev.ip, dev.api_port, "app_uninstall", [dev.package])
  end

  def start(dev) do
    query(dev.address, dev.ip, dev.api_port, "app_start", [dev.package])
  end

  defp query(dev_addr, ip, port, method, params) do
    private_key = Account.private_key()
    address = Account.address()

    nonce = SendNonce.get_and_update_nonce(address) |> Utils.encode_int()
    url = "http://#{ip}:#{port}"

    sign = Protocol.sign(method, params, nonce, dev_addr, private_key)

    case HTTP.call(url, method, params ++ [nonce, sign]) do
      {:ok, result} ->
        if Protocol.verify_resp_sign(result, address, dev_addr) do
          :ok
        else
          {:error, :verify_error}
        end

      {:error, err} ->
        {:error, err}
    end
  end
end
