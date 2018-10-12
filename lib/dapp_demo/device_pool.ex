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

  def request(package, width, height) do
    GenServer.call(__MODULE__, {:request, package, width, height})
  end

  def init(_opts) do
    Process.send_after(self(), :check_interval, @check_interval)
    {:ok, %{}}
  end

  def handle_call({:request, package, width, height}, _from, state) do
    devices = :ets.lookup(DappDemo.DevicePackages, package)

    devices =
      Enum.flat_map(devices, fn {_, address} ->
        case lookup(address) do
          {:ok, dev} ->
            [dev]

          _ ->
            []
        end
      end)

    sorted =
      Enum.sort(devices, fn x, y ->
        x_w =
          calc_weight(width, height, x.width, x.height, Map.get(x.crashed_packages, package, 0))

        y_w =
          calc_weight(width, height, y.width, y.height, Map.get(y.crashed_packages, package, 0))

        x_w > y_w
      end)

    dev = request_device(sorted, package, nil)

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

  defp request_device([], _, _) do
    nil
  end

  defp request_device(devices, package, _) do
    [dev | rest] = devices

    res =
      with 0 <- dev.state,
           {:ok, d} <- Device.request(dev.pid, package) do
        {:ok, d}
      else
        _ ->
          :error
      end

    request_device(rest, package, res)
  end

  defp calc_weight(client_width, client_height, device_width, device_height, broken_times) do
    aspect_ratio = abs(client_width / client_height - device_width / device_height)
    height_diff_ratio = abs(client_height - device_height) / device_height

    -(aspect_ratio * 10 + height_diff_ratio * 10 + broken_times * 5)
  end
end
