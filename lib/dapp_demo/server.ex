defmodule DappDemo.Server do
  @moduledoc false

  require Logger

  alias JSONRPC2.Client.HTTP
  alias DappDemo.API.Jsonrpc2.Protocol
  alias DappDemo.{Account, Config, Contract, Device, SendNonce, Utils}

  use GenServer

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
            port: result["port"],
            price: price,
            api_port: result["port"] + 1
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
    method = "device_release"
    sign_data = [device_addr]

    server = get(pid)

    case send_request(server.address, server.ip, server.port, method, sign_data) do
      {:ok, _result} ->
        GenServer.call(pid, {:remove_device, device_addr})

      {:error, error} ->
        {:error, error}
    end
  end

  def get(pid) do
    GenServer.call(pid, :get)
  end

  def pay(pid, dev_address, amount) do
    GenServer.cast(pid, {:pay, dev_address, amount})
  end

  def unbind(pid) do
    GenServer.cast(pid, :unbind)
  end

  # Callbacks

  def init(opts) do
    address = opts[:address]
    amount = opts[:amount]

    bind(address, amount)

    Process.send_after(self(), :check_interval, @check_interval)
    {:ok, {%__MODULE__{}, %{}}}
  end

  def handle_call({:add_device, device}, _from, {server, devices} = state) do
    if Map.has_key?(devices, device.address) do
      {:reply, {:error, :duplicate_device}, state}
    else
      devices = Map.put(devices, device.address, true)

      case Device.insert(device) do
        :ok ->
          {:reply, {:ok, device}, {server, devices}}

        {:error, error} ->
          {:reply, {:error, error}, state}
      end
    end
  end

  def handle_call({:remove_device, device_addr}, _from, {server, devices} = state) do
    if Map.has_key?(devices, device_addr) do
      devices = Map.delete(devices, device_addr)
      Device.remove(device_addr)
      {:reply, :ok, {server, devices}}
    else
      {:reply, {:error, :no_device}, state}
    end
  end

  def handle_call(:get, _from, {server, _devices} = state) do
    {:reply, server, state}
  end

  def handle_cast({:pay, dev_address, amount}, {server, devices} = state) do
    new_paid = server.paid + amount
    promise = Account.promise(server.cid, server.address, new_paid)

    data = [Poison.encode!(promise), dev_address]

    with {:ok, _result} <-
           send_request(server.address, server.ip, server.port, "account_pay", data),
         :ok <- Device.add_paid(dev_address, amount) do
      server = Map.put(server, :paid, new_paid)
      write_file(server.address, server)
      {:noreply, {server, devices}}
    else
      err ->
        Logger.error(err)
        {:noreply, state}
    end
  end

  def handle_cast(:unbind, {server, devices} = state) do
    if server.state == @state_ok do
      unbind(self(), server, devices)
      server = struct(server, state: @state_first_unbind_start)
      {:noreply, {server, devices}}
    else
      {:noreply, state}
    end
  end

  def handle_info(:check_interval, {server, devices}) do
    # check server register expired
    now = DateTime.utc_now() |> DateTime.to_unix()
    %{expired: register_expired} = Contract.get_server_by_addr(server.address)

    %{expired: binding_expired} =
      Contract.get_bind_server_expired(Account.address(), server.address)

    allowance = Contract.bank_allowance(Account.address(), server.address)

    increase_approval_task = Map.get(server, :increase_approval_task, nil)

    server =
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

    Process.send_after(self(), :check_interval, @check_interval)
    {:noreply, {server, devices}}
  end

  def handle_info({_ref, {:bind_result, result, data}}, {server, devices}) do
    Logger.info("bound server #{data.address} #{result}")

    if :success == result do
      Config.add_server(data.address, data.amount)
      {:noreply, {data, devices}}
    else
      Config.remove_server(data.address)
      {:stop, :normal, {server, devices}}
    end
  end

  def handle_info({_ref, {:unbind_result, result}}, {server, devices}) do
    Logger.info("unbound server #{server.address} #{result}")

    if :success == result do
      case server.state do
        @state_first_unbind_start ->
          server = struct(server, state: @state_first_unbind_end)
          {:noreply, {server, devices}}

        @state_second_unbind_start ->
          server = struct(server, state: @state_second_unbind_end)
          {:stop, :normal, {server, devices}}
      end
    else
      case server.state do
        @state_first_unbind_start ->
          server = struct(server, state: @state_ok)
          {:noreply, {server, devices}}

        @state_second_unbind_start ->
          server = struct(server, state: @state_first_unbind_end)
          {:noreply, {server, devices}}
      end
    end
  end

  def handle_info({_ref, {:increase_approval_result, result}}, {server, devices}) do
    Logger.info("increase approval result #{server.address} #{result}")

    server = Map.delete(server, :increase_approval_task)
    {:noreply, {server, devices}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  def send_request(server_address, ip, port, method, data) do
    private_key = Account.private_key()
    address = Account.address()

    nonce = SendNonce.get_and_update_nonce(server_address) |> Utils.encode_int()
    url = "http://#{ip}:#{port}"

    sign = Protocol.sign(method, data, nonce, server_address, private_key)

    case HTTP.call(url, method, data ++ [nonce, sign]) do
      {:ok, result} ->
        if Protocol.verify_resp_sign(result, address, server_address) do
          {:ok, result}
        else
          {:error, :verify_error}
        end

      {:error, err} ->
        {:error, err}
    end
  end

  defp bind(address, amount) do
    Task.async(fn ->
      private_key = Account.private_key()
      self_address = Account.address()

      %{ip: ip, port: port} = Contract.get_server_by_addr(address)

      state =
        with true <- ip != "0.0.0.0",
             :ok <- check_and_bind_server(private_key, self_address, address),
             :ok <- check_and_deposit_to_bank(private_key, self_address, address, amount),
             :ok <- check_and_approve_to_bank(private_key, self_address, address, amount) do
          @state_ok
        else
          {:ok, state} ->
            state

          err ->
            Logger.error(err)
            nil
        end

      if state do
        %{cid: cid} = Contract.bank_allowance(address, self_address)

        file_data = read_file(address)

        paid =
          if file_data && file_data.cid == cid do
            file_data.paid
          else
            delete_file(address)
            0
          end

        data = %__MODULE__{
          address: address,
          ip: ip,
          port: port + 1,
          cid: cid,
          amount: amount,
          paid: paid,
          state: state
        }

        {:bind_result, :success, data}
      else
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
      balance = Contract.get_bank_balance(dapp_address)

      res =
        if balance < amount do
          with {:ok, %{"status" => "0x1"}} <-
                 Contract.token_approve(private_key, amount - balance),
               {:ok, %{"status" => "0x1"}} <-
                 Contract.deposit_to_bank(private_key, amount - balance) do
            :ok
          else
            _ ->
              :fail
          end
        else
          :ok
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
    %{server_addr: addr, expired: expired} =
      Contract.get_bind_server_expired(dapp_addr, server_addr)

    now = DateTime.utc_now() |> DateTime.to_unix()

    cond do
      addr != server_addr ->
        # new bind
        Logger.info("binding server #{server_addr}")

        case Contract.bind_server(private_key, server_addr) do
          {:ok, %{"status" => "0x1"}} ->
            :ok

          _ ->
            {:error, "bind server failed"}
        end

      expired != 0 && expired <= now ->
        # unbind
        Logger.info("expired. unbinding server #{server_addr}")

        case Contract.unbind_server(private_key, server_addr) do
          {:ok, %{"status" => "0x1"}} ->
            {:error, "unbind success #{server_addr}"}

          _ ->
            {:ok, @state_second_unbind_start}
        end

      expired != 0 && expired > now ->
        # need unbind
        Logger.info("expired. need unbind server #{server_addr}")
        {:ok, @state_first_unbind_end}

      true ->
        :ok
    end
  end

  defp check_and_deposit_to_bank(private_key, address, server_addr, amount) do
    balance = Contract.get_bank_balance(address)
    allowance = Contract.bank_allowance(address, server_addr)

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

  defp check_and_approve_to_bank(private_key, address, server_addr, amount) do
    allowance = Contract.bank_allowance(address, server_addr)

    if allowance.cid == 0 do
      Logger.info("bank approve...")

      with {:ok, %{"status" => "0x1"}} <- Contract.bank_approve(private_key, server_addr, amount) do
        :ok
      else
        _ ->
          {:error, "bank approve failed"}
      end
    else
      :ok
    end
  end

  defp write_file(address, data) do
    case Poison.encode(data) do
      {:ok, encoded_data} ->
        File.write(file_path(address), encoded_data)

      {:error, err} ->
        Logger.error("save file error, address = #{address}")
        Logger.error(err)
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
