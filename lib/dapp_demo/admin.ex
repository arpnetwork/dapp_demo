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

  @keystore_path Application.get_env(:dapp_demo, :data_dir) |> Path.join("keystore")
  @servers_path Application.get_env(:dapp_demo, :data_dir) |> Path.join("bind_server")

  def load_default() do
    config = Application.get_all_env(:dapp_demo)
    Config.set(:amount, config[:amount])
    Config.set(:price, config[:price])
    Config.set(:keystore_file, config[:keystore_file])
    Config.set(:bind_server, config[:bind_server])

    file_data = read_bind_server(@servers_path)
    saved_server_addr = Enum.at(file_data, 0)

    server_addr = config[:bind_server] || saved_server_addr

    with {:ok, _} <- Account.set_key(config[:keystore_file], config[:password]),
         :ok <- bind_server(server_addr, config[:amount]) do
      :ok
    else
      error ->
        error
    end
  end

  def verify_password(password) do
    with {:ok, file} <- File.read(@keystore_path),
         {:ok, file_map} <- file |> String.downcase() |> Poison.decode(keys: :atoms),
         {:ok, private_key} <- Crypto.decrypt_keystore(file_map, password) do
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
    File.write!(@keystore_path, Poison.encode!(keystore))

    Account.set_key(private_key)
  end

  def bind_server(server_address, amount) do
    address = Account.address()
    private_key = Account.private_key()

    with :ok <- check_eth_balance(address),
         :ok <- check_arp_balance(address),
         :ok <- check_and_deposit_to_bank(private_key, address, amount),
         :ok <- check_and_bind_server(private_key, address, server_address),
         :ok <- check_and_approve_to_bank(private_key, address, server_address, amount) do
      # save to file, save server info
      save_bind_server_addr(@servers_path, server_address)

      server = Contract.get_server_by_addr(server_address)

      %{cid: cid} = Contract.bank_allowance(address, server_address)
      ServerRegistry.create(server_address, server.ip, server.port + 1, cid)

      Logger.info("binded server #{server_address}, ip = #{server.ip}")

      :ok
    else
      err ->
        err
    end
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

  defp check_and_deposit_to_bank(private_key, address, amount) do
    balance = Contract.get_bank_balance(address)

    if balance < amount do
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

  defp check_and_bind_server(private_key, dapp_addr, server_addr) do
    %{server_addr: addr, expired: expired} =
      Contract.get_bind_server_expired(dapp_addr, server_addr)

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

      expired != 0 && expired <= DateTime.utc_now() |> DateTime.to_unix() ->
        # unbind
        Logger.info("expired. unbinding server #{server_addr}")

        case Contract.unbind_server(private_key, server_addr) do
          {:ok, %{"status" => "0x1"}} ->
            :ok

          _ ->
            {:error, "unbind server failed"}
        end

        # rebind
        check_and_bind_server(private_key, dapp_addr, server_addr)

      true ->
        :ok
    end
  end

  defp save_bind_server_addr(file_path, server_addr) do
    file_data = read_bind_server(file_path)

    encode_data = [server_addr | file_data] |> Enum.uniq() |> Poison.encode!()
    File.write(file_path, encode_data)
  end

  defp read_bind_server(file_path) do
    case File.read(file_path) do
      {:ok, data} ->
        if data == "" do
          []
        else
          Poison.decode!(data)
        end

      {:error, _} ->
        []
    end
  end
end
