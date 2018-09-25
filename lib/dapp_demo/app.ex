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
    with {:ok, dev} <- DevicePool.lookup(address) do
      Device.install(dev.pid, package, url, filesize, md5)
    end
  end

  def install_notify(address, package, result) do
    with {:ok, dev} <- DevicePool.lookup(address) do
      Device.install_notify(dev.pid, package, result)
    end
  end

  def uninstall(address, package) do
    with {:ok, dev} <- DevicePool.lookup(address) do
      Device.uninstall(dev.pid, package)
    end
  end

  def start(address, package) do
    with {:ok, dev} <- DevicePool.lookup(address) do
      Device.start_app(dev.pid, package)
    end
  end
end
