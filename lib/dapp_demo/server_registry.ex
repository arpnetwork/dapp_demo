defmodule DappDemo.ServerRegistry do
  @moduledoc false

  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def create(address, amount) do
    GenServer.call(__MODULE__, {:create, address, amount})
  end

  def lookup(address) do
    case :ets.lookup(__MODULE__, address) do
      [{^address, pid}] -> {:ok, pid}
      [] -> :error
    end
  end

  def lookup_all() do
    :ets.match_object(__MODULE__, {:"$1", :"$2"})
  end

  def init(_opts) do
    server_tab =
      :ets.new(__MODULE__, [
        :named_table,
        :public,
        write_concurrency: true,
        read_concurrency: true
      ])

    :ets.new(DappDemo.Device, [
      :named_table,
      :public,
      write_concurrency: true,
      read_concurrency: true
    ])

    {:ok, {server_tab}}
  end

  def handle_call({:create, address, amount}, _from, {server_tab} = state) do
    case lookup(address) do
      {:ok, data} ->
        {:reply, data, state}

      :error ->
        case DynamicSupervisor.start_child(
               DappDemo.DSupervisor,
               {DappDemo.Server, [address: address, amount: amount, server_tab: server_tab]}
             ) do
          {:ok, pid} ->
            :ets.insert(server_tab, {address, pid})
            {:reply, {:ok, pid}, state}

          err ->
            {:reply, err, state}
        end
    end
  end
end
