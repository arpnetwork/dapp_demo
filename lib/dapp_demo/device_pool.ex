defmodule DappDemo.DevicePool do
  @moduledoc false

  alias DappDemo.Device

  use GenServer

  @check_interval 1_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def lookup(address) do
    case :ets.lookup(DappDemo.Device, address) do
      [{^address, dev}] -> {:ok, dev}
      [] -> :error
    end
  end

  def lookup_all() do
    :ets.match_object(DappDemo.Device, {:"$1", :"$2"})
  end

  def lookup_by_session(session) do
    fun = [
      {{:_, %{address: :"$2", session: :"$1"}}, [{:"=:=", {:const, session}, :"$1"}], [:"$2"]}
    ]

    case :ets.select(DappDemo.Device, fun, 1) do
      {[address], _} ->
        lookup(address)

      _ ->
        :error
    end
  end

  def request(package) do
    GenServer.call(__MODULE__, {:request, package})
  end

  def init(_opts) do
    Process.send_after(self(), :check_interval, @check_interval)
    {:ok, %{}}
  end

  def handle_call({:request, package}, _from, state) do
    devices = :ets.lookup(DappDemo.DevicePackages, package)
    dev = request_device(package, devices, nil)

    unless is_nil(dev) do
      {:reply, {:ok, dev}, state}
    else
      {:reply, {:error, :no_idle_device}, state}
    end
  end

  def handle_info(:check_interval, state) do
    # check device working
    res = :ets.match(DappDemo.Device, {:_, :"$1"})

    Enum.each(res, fn [dev] ->
      GenServer.cast(dev.pid, :check_interval)
    end)

    Process.send_after(self(), :check_interval, @check_interval)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp request_device(_, _, {:ok, dev}) do
    dev
  end

  defp request_device(_, [], _) do
    nil
  end

  defp request_device(package, devices, _) do
    {_, address} = dev = Enum.random(devices)

    res =
      with {:ok, d} <- lookup(address),
           0 <- d.state,
           {:ok, d} <- Device.request(d.pid, package) do
        {:ok, d}
      else
        _ ->
          :error
      end

    request_device(package, List.delete(devices, dev), res)
  end
end
