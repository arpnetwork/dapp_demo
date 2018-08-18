defmodule DappDemo.Init do
  @moduledoc """
  Initialize dapp
  """

  alias DappDemo.Contract

  require Logger

  def init() do
    all_env = Application.get_all_env(:dapp_demo)

    data_dir = all_env[:data_dir]

    unless File.exists?(data_dir) do
      :ok = File.mkdir(data_dir)
    end

    password = all_env[:password]
    keystore_file = all_env[:keystore_file]
    deposit = all_env[:deposit]
    configed_server_addr = all_env[:bind_server]

    bind_server_path = Path.join(data_dir, "bind_server")
    file_data = read_bind_server(bind_server_path)
    saved_server_addr = Enum.at(file_data, 0)

    server_addr = configed_server_addr || saved_server_addr

    with {:ok, %{private_key: private_key, address: address}} <-
           DappDemo.Account.set_key(keystore_file, password),
         :ok <- check_eth_balance(address),
         :ok <- check_arp_balance(address),
         :ok <- check_and_deposit_to_bank(private_key, address, deposit),
         :ok <- check_and_bind_server(private_key, address, server_addr),
         :ok <- check_and_approve_to_bank(private_key, address, server_addr, deposit) do
      # save to file, save server info
      save_bind_server_addr(bind_server_path, server_addr)

      server = Contract.get_server_by_addr(server_addr)

      %{cid: cid} = Contract.bank_allowance(address, server_addr)
      DappDemo.Server.insert(server_addr, server.ip, server.port, cid)

      Logger.info("binded server #{server_addr}, ip = #{server.ip}")

      :ok
    else
      {:error, msg} ->
        Logger.error(msg)
        :error
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

    if balance == 0 do
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

      expired <= DateTime.utc_now() |> DateTime.to_unix() ->
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
