defmodule DappDemo.Account do
  @moduledoc """
  Manage dapp account
  """

  alias DappDemo.Config
  alias DappDemo.Crypto
  alias DappDemo.Utils

  require Logger

  def init() do
    :ets.new(__MODULE__, [:named_table, :public, read_concurrency: true])
  end

  def set_key(keystore, auth) do
    with {:ok, private_key} <- Crypto.decrypt_keystore(keystore, auth) do
      public_key = Crypto.eth_privkey_to_pubkey(private_key)
      address = Crypto.get_eth_addr(public_key)
      Logger.info("use address #{address}")

      Config.set_keystore(keystore)

      :ets.insert(__MODULE__, [
        {:private_key, private_key},
        {:public_key, public_key},
        {:address, address}
      ])

      {:ok, %{private_key: private_key, public_key: public_key, address: address}}
    else
      _ ->
        {:error, "keystore file invalid or password error!"}
    end
  end

  def set_key(private_key) do
    public_key = Crypto.eth_privkey_to_pubkey(private_key)
    address = Crypto.get_eth_addr(public_key)

    :ets.insert(__MODULE__, [
      {:private_key, private_key},
      {:public_key, public_key},
      {:address, address}
    ])

    {:ok, %{private_key: private_key, public_key: public_key, address: address}}
  end

  def private_key do
    [{:private_key, key}] = :ets.lookup(__MODULE__, :private_key)
    key
  end

  def public_key do
    [{:public_key, key}] = :ets.lookup(__MODULE__, :public_key)
    key
  end

  def address do
    [{:address, addr}] = :ets.lookup(__MODULE__, :address)
    addr
  end

  def settle(start_time, price, paid, amount) do
    now = DateTime.utc_now() |> DateTime.to_unix()
    duration = now - start_time

    total_need_pay = div(price * duration, 3600)
    piece_need_pay = total_need_pay - paid

    if amount <= piece_need_pay do
      {:ok, amount}
    else
      {:error, "too much amount"}
    end
  end

  def promise(cid, server_address, amount) do
    private_key = private_key()
    address = address()
    decoded_addr = address |> String.slice(2..-1) |> Base.decode16!(case: :mixed)
    decoded_server_address = server_address |> String.slice(2..-1) |> Base.decode16!(case: :mixed)

    data =
      <<cid::size(256), decoded_addr::binary-size(20), decoded_server_address::binary-size(20),
        amount::size(256)>>

    %{
      cid: Utils.encode_int(cid),
      from: address,
      to: server_address,
      amount: Utils.encode_int(amount),
      sign: Crypto.eth_sign(data, private_key)
    }
  end

  def verify_promise(promise) do
    decoded_cid = Utils.decode_hex(promise[:cid])
    decoded_from = promise[:from] |> String.slice(2..-1) |> Base.decode16!(case: :mixed)
    decoded_to = promise[:to] |> String.slice(2..-1) |> Base.decode16!(case: :mixed)
    decoded_amount = Utils.decode_hex(promise[:amount])

    data =
      <<decoded_cid::size(256), decoded_from::binary-size(20), decoded_to::binary-size(20),
        decoded_amount::size(256)>>

    Crypto.eth_verify(data, promise[:sign], public_key())
  end
end
