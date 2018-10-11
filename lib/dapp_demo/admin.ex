defmodule DappDemo.Admin do
  @moduledoc """
  Admin.
  """

  require Logger

  alias DappDemo.{
    Account,
    App,
    Config,
    Contract,
    Crypto,
    Device,
    DevicePool,
    Server,
    ServerRegistry
  }

  use GenServer

  @check_interval 10000

  def start(auth) do
    bind_server = Config.get(:bind_server)
    amount = Config.get(:amount)
    Application.put_env(:ethereumex, :url, Config.get(:eth_node))

    keystore = read_keystore(Config.get(:keystore_file)) || Config.get_keystore()

    with {:ok, %{address: address}} <- Account.set_key(keystore, auth),
         :ok <- check_eth_balance(address),
         :ok <- check_arp_balance(address) do
      servers = Config.get_servers()

      if bind_server do
        ServerRegistry.create(bind_server, amount)
      end

      if Map.size(servers) > 0 do
        Enum.each(servers, fn {address, amount} ->
          ServerRegistry.create(address, amount)
        end)
      else
        with {:ok, servers} <- Contract.get_bound_servers(Account.address()) do
          Enum.each(servers, fn address ->
            ServerRegistry.create(address, amount)
          end)
        end
      end

      Process.send_after(__MODULE__, :check_interval, @check_interval)

      :ok
    else
      error ->
        error
    end
  end

  def add_server(address, amount \\ nil) do
    ServerRegistry.create(address |> String.downcase(), amount || Config.get(:amount))
  end

  def remove_server(address) do
    with {:ok, pid} <- ServerRegistry.lookup(address |> String.downcase()) do
      Server.unbind(pid)
    end
  end

  def verify_password(password) do
    keystore = Config.get_keystore()

    with {:ok, private_key} <- Crypto.decrypt_keystore(keystore, password) do
      if Account.private_key() == private_key do
        :ok
      else
        :error
      end
    else
      _ ->
        :error
    end
  end

  def import_private_key(private_key, password) do
    keystore = Crypto.encrypt_private_key(private_key, password)
    Config.set_keystore(keystore)
    Account.set_key(private_key)
  end

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_opts) do
    {:ok, %{}}
  end

  def handle_info(:check_interval, state) do
    apps =
      with {:ok, data} <- File.read(Config.get(:app_list)),
           {:ok, list} <- Poison.decode(data) do
        list
      else
        _ ->
          []
      end

    devices = DevicePool.lookup_all()

    request_device(devices)

    if length(apps) > 0 do
      app_packages = Enum.map(apps, & &1["package_name"])

      Enum.each(devices, fn {_, dev} ->
        cond do
          not Device.is_idle?(dev) ->
            nil

          app_packages
          |> Enum.drop_while(&Enum.member?(dev.failed_packages, &1))
          |> Enum.empty?() ->
            # all app install failed, release device.
            Device.release(dev.pid)

          true ->
            app =
              Enum.find(apps, nil, fn app ->
                !Enum.member?(dev.packages, app["package_name"]) &&
                  !Enum.member?(dev.failed_packages, app["package_name"]) &&
                  !Enum.find(dev.installing_packages, nil, fn {pkg, _} ->
                    pkg == app["package_name"]
                  end)
              end)

            if app do
              App.install(
                dev.address,
                app["package_name"],
                app["url"],
                app["size"],
                app["md5"]
              )
            end
        end
      end)
    end

    Process.send_after(self(), :check_interval, @check_interval)

    {:noreply, state}
  end

  defp check_eth_balance(address) do
    min_balance = Contract.one_ether()

    case Contract.get_eth_balance(address) do
      {:ok, eth_balance} when eth_balance >= min_balance ->
        :ok

      {:ok, _} ->
        {:error, "eth balance is not enough!"}

      err ->
        err
    end
  end

  defp check_arp_balance(address) do
    min_balance = Config.get(:amount)

    case Contract.get_arp_balance(address) do
      {:ok, arp_balance} when arp_balance >= min_balance ->
        :ok

      {:ok, _} ->
        {:error, "arp balance is not enough!"}

      err ->
        err
    end
  end

  defp request_device(devices) do
    idle_device_count = Enum.count(devices, fn {_, dev} -> Device.is_idle?(dev) end)

    ok_servers =
      Enum.filter(ServerRegistry.lookup_all(), fn {_, pid} ->
        s = Server.get(pid)

        if s do
          Server.is_ok?(s)
        end
      end)

    ok_server_count = length(ok_servers)

    min_idle_device = Config.get(:min_idle_device)

    if ok_server_count > 0 && idle_device_count < min_idle_device do
      c = div(min_idle_device - idle_device_count, ok_server_count)

      Enum.each(ok_servers, fn {_, pid} ->
        Enum.each(0..c, fn _ ->
          DappDemo.Server.device_request(
            pid,
            Config.get(:price),
            Config.get(:ip),
            Config.get(:port)
          )
        end)
      end)
    end
  end

  defp read_keystore(keystore_filepath) do
    with true <- is_binary(keystore_filepath),
         {:ok, file} <- File.read(keystore_filepath),
         {:ok, file_map} <- file |> String.downcase() |> Poison.decode(keys: :atoms) do
      file_map
    else
      _ ->
        nil
    end
  end
end
