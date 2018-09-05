defmodule DappDemo.Auto do
  require Logger

  alias DappDemo.{Config, DevicePool, Server, ServerRegistry}

  use GenServer

  @check_interval 10000
  @total_device 100
  @install_timeout 600

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def start() do
    Process.send_after(__MODULE__, :check_interval, @check_interval)
  end

  def install_finish(address) do
    GenServer.cast(__MODULE__, {:install_finish, address})
  end

  def init(_opts) do
    # installing = %{"address" => {"package", timeout}}
    installing = %{}

    {:ok, installing}
  end

  def handle_cast({:install_finish, address}, installing) do
    {:noreply, Map.delete(installing, address)}
  end

  def handle_info(:check_interval, installing) do
    apps =
      with {:ok, data} <- File.read(Config.get(:app_list)),
           {:ok, list} <- Poison.decode(data) do
        list
      else
        _ ->
          []
      end

    servers = ServerRegistry.lookup_all()
    devices = DevicePool.lookup_all()

    now = DateTime.utc_now() |> DateTime.to_unix()

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

    # release timeout device.
    devices =
      Enum.reduce(devices, [], fn {addr, dev} = item, acc ->
        case Map.get(installing, addr) do
          {_, timeout} when now > timeout ->
            Logger.warn("install timeout. #{dev.address}")
            release_device(dev.server_address, dev.address)
            acc

          _ ->
            [item | acc]
        end
      end)

    # filter out invalid install info
    installing =
      Enum.reduce(installing, %{}, fn {addr, info}, acc ->
        if List.keymember?(devices, addr, 0) do
          Map.put(acc, addr, info)
        else
          acc
        end
      end)

    installing =
      if length(apps) > 0 do
        Enum.reduce(devices, installing, fn {_, dev}, acc ->
          if is_nil(dev.package) && !Map.has_key?(installing, dev.address) do
            {:ok, app} = Enum.fetch(apps, :rand.uniform(length(apps)) - 1)

            try do
              res =
                DappDemo.App.install(
                  dev,
                  app["package_name"],
                  app["url"],
                  app["size"],
                  app["md5"]
                )

              if :ok == res do
                Map.put(acc, dev.address, {app["package_name"], now + @install_timeout})
              else
                Logger.warn("send install fail. #{inspect(res)}")
                acc
              end
            rescue
              e ->
                Logger.warn("send install fail. #{inspect(e)}")
                release_device(dev.server_address, dev.address)
                acc
            end
          else
            acc
          end
        end)
      else
        installing
      end

    Process.send_after(self(), :check_interval, @check_interval)

    {:noreply, installing}
  end

  def release_device(server_address, device_address) do
    case ServerRegistry.lookup(server_address) do
      {:ok, pid} ->
        Server.device_release(pid, device_address)

      _ ->
        nil
    end
  end
end
