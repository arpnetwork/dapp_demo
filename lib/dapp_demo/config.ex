defmodule DappDemo.Config do
  @moduledoc false

  use GenServer

  @config_path Application.get_env(:dapp_demo, :data_dir)
               |> Path.join("config")
               |> String.to_charlist()

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_opts) do
    tab =
      case :ets.file2tab(@config_path, verify: true) do
        {:ok, tab} ->
          tab

        _ ->
          :ets.new(__MODULE__, [:named_table, read_concurrency: true])
      end

    config = Application.get_all_env(:dapp_demo)

    config =
      Enum.reduce(config, [], fn {key, value}, acc ->
        unless is_nil(value) do
          [{key, value} | acc]
        else
          acc
        end
      end)

    if length(config) > 0 do
      :ets.insert(__MODULE__, config)
      write_file(tab)
    end

    {:ok, tab}
  end

  def set(key, value) do
    GenServer.cast(__MODULE__, {:set, key, value})
  end

  def get(key) do
    case :ets.lookup(__MODULE__, key) do
      [{^key, value}] ->
        value

      [] ->
        nil
    end
  end

  def delete(key) do
    :ets.delete(__MODULE__, key)
  end

  def get_all() do
    :ets.match_object(__MODULE__, {:"$1", :"$2"})
  end

  def set_keystore(keystore) do
    GenServer.cast(__MODULE__, {:set_keystore, keystore})
  end

  def get_keystore() do
    case :ets.lookup(__MODULE__, :keystore) do
      [{:keystore, value}] ->
        value

      [] ->
        nil
    end
  end

  def get_servers() do
    case :ets.lookup(__MODULE__, :servers) do
      [{:servers, value}] ->
        value

      [] ->
        %{}
    end
  end

  def add_server(server, amount) do
    GenServer.cast(__MODULE__, {:add_server, server, amount})
  end

  def remove_server(server) do
    GenServer.cast(__MODULE__, {:remove_server, server})
  end

  def handle_cast({:set, key, value}, tab) do
    :ets.insert(tab, {key, value})
    write_file(tab)
    {:noreply, tab}
  end

  def handle_cast({:set_keystore, keystore}, tab) do
    :ets.insert(tab, {:keystore, keystore})
    write_file(tab)
    {:noreply, tab}
  end

  def handle_cast({:add_server, server, amount}, tab) do
    servers = get_servers()
    new_servers = Map.put(servers, server, amount)
    :ets.insert(tab, {:servers, new_servers})
    write_file(tab)
    {:noreply, tab}
  end

  def handle_cast({:remove_server, server}, tab) do
    servers = get_servers()
    new_servers = Map.delete(servers, server)
    :ets.insert(tab, {:servers, new_servers})
    write_file(tab)
    {:noreply, tab}
  end

  defp write_file(tab) do
    :ets.tab2file(tab, @config_path, extended_info: [:md5sum])
  end
end
