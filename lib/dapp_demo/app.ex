defmodule DappDemo.App do
  @moduledoc false

  alias DappDemo.{Config, Device, DevicePool}

  def list() do
    file = Config.get(:app_list)

    with {:ok, data} <- File.read(file),
         {:ok, list} <- Poison.decode(data) do
      Enum.map(list, fn m ->
        Map.take(m, ["title", "description", "poster", "logo", "rating", "package_name"])
      end)
    else
      _ ->
        []
    end
  end

  def install(address, package, url, filesize, md5) do
    {:ok, dev} = DevicePool.lookup(address)
    Device.install(dev.pid, package, url, filesize, md5)
  end

  def install_notify(address, package, result) do
    {:ok, dev} = DevicePool.lookup(address)
    Device.install_notify(dev.pid, package, result)
  end

  def uninstall(address, package) do
    {:ok, dev} = DevicePool.lookup(address)
    Device.uninstall(dev.pid, package)
  end

  def start(address, package) do
    {:ok, dev} = DevicePool.lookup(address)
    Device.start_app(dev.pid, package)
  end
end
