defmodule DappDemo.Config do
  @moduledoc false

  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_opts) do
    pid = :ets.new(__MODULE__, [:named_table, read_concurrency: true])
    {:ok, pid}
  end

  def set(key, value) do
    GenServer.call(__MODULE__, {:set, key, value})
  end

  def get(key) do
    case :ets.lookup(__MODULE__, key) do
      [{^key, value}] ->
        value

      [] ->
        nil
    end
  end

  def handle_call({:set, key, value}, _from, pid) do
    :ets.insert(pid, {key, value})
    {:reply, :ok, pid}
  end
end
