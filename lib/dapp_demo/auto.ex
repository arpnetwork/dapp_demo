defmodule DappDemo.Auto do
  require Logger

  alias DappDemo.ServerRegistry
  alias DappDemo.DevicePool

  use GenServer

  @check_interval 10000
  @total_device 100
  @price Application.get_env(:dapp_demo, :price)
  @ip Application.get_env(:dapp_demo, :ip)
  @port Application.get_env(:dapp_demo, :port)
  @app_data_file2 Application.get_env(:dapp_demo, :app_data_file2)

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def install_finish(address) do
    GenServer.cast(__MODULE__, {:install_finish, address})
  end

  def init(_opts) do
    apps =
      with {:ok, data} <- File.read(@app_data_file2),
           {:ok, list} <- Poison.decode(data) do
        list
      else
        _ ->
          []
      end

    installed = %{}

    Process.send_after(self(), :check_interval, @check_interval)
    {:ok, {apps, installed}}
  end

  def handle_cast({:install_finish, address}, {apps, installed}) do
    {:noreply, {apps, Map.delete(installed, address)}}
  end

  def handle_info(:check_interval, {apps, installed}) do
    servers = ServerRegistry.lookup_all()
    devices = DevicePool.lookup_all()

    Enum.each(servers, fn {_, pid} ->
      if length(devices) < @total_device do
        DappDemo.Server.device_request(pid, @price, @ip, @port)
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

          if :ok == DappDemo.App.install(dev, app["package"], app["url"], app["size"], app["md5"]) do
            Map.put(acc, dev.address, app["package"])
          else
            acc
          end
        else
          acc
        end
      end)

    Process.send_after(self(), :check_interval, @check_interval)

    {:noreply, {apps, installed}}
  rescue
    e ->
      Logger.warn(inspect(e))
      Process.send_after(self(), :check_interval, @check_interval)
      {:noreply, {apps, installed}}
  end
end
