defmodule DappDemo.Device do
  require Logger

  alias DappDemo.{Account, Nonce, Utils}
  alias DappDemo.API.Jsonrpc2.Protocol
  alias JSONRPC2.Client.HTTP

  use GenServer, restart: :temporary

  @idle 0
  @installing 1
  @using 2

  @install_timeout 600

  @enforce_keys [:server_address, :address, :ip, :port, :price]
  defstruct [
    :pid,
    :server_address,
    :address,
    :width,
    :height,
    :ip,
    :port,
    :price,
    :inserted_at,
    :session,
    :api_port,
    packages: [],
    installing_packages: [],
    failed_packages: [],
    state: @idle,
    ping_failed: false,
    paid: 0
  ]

  @client_before_connected 0
  @client_using 1
  @client_stopped 2

  @app_install_success 0
  @app_download_failed 1
  @app_install_failed 2

  def is_idle?(dev) do
    dev.state == @idle
  end

  def is_installing?(dev) do
    dev.state == @installing
  end

  def is_using?(dev) do
    dev.state == @using
  end

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

  def install(pid, package, url, filesize, md5) do
    if Process.alive?(pid) do
      GenServer.call(pid, {:install, package, url, filesize, md5})
    else
      {:error, :invalid_pid}
    end
  end

  def uninstall(pid, package) do
    if Process.alive?(pid) do
      GenServer.call(pid, {:uninstall, package})
    else
      {:error, :invalid_pid}
    end
  end

  def start_app(pid, package) do
    if Process.alive?(pid) do
      GenServer.call(pid, {:start_app, package})
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

  def install_notify(pid, package, result) do
    if Process.alive?(pid) do
      GenServer.cast(pid, {:install_notify, package, result})
    else
      {:error, :invalid_pid}
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
    {:ok, %{address: dev.address, ping_failed: []}}
  end

  def terminate(_reason, %{address: address}) do
    :ets.match_delete(DappDemo.DevicePackages, {:_, address})
    :ets.delete(__MODULE__, address)
  end

  def handle_call({:verify, session}, _from, %{address: address} = state) do
    with [{^address, device}] <- :ets.lookup(__MODULE__, address),
         ^session <- device.session do
      {:reply, :ok, state}
    else
      _ ->
        {:reply, {:error, :invalid_params}, state}
    end
  end

  def handle_call({:install, package, url, filesize, md5}, _from, %{address: address} = state) do
    case :ets.lookup(__MODULE__, address) do
      [{^address, device}] ->
        cond do
          device.ping_failed ->
            {:reply, {:error, :device_ping_failed}, state}

          device.state != @idle ->
            {:reply, {:error, :device_busy}, state}

          Enum.member?(device.packages, package) ->
            {:reply, {:error, :already_installed}, state}

          Enum.member?(device.installing_packages, package) ->
            {:reply, {:error, :installing}, state}

          true ->
            failed_packages = List.delete(device.failed_packages, package)

            now = DateTime.utc_now() |> DateTime.to_unix()
            installing_packages = [{package, now} | device.installing_packages]

            device =
              struct(device,
                state: @installing,
                installing_packages: installing_packages,
                failed_packages: failed_packages
              )

            :ets.insert(__MODULE__, {address, device})

            Task.async(fn ->
              case send_request(address, device.ip, device.api_port, "app_install", [
                     package,
                     url,
                     filesize,
                     md5
                   ]) do
                :ok ->
                  {:install_request_result, :success, package}

                e ->
                  Logger.warn(inspect(e), label: "send install app failed")
                  {:install_request_result, :fail, package}
              end
            end)

            {:reply, :ok, state}
        end

      _ ->
        {:stop, :normal, state}
    end
  end

  def handle_call({:uninstall, package}, _from, %{address: address} = state) do
    with [{^address, device}] <- :ets.lookup(__MODULE__, address) do
      cond do
        device.ping_failed ->
          {:reply, {:error, :device_ping_failed}, state}

        true ->
          Task.async(fn ->
            send_request(address, device.ip, device.api_port, "app_uninstall", [package])
          end)

          :ets.delete_object(DappDemo.DevicePackages, {package, address})

          packages = List.delete(device.packages, package)
          device = struct(device, packages: packages)
          :ets.insert(__MODULE__, {address, device})

          {:reply, :ok, state}
      end
    else
      _ ->
        {:reply, {:error, :invalid_params}, state}
    end
  end

  def handle_call({:start_app, package}, _from, %{address: address} = state) do
    with [{^address, device}] <- :ets.lookup(__MODULE__, address) do
      cond do
        device.ping_failed ->
          {:reply, {:error, :device_ping_failed}, state}

        !Enum.member?(device.packages, package) ->
          {:reply, {:error, :invalid_package}, state}

        device.state != @using ->
          {:reply, {:error, :invalid_state}, state}

        true ->
          Task.async(fn ->
            send_request(address, device.ip, device.api_port, "app_start", [package])
          end)

          {:reply, :ok, state}
      end
    else
      _ ->
        {:reply, {:error, :invalid_params}, state}
    end
  end

  def handle_call({:idle, session}, _from, %{address: address} = state) do
    with [{^address, device}] <- :ets.lookup(__MODULE__, address),
         ^session <- device.session do
      if device.state != @idle do
        device = struct(device, session: nil, state: @idle)
        :ets.insert(__MODULE__, {address, device})
      end

      {:reply, :ok, state}
    else
      _ ->
        {:reply, {:error, :invalid_params}, state}
    end
  end

  def handle_call({:request, package}, _from, %{address: address} = state) do
    with [{^address, device}] <- :ets.lookup(__MODULE__, address),
         @idle <- device.state,
         true <- Enum.member?(device.packages, package),
         false <- device.ping_failed do
      session = Base.encode64(:crypto.strong_rand_bytes(96))
      device = struct(device, state: @using, session: session)
      :ets.insert(__MODULE__, {address, device})
      {:reply, {:ok, device}, state}
    else
      _ ->
        {:reply, {:error, :invalid_params}, state}
    end
  end

  def handle_cast({:add_paid, amount}, %{address: address} = state) do
    case :ets.lookup(__MODULE__, address) do
      [{^address, device}] ->
        device = struct(device, paid: device.paid + amount)
        :ets.insert(__MODULE__, {address, device})
        {:noreply, state}

      _ ->
        {:stop, :normal, state}
    end
  end

  def handle_cast({:install_notify, package, result}, %{address: address} = state) do
    case :ets.lookup(__MODULE__, address) do
      [{^address, device}] ->
        device =
          cond do
            device.state != @installing ->
              device

            result in [@app_download_failed, @app_install_failed] ->
              installing_packages = List.keydelete(device.installing_packages, package, 0)
              failed_packages = [package | device.failed_packages]

              struct(device,
                state: @idle,
                installing_packages: installing_packages,
                failed_packages: failed_packages
              )

            result == @app_install_success ->
              installing_packages = List.keydelete(device.installing_packages, package, 0)

              packages =
                unless Enum.member?(device.packages, package) do
                  [package | device.packages]
                else
                  device.packages
                end

              :ets.insert(DappDemo.DevicePackages, {package, address})

              struct(device,
                state: @idle,
                packages: packages,
                installing_packages: installing_packages
              )

            true ->
              device
          end

        :ets.insert(__MODULE__, {address, device})

        {:noreply, state}

      _ ->
        {:stop, :normal, state}
    end
  end

  def handle_cast(:release, state) do
    {:stop, :normal, state}
  end

  def handle_cast(:check_interval, %{address: address} = state) do
    case :ets.lookup(__MODULE__, address) do
      [{^address, device}] ->
        # check device working
        check_ping(device)

        # check install timeout
        if device.state == @installing do
          device = check_install_timeout(device)
          :ets.insert(__MODULE__, {address, device})
        end

        {:noreply, state}

      _ ->
        {:stop, :normal, state}
    end
  end

  def handle_info({_ref, :ping_success}, %{address: address} = state) do
    case :ets.lookup(__MODULE__, address) do
      [{^address, device}] ->
        if device.ping_failed do
          device = struct(device, ping_failed: false)
          :ets.insert(__MODULE__, {address, device})
        end

        {:noreply, state}

      _ ->
        {:stop, :normal, state}
    end
  end

  def handle_info({_ref, :ping_failed}, %{address: address, ping_failed: ping_failed} = state) do
    case :ets.lookup(__MODULE__, address) do
      [{^address, device}] ->
        now = DateTime.utc_now() |> DateTime.to_unix()
        Enum.drop_while(ping_failed, fn t -> t < now - 60 end)

        ping_failed = List.insert_at(ping_failed, length(ping_failed), now)

        if length(ping_failed) >= 10 do
          Logger.warn("device ping failed 10 times in 1 minute. #{address}")
          {:stop, :normal, state}
        else
          unless device.ping_failed do
            device = struct(device, ping_failed: true)
            :ets.insert(__MODULE__, {address, device})
          end

          {:noreply, Map.put(state, :ping_failed, ping_failed)}
        end

      _ ->
        {:stop, :normal, state}
    end
  end

  def handle_info({_ref, :ping_stop}, state) do
    {:stop, :normal, state}
  end

  def handle_info({_ref, {:install_request_result, result, package}}, %{address: address} = state) do
    case :ets.lookup(__MODULE__, address) do
      [{^address, device}] ->
        if result == :success do
          {:noreply, state}
        else
          installing_packages = List.keydelete(device.installing_packages, package, 0)

          device =
            struct(device,
              state: @idle,
              installing_packages: installing_packages
            )

          :ets.insert(__MODULE__, {address, device})

          {:noreply, state}
        end

      _ ->
        {:stop, :normal, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp check_ping(device) do
    Task.async(fn ->
      url = "http://#{device.ip}:#{device.api_port}"

      case JSONRPC2.Client.HTTP.call(url, "device_ping", []) do
        {:ok, _} ->
          :ping_success

        {:error, _} ->
          :ping_failed
      end
    end)
  end

  defp check_install_timeout(device) do
    now = DateTime.utc_now() |> DateTime.to_unix()

    {installing, failed} =
      Enum.reduce(
        device.installing_packages,
        {[], device.failed_packages},
        fn {installing_package, t}, {installing, failed} ->
          if now > t + @install_timeout do
            {installing, [installing_package | failed]}
          else
            {[{installing_package, t} | installing], failed}
          end
        end
      )

    struct(device,
      state: if(length(installing) == 0, do: @idle, else: @installing),
      installing_packages: installing,
      failed_packages: failed
    )
  end

  defp send_request(dev_addr, ip, port, method, params) do
    private_key = Account.private_key()
    address = Account.address()

    nonce = Nonce.get_and_update_nonce(address, dev_addr) |> Utils.encode_int()
    url = "http://#{ip}:#{port}"

    sign = Protocol.sign(method, params, nonce, dev_addr, private_key)

    case HTTP.call(url, method, params ++ [nonce, sign]) do
      {:ok, result} ->
        if Protocol.verify_resp_sign(result, address, dev_addr) do
          :ok
        else
          {:error, :verify_error}
        end

      {:error, err} ->
        {:error, err}
    end
  end
end
