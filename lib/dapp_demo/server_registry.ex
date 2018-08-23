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

  def init(_opts) do
    :ets.new(__MODULE__, [:named_table, read_concurrency: true])
    {:ok, %{}}
  end

  def handle_call({:create, address, amount}, _from, state) do
    case lookup(address) do
      {:ok, data} ->
        {:reply, data, state}

      :error ->
        case DynamicSupervisor.start_child(
               DappDemo.DSupervisor,
               {DappDemo.Server, [address: address, amount: amount]}
             ) do
          {:ok, pid} ->
            :ets.insert(__MODULE__, {address, pid})

            ref = Process.monitor(pid)
            state = Map.put(state, ref, address)

            {:reply, {:ok, pid}, state}

          err ->
            {:reply, err, state}
        end
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
