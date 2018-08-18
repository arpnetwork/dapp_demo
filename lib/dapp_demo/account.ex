defmodule DappDemo.Account do
  @moduledoc """
  Manage dapp account
  """

  alias DappDemo.Crypto

  require Logger

  def init() do
    :ets.new(__MODULE__, [:named_table, :public, read_concurrency: true])
  end

  def set_key(path, auth) do
    data_keystore = keystore_file_path()

    with {:ok, file} <- File.read(path || data_keystore),
         {:ok, file_map} <- file |> String.downcase() |> Poison.decode(keys: :atoms),
         {:ok, private_key} <- Crypto.decrypt_keystore(file_map, auth) do
      public_key = Crypto.eth_privkey_to_pubkey(private_key)
      address = Crypto.get_eth_addr(public_key)

      unless is_nil(path) do
        path |> Path.expand() |> File.cp(data_keystore)
      end

      Logger.info("use address #{address}")

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

  def private_key do
    [{:private_key, key}] = :ets.lookup_element(__MODULE__, :private_key, 2)
    key
  end

  def public_key do
    [{:public_key, key}] = :ets.lookup_element(__MODULE__, :public_key, 2)
    key
  end

  def address do
    [{:address, addr}] = :ets.lookup_element(__MODULE__, :address, 2)
    addr
  end

  def settle(start_time, price, paid, amount) do
    now = DateTime.utc_now() |> DateTime.to_unix()
    duration = now - start_time
    price_per_sec = price * 3600

    total_need_pay = price_per_sec * duration
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
      cid: cid,
      from: address,
      to: server_address,
      amount: amount,
      sign: Crypto.eth_sign(data, private_key)
    }
  end

  defp keystore_file_path() do
    data_dir = Application.get_env(:dapp_demo, :data_dir)
    Path.join(data_dir, "keystore")
  end
end
