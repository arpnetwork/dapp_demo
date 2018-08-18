defmodule DappDemo.Server do
  @moduledoc false

  use GenServer

  alias JSONRPC2.Client.HTTP
  alias DappDemo.Account
  alias DappDemo.API.Jsonrpc2.Protocol
  alias DappDemo.{Utils, Device, SendNonce}

  def device_request(server_address, price, ip, port) do
    method = "device_request"
    encode_price = price |> Utils.encode_int()
    sign_data = [encode_price, ip, port]

    [{^server_address, %{ip: ip, port: port}}] = lookup(server_address)

    case send_request(server_address, ip, port, method, sign_data) do
      {:ok, result} ->
        dev = %DappDemo.Device{
          server_address: server_address,
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

  def device_release(server_address, device_addr) do
    method = "device_release"
    sign_data = [device_addr]

    %{ip: ip, port: port} = lookup(server_address)

    case send_request(server_address, ip, port, method, sign_data) do
      {:ok, _result} ->
        Device.remove(device_addr)

      {:error, error} ->
        {:error, error}
    end
  end

  def insert(address, ip, port, cid) do
    :ets.insert(__MODULE__, {address, %{ip: ip, port: port, cid: cid, paid: 0}})
  end

  def delete(address) do
    :ets.delete(__MODULE__, address)
  end

  def lookup(address) do
    [{^address, data}] = :ets.lookup(__MODULE__, address)
    data
  end

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def pay(server_address, dev_address, amount) do
    GenServer.cast(__MODULE__, {:pay, server_address, dev_address, amount})
  end

  # Callbacks

  def init(_opts) do
    :ets.new(__MODULE__, [:named_table, :public, read_concurrency: true])
    {:ok, %{}}
  end

  def handle_cast({:pay, server_address, dev_address, amount}, _from, state) do
    [{^server_address, server}] = lookup(server_address)
    new_paid = server.paid + amount
    promise = Account.promise(server.cid, server_address, new_paid)

    data = [Poison.encode!(promise), dev_address]

    case send_request(server_address, server.ip, server.port, "account_pay", data) do
      {:ok, _result} ->
        server = Map.put(server, :paid, new_paid)
        :ets.insert(__MODULE__, {server_address, server})

        Device.add_paid(dev_address, amount)

      err ->
        IO.inspect(err)
    end

    {:noreply, state}
  end

  defp send_request(server_address, ip, port, method, data) do
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
