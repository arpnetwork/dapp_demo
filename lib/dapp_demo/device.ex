defmodule DappDemo.Device do
  require Logger

  use GenServer, restart: :temporary

  @idle 0
  @using 1

  @enforce_keys [:server_address, :address, :ip, :port, :price]
  defstruct [
    :pid,
    :server_address,
    :address,
    :ip,
    :port,
    :price,
    :inserted_at,
    :package,
    :session,
    :api_port,
    state: @idle,
    paid: 0
  ]

  @client_before_connected 0
  @client_using 1
  @client_stopped 2

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def release(pid) do
    if Process.alive?(pid) do
      GenServer.cast(pid, :release)
    else
      {:error, :invalid_pid}
    end
  end

  def verify(pid, session) do
    if Process.alive?(pid) do
      GenServer.call(pid, {:verify, session})
    else
      {:error, :invalid_pid}
    end
  end

  def install_success(pid, package) do
    if Process.alive?(pid) do
      GenServer.cast(pid, {:install_success, package})
    else
      {:error, :invalid_pid}
    end
  end

  def uninstall_success(pid) do
    if Process.alive?(pid) do
      GenServer.cast(pid, :uninstall_success)
    else
      {:error, :invalid_pid}
    end
  end

  def idle(pid, session) do
    if Process.alive?(pid) do
      GenServer.call(pid, {:idle, session})
    else
      {:error, :invalid_pid}
    end
  end

  def report(pid, session, state) do
    case state do
      @client_before_connected ->
        nil

      @client_using ->
        nil

      @client_stopped ->
        idle(pid, session)
    end
  end

  def request(pid, package) do
    GenServer.call(pid, {:request, package})
  end

  def add_paid(pid, amount) do
    GenServer.cast(pid, {:add_paid, amount})
  end

  # Callbacks

  def init(opts) do
    dev = opts[:device]
    dev = struct(dev, pid: self())
    :ets.insert(__MODULE__, {dev.address, dev})
    {:ok, {dev.address}}
  end

  def terminate(_reason, {address}) do
    :ets.delete(__MODULE__, address)
  end

  def handle_call({:verify, session}, _from, {address} = state) do
    with [{^address, device}] <- :ets.lookup(__MODULE__, address),
         ^session <- device.session do
      {:reply, :ok, state}
    else
      _ ->
        {:reply, {:error, :invalid_params}, state}
    end
  end

  def handle_call({:idle, session}, _from, {address} = state) do
    with [{^address, device}] <- :ets.lookup(__MODULE__, address),
         ^session <- device.session do
      device = struct(device, session: nil, state: @idle)
      :ets.insert(__MODULE__, {address, device})
      {:reply, :ok, state}
    else
      _ ->
        {:reply, {:error, :invalid_params}, state}
    end
  end

  def handle_call({:request, package}, _from, {address} = state) do
    with [{^address, device}] <- :ets.lookup(__MODULE__, address),
         ^package <- device.package do
      session = Base.encode64(:crypto.strong_rand_bytes(96))
      device = struct(device, state: @using, session: session)
      :ets.insert(__MODULE__, {address, device})
      {:reply, {:ok, device}, state}
    else
      _ ->
        {:reply, {:error, :invalid_params}, state}
    end
  end

  def handle_cast({:add_paid, amount}, {address} = state) do
    case :ets.lookup(__MODULE__, address) do
      [{^address, device}] ->
        device = struct(device, paid: device.paid + amount)
        :ets.insert(__MODULE__, {address, device})
        {:noreply, state}

      _ ->
        {:stop, :normal, state}
    end
  end

  def handle_cast({:install_success, package}, {address} = state) do
    case :ets.lookup(__MODULE__, address) do
      [{^address, device}] ->
        device = struct(device, package: package)
        :ets.insert(__MODULE__, {address, device})
        {:noreply, state}

      _ ->
        {:stop, :normal, state}
    end
  end

  def handle_cast(:uninstall_success, {address} = state) do
    case :ets.lookup(__MODULE__, address) do
      [{^address, device}] ->
        device = struct(device, package: nil)
        :ets.insert(__MODULE__, {address, device})
        {:noreply, state}

      _ ->
        {:stop, :normal, state}
    end
  end

  def handle_cast(:release, state) do
    {:stop, :normal, state}
  end

  def handle_cast(:check_interval, {address} = state) do
    # check device working
    case :ets.lookup(__MODULE__, address) do
      [{^address, device}] ->
        Task.async(fn ->
          url = "http://#{device.ip}:#{device.api_port}"

          case JSONRPC2.Client.HTTP.call(url, "device_ping", []) do
            {:ok, _} ->
              :ping_success

            {:error, _} ->
              :ping_failed
          end
        end)

        {:noreply, state}

      _ ->
        {:stop, :normal, state}
    end
  end

  def handle_info({_ref, :ping_failed}, {address} = state) do
    Logger.info("device ping failed. #{address}")
    {:stop, :normal, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
