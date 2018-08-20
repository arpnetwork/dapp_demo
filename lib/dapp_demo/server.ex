defmodule DappDemo.Server do
  @moduledoc false

  use GenServer

  alias JSONRPC2.Client.HTTP
  alias DappDemo.Account
  alias DappDemo.API.Jsonrpc2.Protocol
  alias DappDemo.{Utils, Device, SendNonce}

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

        case Device.insert(dev) do
          :ok ->
            {:ok, dev}

          {:error, error} ->
            {:error, error}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  def device_release(server, device_addr) do
    method = "device_release"
    sign_data = [device_addr]

    case send_request(server.address, server.ip, server.port, method, sign_data) do
      {:ok, _result} ->
        Device.remove(device_addr)

      {:error, error} ->
        {:error, error}
    end
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts[:data])
  end

  def pay(server, dev_address, amount) do
    GenServer.cast(server.pid, {:pay, dev_address, amount})
  end

  def info(server) do
    GenServer.call(server.pid, :info)
  end

  # Callbacks

  def init(data) do
    {:ok, Map.put(data, :paid, 0)}
  end

  def handle_cast({:pay, dev_address, amount}, server) do
    new_paid = server.paid + amount
    promise = Account.promise(server.cid, server.address, new_paid)

    data = [Poison.encode!(promise), dev_address]

    with {:ok, _result} <-
           send_request(server.address, server.ip, server.port, "account_pay", data),
         :ok <- Device.add_paid(dev_address, amount) do
      server = Map.put(server, :paid, new_paid)
      {:noreply, server}
    else
      err ->
        IO.inspect(err)
        {:noreply, server}
    end
  end

  def handle_call(:info, _from, server) do
    {:reply, server, server}
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
end
