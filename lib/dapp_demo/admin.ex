defmodule DappDemo.Admin do
  @moduledoc """
  Admin.
  """

  require Logger

  alias DappDemo.Account
  alias DappDemo.Auto
  alias DappDemo.Contract
  alias DappDemo.Config
  alias DappDemo.Crypto
  alias DappDemo.ServerRegistry

  def start(auth) do
    bind_server = Config.get(:bind_server)
    amount = Config.get(:amount)
    Application.put_env(:ethereumex, :url, Config.get(:eth_node))

    keystore = read_keystore(Config.get(:keystore_file)) || Config.get_keystore()

    with {:ok, %{address: address}} <- Account.set_key(keystore, auth),
         :ok <- check_eth_balance(address),
         :ok <- check_arp_balance(address) do
      servers = Config.get_servers()

      if bind_server do
        ServerRegistry.create(bind_server, amount)
      end

      if Map.size(servers) > 0 do
        Enum.each(servers, fn {address, amount} ->
          ServerRegistry.create(address, amount)
        end)
      else
        servers = Contract.get_bound_servers(Account.address())

        Enum.each(servers, fn address ->
          ServerRegistry.create(address, amount)
        end)
      end

      Auto.start()

      :ok
    else
      error ->
        error
    end
  end

  def add_server(address, amount \\ nil) do
    ServerRegistry.create(address, amount || Config.get(:amount))
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
