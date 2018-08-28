defmodule DappDemo.Admin do
  @moduledoc """
  Admin.
  """

  require Logger

  alias DappDemo.Account
  alias DappDemo.Contract
  alias DappDemo.Config
  alias DappDemo.Crypto
  alias DappDemo.ServerRegistry

  def load_default() do
    config = Application.get_all_env(:dapp_demo)
    Config.set(:amount, config[:amount])
    Config.set(:price, config[:price])

    keystore = read_keystore(config[:keystore_file]) || Config.get_keystore()

    with {:ok, %{address: address}} <- Account.set_key(keystore, config[:password]),
         :ok <- check_eth_balance(address),
         :ok <- check_arp_balance(address) do
      servers = Config.get_servers()

      if config[:bind_server] do
        ServerRegistry.create(config[:bind_server], Config.get(:amount))
      end

      if Map.size(servers) > 0 do
        Enum.each(servers, fn {address, amount} ->
          ServerRegistry.create(address, amount)
        end)
      else
        amount = Config.get(:amount)
        servers = Contract.get_bound_servers(Account.address())

        Enum.each(servers, fn address ->
          ServerRegistry.create(address, amount)
        end)
      end

      :ok
    else
      error ->
        error
    end
  end

  def verify_password(password) do
    keystore = Config.get_keystore()

    with {:ok, private_key} <- Crypto.decrypt_keystore(keystore, password) do
      if Account.private_key() == private_key do
        :ok
      else
        :error
      end
    else
      _ ->
        :error
    end
  end

  def import_private_key(private_key, password) do
    keystore = Crypto.encrypt_private_key(private_key, password)
    Config.set_keystore(keystore)
    Account.set_key(private_key)
  end

  defp check_eth_balance(address) do
    eth_balance = Contract.get_eth_balance(address)

    if eth_balance >= Contract.one_ether() do
      :ok
    else
      {:error, "eth balance is not enough!"}
    end
  end

  defp check_arp_balance(address) do
    arp_balance = Contract.get_arp_balance(address)

    if arp_balance >= 5000 * Contract.one_ether() do
      :ok
    else
      {:error, "arp balance is not enough!"}
    end
  end

  defp read_keystore(keystore_filepath) do
    with true <- is_binary(keystore_filepath),
         {:ok, file} <- File.read(keystore_filepath),
         {:ok, file_map} <- file |> String.downcase() |> Poison.decode(keys: :atoms) do
      file_map
    else
      _ ->
        nil
    end
  end
end
