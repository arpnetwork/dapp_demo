defmodule DappDemo.Auto do
  require Logger

  alias DappDemo.{Config, DevicePool, Server, ServerRegistry}

  use GenServer

  @check_interval 10000
  @total_device 100

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def install_finish(address) do
    GenServer.cast(__MODULE__, {:install_finish, address})
  end

  def init(_opts) do
    installed = %{}

    Process.send_after(self(), :check_interval, @check_interval)
    {:ok, installed}
  end

  def handle_cast({:install_finish, address}, installed) do
    {:noreply, Map.delete(installed, address)}
  end

  def handle_info(:check_interval, installed) do
    apps =
      with {:ok, data} <- File.read(Config.get(:app_data_file2)),
           {:ok, list} <- Poison.decode(data) do
        list
      else
        _ ->
          []
      end

    servers = ServerRegistry.lookup_all()
    devices = DevicePool.lookup_all()

    Enum.each(servers, fn {_, pid} ->
      if length(devices) < @total_device do
        DappDemo.Server.device_request(
          pid,
          Config.get(:price),
          Config.get(:ip),
          Config.get(:port)
        )
      end
    end)

    installed =
      Enum.reduce(installed, %{}, fn {addr, pkg}, acc ->
        if List.keymember?(devices, addr, 1) do
          Map.put(acc, addr, pkg)
        else
          acc
        end
      end)

    installed =
      Enum.reduce(devices, installed, fn {_, dev}, acc ->
        if is_nil(dev.package) && !Map.has_key?(installed, dev.address) do
          {:ok, app} = Enum.fetch(apps, :rand.uniform(length(apps)) - 1)

          try do
            if :ok ==
                 DappDemo.App.install(dev, app["package"], app["url"], app["size"], app["md5"]) do
              Map.put(acc, dev.address, app["package"])
            else
              acc
            end
          rescue
            e ->
              Logger.warn(inspect(e))

              case ServerRegistry.lookup(dev.server_address) do
                {:ok, pid} ->
                  Server.device_release(pid, dev.address)

                _ ->
                  nil
              end

              acc
          end
        else
          acc
        end
      end)

    Process.send_after(self(), :check_interval, @check_interval)

    {:noreply, installed}
  end
end
