defmodule DappDemo.ServerRegistry do
  @moduledoc false

  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def create(address, ip, port, cid) do
    GenServer.call(__MODULE__, {:create, address, ip, port, cid})
  end

  def lookup(address) do
    case :ets.lookup(__MODULE__, String.downcase(address)) do
      [{^address, data}] -> {:ok, data}
      [] -> :error
    end
  end

  def init(_opts) do
    :ets.new(__MODULE__, [:named_table, read_concurrency: true])
    {:ok, %{}}
  end

  def handle_call({:create, address, ip, port, cid}, _from, state) do
    case lookup(address) do
      {:ok, data} ->
        {:reply, data, state}

      :error ->
        server_data = %{address: address, ip: ip, port: port, cid: cid}

        {:ok, pid} =
          DynamicSupervisor.start_child(
            DappDemo.DSupervisor,
            {DappDemo.Server, [data: server_data]}
          )

        :ets.insert(__MODULE__, {address, Map.put(server_data, :pid, pid)})

        ref = Process.monitor(pid)
        state = Map.put(state, ref, address)

        {:reply, server_data, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {address, state} = Map.pop(state, ref)
    :ets.delete(__MODULE__, address)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
