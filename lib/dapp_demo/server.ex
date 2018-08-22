defmodule DappDemo.Server do
  @moduledoc false

  require Logger

  alias JSONRPC2.Client.HTTP
  alias DappDemo.API.Jsonrpc2.Protocol
  alias DappDemo.{Account, Config, Contract, Device, SendNonce, Utils}

  use GenServer

  @check_interval 3_600_000
  @allowance_threshold_value 0.8

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts[:data])
  end

  def device_request(server, price, ip, port) do
    method = "device_request"
    encode_price = price |> Utils.encode_int()
    sign_data = [encode_price, ip, port]

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

        GenServer.call(server.pid, {:add_device, dev})

      {:error, error} ->
        {:error, error}
    end
  end

  def device_release(server, device_addr) do
    method = "device_release"
    sign_data = [device_addr]

    case send_request(server.address, server.ip, server.port, method, sign_data) do
      {:ok, _result} ->
        GenServer.call(server.pid, {:remove_device, device_addr})

      {:error, error} ->
        {:error, error}
    end
  end

  def pay(server, dev_address, amount) do
    GenServer.cast(server.pid, {:pay, dev_address, amount})
  end

  # Callbacks

  def init(data) do
    # %{address: address, ip: ip, port: port, cid: cid} = data
    Process.send_after(self(), :check_interval, @check_interval)
    {:ok, {Map.put(data, :paid, 0), %{}}}
  end

  def add_device({:add_device, device}, _from, {server, devices} = state) do
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

  def remove_device({:remove_device, device_addr}, _from, {server, devices} = state) do
    if Map.has_key?(devices, device_addr) do
      devices = Map.delete(devices, device_addr)
      Device.remove(device_addr)
      {:reply, :ok, {server, devices}}
    else
      {:reply, {:error, :no_device}, state}
    end
  end

  def handle_cast({:pay, dev_address, amount}, {server, devices} = state) do
    new_paid = server.paid + amount
    promise = Account.promise(server.cid, server.address, new_paid)

    data = [Poison.encode!(promise), dev_address]

    with {:ok, _result} <-
           send_request(server.address, server.ip, server.port, "account_pay", data),
         :ok <- Device.add_paid(dev_address, amount) do
      server = Map.put(server, :paid, new_paid)
      {:noreply, {server, devices}}
    else
      err ->
        IO.inspect(err)
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

    unbind_task = Map.get(server, :unbind_task, nil)
    increase_approval_task = Map.get(server, :increase_approval_task, nil)

    server =
      cond do
        register_expired > 0 && now < register_expired && binding_expired == 0 &&
            is_nil(unbind_task) ->
          # server unregisted and binding_expired is forever
          # first unbind
          Logger.info("server unregisted, first unbind server #{server.address}")
          unbind(server, devices)
          Map.put(server, :unbind_task, :first_unbind_start)

        now > binding_expired && (is_nil(unbind_task) || :first_unbind_finished == unbind_task) ->
          # binding expired.
          # first unbind is done or server unbind.
          # second unbind.
          Logger.info("second unbind server #{server.address}")
          unbind(server, devices)
          Map.put(server, :unbind_task, :second_unbind_start)

        allowance.paid / allowance.amount >= @allowance_threshold_value &&
            is_nil(increase_approval_task) ->
          # balance of allowance is too low.
          increase_amount = Config.get(:amount)
          Logger.info("increase approval #{server.address} #{increase_amount}")
          increase_approval(server.address, increase_amount)
          Map.put(server, :increase_approval_task, true)

        true ->
          server
      end

    Process.send_after(self(), :check_interval, @check_interval)
    {:noreply, {server, devices}}
  end

  def handle_info({_ref, {:unbind_result, result}}, {server, devices}) do
    Logger.info("unbind server #{server.address} #{result}")

    if :success == result do
      unbind_task = Map.get(server, :unbind_task, nil)

      if :second_unbind_start == unbind_task do
        {:stop, :normal, {server, devices}}
      else
        server = Map.put(server, :unbind_task, :first_unbind_finished)
        {:noreply, {server, devices}}
      end
    else
      server = Map.delete(server, :unbind_task)
      {:noreply, {server, devices}}
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

  defp unbind(server, devices) do
    Task.async(fn ->
      Enum.each(Map.keys(devices), fn addr ->
        device_release(server, addr)
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
end
