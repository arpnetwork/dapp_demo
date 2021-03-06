defmodule DappDemo.Server do
  @moduledoc false

  require Logger

  alias JSONRPC2.Client.HTTP
  alias DappDemo.API.Jsonrpc2.Protocol
  alias DappDemo.{Account, Config, Contract, Device, Nonce, Utils}

  use GenServer, restart: :transient

  @data_path Application.get_env(:dapp_demo, :data_dir)

  @check_interval 3_600_000
  @allowance_threshold_value 0.8

  @state_init 0
  @state_ok 1
  @state_first_unbind_start 2
  @state_first_unbind_end 3
  @state_second_unbind_start 4
  @state_second_unbind_end 5

  defstruct [
    :address,
    :ip,
    :port,
    :cid,
    :increase_approval_task,
    amount: 0,
    paid: 0,
    state: @state_init
  ]

  def is_ok?(server) do
    server.state == @state_ok
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def device_request(pid, price, ip, port) do
    method = "device_request"
    encode_price = price |> Utils.encode_int()
    sign_data = [encode_price, ip, port]

    server = get(pid)

    if server.state == @state_ok do
      case send_request(server.address, server.ip, server.port, method, sign_data) do
        {:ok, result} ->
          dev = %DappDemo.Device{
            server_address: server.address,
            address: result["address"],
            ip: result["ip"],
            port: result["tcp_port"],
            price: price,
            width: result["width"] || 0,
            height: result["height"] || 0,
            inserted_at: DateTime.utc_now() |> DateTime.to_unix()
          }

          GenServer.call(pid, {:add_device, dev})

        {:error, error} ->
          {:error, error}
      end
    else
      {:error, "state error"}
    end
  end

  def device_release(pid, device_addr) do
    if Process.alive?(pid) do
      GenServer.call(pid, {:release_device, device_addr})
    else
      :error
    end
  end

  def get(pid) do
    if Process.alive?(pid) do
      GenServer.call(pid, :get)
    else
      nil
    end
  end

  def pay(pid, dev_address, amount) do
    if Process.alive?(pid) do
      GenServer.cast(pid, {:pay, dev_address, amount})
    else
      {:error, "internal error"}
    end
  end

  def unbind(pid) do
    if Process.alive?(pid) do
      GenServer.cast(pid, :unbind)
    end
  end

  # Callbacks

  def init(opts) do
    address = opts[:address]
    amount = opts[:amount]
    server_tab = opts[:server_tab]

    bind(address, amount)

    Process.send_after(self(), :check_interval, @check_interval)
    {:ok, {%__MODULE__{address: address, amount: amount}, %{}, %{}, server_tab}}
  end

  def terminate(_reason, {server, devices, _refs, server_tab}) do
    :ets.delete(server_tab, server.address)
    # remove all devices
    Enum.each(devices, fn {_, pid} ->
      Device.release(pid)
    end)
  end

  def handle_call({:add_device, device}, _from, {server, devices, refs, tab} = state) do
    if Map.has_key?(devices, device.address) do
      {:reply, {:error, :duplicate_device}, state}
    else
      case DynamicSupervisor.start_child(
             DappDemo.DSupervisor,
             {DappDemo.Device, [device: device]}
           ) do
        {:ok, pid} ->
          ref = Process.monitor(pid)

          devices = Map.put(devices, device.address, pid)
          refs = Map.put(refs, ref, device.address)

          {:reply, {:ok, device}, {server, devices, refs, tab}}

        err ->
          {:reply, err, state}
      end
    end
  end

  def handle_call({:release_device, device_addr}, _from, {server, devices, refs, tab} = state) do
    if Map.has_key?(devices, device_addr) do
      {pid, devices} = Map.pop(devices, device_addr)

      if pid do
        Device.release(pid)
      end

      {:reply, :ok, {server, devices, refs, tab}}
    else
      {:reply, {:error, :no_device}, state}
    end
  end

  def handle_call(:get, _from, {server, _devices, _refs, _} = state) do
    {:reply, server, state}
  end

  def handle_cast({:pay, dev_address, amount}, {server, devices, refs, tab}) do
    new_paid = server.paid + amount
    promise = Account.promise(server.cid, server.address, new_paid)
    data = [Poison.encode!(promise), Utils.encode_int(amount), dev_address]

    pid = Map.get(devices, dev_address, nil)
    Device.add_paid(pid, amount)
    server = struct(server, paid: new_paid)
    write_file(server.address, server)

    case send_request(server.address, server.ip, server.port, "account_pay", data) do
      {:ok, _result} ->
        nil

      {:error, err} ->
        Logger.error("send pay failed. #{inspect(err)}")
    end

    {:noreply, {server, devices, refs, tab}}
  end

  def handle_cast(:unbind, {server, devices, refs, tab} = state) do
    if server.state == @state_ok do
      unbind(self(), server, devices)
      server = struct(server, state: @state_first_unbind_start)
      {:noreply, {server, devices, refs, tab}}
    else
      {:noreply, state}
    end
  end

  def handle_info(:check_interval, {server, devices, refs, tab}) do
    # check server register expired
    now = DateTime.utc_now() |> DateTime.to_unix()

    server =
      with {:ok, %{expired: register_expired}} <- Contract.get_server_by_addr(server.address),
           {:ok, allowance} <- Contract.bank_allowance(Account.address(), server.address),
           {:ok, %{expired: binding_expired}} <-
             Contract.get_bind_server_expired(Account.address(), server.address) do
        increase_approval_task = Map.get(server, :increase_approval_task, nil)

        cond do
          server.state == @state_ok && register_expired > 0 && now < register_expired ->
            # server unregisted.
            # first unbind.
            Logger.info("server unregisted, first unbind server #{server.address}")
            unbind(self(), server, devices)
            struct(server, state: @state_first_unbind_start)

          server.state == @state_first_unbind_end && now > binding_expired ->
            # binding expired.
            # first unbind is done or server unbind.
            # second unbind.
            Logger.info("second unbind server #{server.address}")
            unbind(self(), server, devices)
            struct(server, state: @state_second_unbind_start)

          server.state == @state_ok &&
            allowance.paid / allowance.amount >= @allowance_threshold_value &&
              is_nil(increase_approval_task) ->
            # balance of allowance is too low.
            increase_amount = Config.get(:amount)
            Logger.info("increase approval #{server.address} #{increase_amount}")
            increase_approval(server.address, increase_amount)
            struct(server, increase_approval_task: true)

          true ->
            server
        end
      else
        _ -> server
      end

    Process.send_after(self(), :check_interval, @check_interval)
    {:noreply, {server, devices, refs, tab}}
  end

  def handle_info({_ref, {:bind_result, result, data}}, {server, devices, refs, tab}) do
    case result do
      :success ->
        Logger.info("bound server #{server.address} #{result}")

        Config.add_server(data.address, data.amount)
        write_file(data.address, data)
        {:noreply, {data, devices, refs, tab}}

      :fail ->
        Logger.info("bound server #{server.address} #{result}")
        Config.remove_server(server.address)
        {:stop, :normal, {server, devices, refs, tab}}

      :unbind_success ->
        Logger.info("unbound server #{server.address} #{result}")
        Config.remove_server(server.address)
        {:stop, :normal, {server, devices, refs, tab}}
    end
  end

  def handle_info({_ref, {:unbind_result, result}}, {server, devices, refs, tab}) do
    Logger.info("unbound server #{server.address} #{result}")

    if :success == result do
      case server.state do
        @state_first_unbind_start ->
          server = struct(server, state: @state_first_unbind_end)
          {:noreply, {server, devices, refs, tab}}

        @state_second_unbind_start ->
          server = struct(server, state: @state_second_unbind_end)
          {:stop, :normal, {server, devices, refs, tab}}
      end
    else
      case server.state do
        @state_first_unbind_start ->
          server = struct(server, state: @state_ok)
          {:noreply, {server, devices, refs, tab}}

        @state_second_unbind_start ->
          server = struct(server, state: @state_first_unbind_end)
          {:noreply, {server, devices, refs, tab}}
      end
    end
  end

  def handle_info({_ref, {:increase_approval_result, result}}, {server, devices, refs, tab}) do
    Logger.info("increase approval result #{server.address} #{result}")

    server = struct(server, increase_approval_task: nil)
    {:noreply, {server, devices, refs, tab}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, {server, devices, refs, tab}) do
    {address, refs} = Map.pop(refs, ref)
    devices = Map.delete(devices, address)

    if address do
      method = "device_release"
      sign_data = [address]
      send_request(server.address, server.ip, server.port, method, sign_data)
    end

    {:noreply, {server, devices, refs, tab}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  def get_nonce(ip, port) do
    case HTTP.call("http://#{ip}:#{port}", "nonce_get", [Account.address()]) do
      {:ok, result} ->
        Utils.decode_hex(result["nonce"])

      {:error, _} ->
        0
    end
  end

  def send_request(server_address, ip, port, method, data) do
    private_key = Account.private_key()
    address = Account.address()

    nonce = Nonce.get_and_update_nonce(address, server_address) |> Utils.encode_int()
    url = "http://#{ip}:#{port}"

    sign = Protocol.sign(method, data, nonce, server_address, private_key)

    case HTTP.call(url, method, data ++ [nonce, sign]) do
      {:ok, result} ->
        if Protocol.verify_resp_sign(result, address, server_address) do
          {:ok, result}
        else
          {:error, :verify_error}
        end

      {:error, %{"message" => "Nonce too low"}} ->
        nonce = get_nonce(ip, port) + 1
        Nonce.check_and_update_nonce(address, server_address, nonce)
        send_request(server_address, ip, port, method, data)

      err ->
        err
    end
  end

  defp bind(address, amount) do
    Task.async(fn ->
      private_key = Account.private_key()
      self_address = Account.address()

      with {:ok, state} <- check_and_bind_server(private_key, self_address, address),
           :ok <- check_and_deposit_to_bank(private_key, self_address, address, amount),
           :ok <- check_and_approve_to_bank(private_key, self_address, address, amount),
           {:ok, %{ip: ip, port: port}} <- Contract.get_server_by_addr(address),
           {:ok, %{cid: cid}} <- Contract.bank_allowance(self_address, address) do
        server_api_port = port + 1

        last_promise =
          get_last_promise(private_key, self_address, ip, server_api_port, address, cid)

        server_paid =
          if last_promise && Utils.decode_hex(last_promise.cid) == cid do
            Utils.decode_hex(last_promise.amount)
          else
            0
          end

        file_data = read_file(address)

        local_paid =
          if file_data && file_data.cid == cid do
            file_data.paid
          else
            delete_file(address)
            0
          end

        data = %__MODULE__{
          address: address,
          ip: ip,
          port: server_api_port,
          cid: cid,
          amount: amount,
          paid: max(server_paid, local_paid),
          state: state
        }

        {:bind_result, :success, data}
      else
        :unbind_success ->
          {:bind_result, :unbind_success, nil}

        err ->
          Logger.warn(inspect(err))
          {:bind_result, :fail, nil}
      end
    end)
  end

  defp unbind(pid, server, devices) do
    Task.async(fn ->
      Enum.each(Map.keys(devices), fn addr ->
        device_release(pid, addr)
      end)

      case Contract.unbind_server(Account.private_key(), server.address) do
        {:ok, %{"status" => "0x1"}} ->
          {:unbind_result, :success}

        _ ->
          {:unbind_result, :fail}
      end
    end)
  end

  defp increase_approval(server_address, amount) do
    Task.async(fn ->
      dapp_address = Account.address()
      private_key = Account.private_key()

      res =
        with {:ok, balance} when balance < amount <- Contract.get_bank_balance(dapp_address),
             {:ok, %{"status" => "0x1"}} <- Contract.token_approve(private_key, amount - balance),
             {:ok, %{"status" => "0x1"}} <-
               Contract.deposit_to_bank(private_key, amount - balance) do
          :ok
        else
          {:ok, balance} when balance >= amount ->
            :ok

          _ ->
            :error
        end

      with :ok <- res,
           {:ok, %{"status" => "0x1"}} <-
             Contract.bank_increase_approval(private_key, server_address, amount) do
        {:increase_approval_result, :success}
      else
        _ ->
          {:increase_approval_result, :fail}
      end
    end)
  end

  defp check_and_bind_server(private_key, dapp_addr, server_addr) do
    with {:ok, %{server_addr: addr, expired: expired}} <-
           Contract.get_bind_server_expired(dapp_addr, server_addr) do
      now = DateTime.utc_now() |> DateTime.to_unix()

      cond do
        addr != server_addr ->
          # new bind
          Logger.info("binding server #{server_addr}")

          case Contract.bind_server(private_key, server_addr) do
            {:ok, %{"status" => "0x1"}} ->
              {:ok, @state_ok}

            _ ->
              {:error, "bind server failed"}
          end

        expired != 0 && expired <= now ->
          # unbind
          Logger.info("expired. unbinding server #{server_addr}")

          case Contract.unbind_server(private_key, server_addr) do
            {:ok, %{"status" => "0x1"}} ->
              :unbind_success

            _ ->
              {:ok, @state_second_unbind_start}
          end

        expired != 0 && expired > now ->
          # need unbind
          Logger.info("expired. need unbind server #{server_addr}")
          {:ok, @state_first_unbind_end}

        true ->
          {:ok, @state_ok}
      end
    end
  end

  defp check_and_deposit_to_bank(private_key, address, server_addr, amount) do
    with {:ok, balance} <- Contract.get_bank_balance(address),
         {:ok, allowance} <- Contract.bank_allowance(address, server_addr) do
      if allowance.cid == 0 && balance < amount do
        Logger.info("depositing...")

        with {:ok, %{"status" => "0x1"}} <- Contract.token_approve(private_key, amount),
             {:ok, %{"status" => "0x1"}} <- Contract.deposit_to_bank(private_key, amount) do
          :ok
        else
          _ ->
            {:error, "deposit failed"}
        end
      else
        :ok
      end
    end
  end

  defp check_and_approve_to_bank(private_key, address, server_addr, amount) do
    with {:ok, allowance} <- Contract.bank_allowance(address, server_addr) do
      if allowance.cid == 0 do
        Logger.info("bank approve...")

        case Contract.bank_approve(private_key, server_addr, amount) do
          {:ok, %{"status" => "0x1"}} ->
            :ok

          _ ->
            {:error, "bank approve failed"}
        end
      else
        :ok
      end
    end
  end

  defp get_last_promise(private_key, address, ip, port, server_address, cid) do
    method = "account_last"
    url = "http://#{ip}:#{port}"
    data = [Utils.encode_int(cid)]

    sign = Protocol.sign(method, data, server_address, private_key)

    with {:ok, result} <- HTTP.call(url, method, data ++ [sign]),
         true <- Protocol.verify_resp_sign(result, address, server_address),
         {:ok, promise} <- Poison.decode(result["promise"], keys: :atoms!),
         :ok <- Account.verify_promise(promise) do
      promise
    else
      _ ->
        nil
    end
  end

  defp write_file(address, data) do
    case Poison.encode(data) do
      {:ok, encoded_data} ->
        File.write(file_path(address), encoded_data)

      {:error, err} ->
        Logger.error("save file error, address = #{address}")
        Logger.error(inspect(err))
    end
  end

  defp read_file(address) do
    with {:ok, file_data} <- File.read(file_path(address)),
         {:ok, data} <- Poison.decode(file_data, keys: :atoms!) do
      data
    else
      _ ->
        nil
    end
  end

  defp delete_file(address) do
    File.rm(file_path(address))
  end

  defp file_path(address) do
    Path.join(@data_path, "server_#{address}")
  end
end
