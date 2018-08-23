defmodule DappDemo.Device do
  require Logger

  use GenServer

  @idle 0
  @using 1

  @check_interval 9_000

  @enforce_keys [:server_address, :address, :ip, :port, :price]
  defstruct [
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

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def insert(dev) do
    GenServer.call(__MODULE__, {:insert, dev})
  end

  def remove(address) do
    GenServer.call(__MODULE__, {:remove, address})
  end

  def verify(address, session) do
    GenServer.call(__MODULE__, {:verify, address, session})
  end

  def lookup(address) do
    GenServer.call(__MODULE__, {:lookup, address})
  end

  def all() do
    GenServer.call(__MODULE__, :all)
  end

  def install_success(address, package) do
    GenServer.call(__MODULE__, {:install_success, address, package})
  end

  def idle(address, session) do
    GenServer.call(__MODULE__, {:idle, address, session})
  end

  def idle_by_session(session) do
    GenServer.call(__MODULE__, {:idle_by_session, session})
  end

  def request(package) do
    GenServer.call(__MODULE__, {:request, package})
  end

  def report(session, state) do
    case state do
      @client_before_connected ->
        nil

      @client_using ->
        nil

      @client_stopped ->
        idle_by_session(session)
    end
  end

  def add_paid(address, amount) do
    GenServer.call(__MODULE__, {:add_paid, address, amount})
  end

  # Callbacks

  def init(_opts) do
    Process.send_after(self(), :check_interval, @check_interval)
    {:ok, {%{}, %{}}}
  end

  def handle_call({:insert, dev}, _from, {devices, users} = state) do
    unless Map.has_key?(devices, dev.address) do
      dev = struct(dev, inserted_at: DateTime.utc_now() |> DateTime.to_unix())
      {:reply, :ok, {Map.put(devices, dev.address, dev), users}}
    else
      {:reply, {:error, :duplicate_device}, state}
    end
  end

  def handle_call({:remove, address}, _from, {devices, users} = state) do
    case Map.fetch(devices, address) do
      {:ok, dev} ->
        devices = Map.delete(devices, address)
        users = Map.delete(users, dev.session)
        {:reply, :ok, {devices, users}}

      _ ->
        {:reply, {:error, :no_device}, state}
    end
  end

  def handle_call({:verify, address, session}, _from, {devices, _users} = state) do
    with {:ok, dev} <- Map.fetch(devices, address),
         ^session <- dev.session do
      {:reply, :ok, state}
    else
      _ ->
        {:reply, {:error, :invalid_params}, state}
    end
  end

  def handle_call({:lookup, address}, _from, {devices, _users} = state) do
    {:reply, Map.get(devices, address, nil), state}
  end

  def handle_call(:all, _from, {devices, _users} = state) do
    {:reply, devices, state}
  end

  def handle_call({:install_success, address, package}, _from, {devices, users} = state) do
    case Map.fetch(devices, address) do
      {:ok, dev} ->
        dev = struct(dev, package: package, session: nil)
        devices = Map.put(devices, address, dev)
        {:reply, :ok, {devices, users}}

      _ ->
        {:reply, {:error, :no_device}, state}
    end
  end

  def handle_call({:idle, address, session}, _from, {devices, users} = state) do
    with {:ok, dev} <- Map.fetch(devices, address),
         ^session <- dev.session do
      users = Map.delete(users, session)
      dev = struct(dev, session: nil, state: @idle)
      devices = Map.put(devices, address, dev)
      {:reply, :ok, {devices, users}}
    else
      _ ->
        {:reply, {:error, :invalid_params}, state}
    end
  end

  def handle_call({:idle_by_session, session}, _from, {devices, users} = state) do
    case Map.fetch(users, session) do
      {:ok, address} ->
        users = Map.delete(users, session)

        {:ok, dev} = Map.fetch(devices, address)
        dev = struct(dev, session: nil, state: @idle)
        devices = Map.put(devices, address, dev)

        {:reply, :ok, {devices, users}}

      _ ->
        {:reply, {:error, :no_device}, state}
    end
  end

  def handle_call({:request, package}, _from, {devices, users} = state) do
    dev =
      Enum.find_value(devices, nil, fn {_, dev} ->
        if dev.state == @idle && dev.package == package, do: dev
      end)

    unless is_nil(dev) do
      session = Base.encode64(:crypto.strong_rand_bytes(96))
      dev = struct(dev, state: @using, session: session)
      devices = Map.put(devices, dev.address, dev)
      users = Map.put(users, session, dev.address)

      {:reply, {:ok, dev}, {devices, users}}
    else
      {:reply, {:error, :no_idle_device}, state}
    end
  end

  def handle_call({:add_paid, address, amount}, _from, {devices, users} = state) do
    case Map.fetch(devices, address) do
      {:ok, dev} ->
        dev = struct(dev, paid: dev.paid + amount)
        devices = Map.put(devices, address, dev)
        {:reply, :ok, {devices, users}}

      _ ->
        {:reply, {:error, :no_device}, state}
    end
  end

  def handle_info(:check_interval, {devices, _users} = state) do
    # check device working
    Enum.each(devices, fn {addr, dev} ->
      Task.async(fn ->
        url = "http://#{dev.ip}:#{dev.api_port}"

        case JSONRPC2.Client.HTTP.call(url, "device_ping", []) do
          {:ok, _} ->
            # nothing
            nil

          {:error, _} ->
            Logger.info("device ping failed. #{addr}")
            {:ok, pid} = DappDemo.ServerRegistry.lookup(dev.server_address)
            DappDemo.Server.device_release(pid, dev.address)
        end
      end)
    end)

    Process.send_after(self(), :check_interval, @check_interval)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
