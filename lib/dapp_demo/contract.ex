defmodule DappDemo.Contract do
  @moduledoc """
  Define the api with the contract.
  """

  @chain_id Application.get_env(:dapp_demo, :chain_id)
  @token_contract Application.get_env(:dapp_demo, :token_contract_address)
  @registry_contract Application.get_env(:dapp_demo, :registry_contract_address)
  @bank_contract Application.get_env(:dapp_demo, :bank_contract_address)
  @first_registry_block Application.get_env(:dapp_demo, :first_registry_block)

  @default_gas_price 41_000_000_000
  @default_gas_limit 300_000

  @receipt_block_time 15_000
  @receipt_attempts 40

  alias DappDemo.Crypto

  def one_ether() do
    trunc(1.0e18)
  end

  @doc """
  Get the eth balance by calling the rpc api of the block chain node.
  """
  @spec get_eth_balance(String.t()) :: {:ok, integer()} | {:error, any()}
  def get_eth_balance(address) do
    with {:ok, res} <- Ethereumex.HttpClient.eth_get_balance(address) do
      {:ok, hex_string_to_integer(res)}
    end
  end

  @doc """
  Get the arp balance by calling the constract api.
  """
  @spec get_arp_balance(String.t()) :: {:ok, integer()} | {:error, any()}
  def get_arp_balance(address) do
    address = address |> String.slice(2..-1) |> Base.decode16!(case: :mixed)
    abi_encoded_data = ABI.encode("balanceOf(address)", [address]) |> Base.encode16(case: :lower)

    params = %{
      data: "0x" <> abi_encoded_data,
      to: @token_contract
    }

    with {:ok, res} <- Ethereumex.HttpClient.eth_call(params) do
      {:ok, hex_string_to_integer(res)}
    end
  end

  @doc """
  Get allowance.
  """
  @spec token_allowance(String.t()) :: {:ok, integer()} | {:error, any()}
  def token_allowance(owner) do
    owner = owner |> String.slice(2..-1) |> Base.decode16!(case: :mixed)
    spender = @bank_contract |> String.slice(2..-1) |> Base.decode16!(case: :mixed)

    abi_encoded_data =
      ABI.encode("allowance(address,address)", [owner, spender]) |> Base.encode16(case: :lower)

    params = %{
      data: "0x" <> abi_encoded_data,
      to: @token_contract
    }

    with {:ok, res} <- Ethereumex.HttpClient.eth_call(params) do
      {:ok, hex_string_to_integer(res)}
    end
  end

  @doc """
  Approve to bank contract.
  """
  @spec token_approve(String.t(), integer(), integer(), integer()) ::
          {:ok, map()} | {:error, term()}
  def token_approve(
        private_key,
        value,
        gas_price \\ @default_gas_price,
        gas_limit \\ @default_gas_limit
      ) do
    address = @bank_contract |> String.slice(2..-1) |> Base.decode16!(case: :mixed)
    encoded_abi = ABI.encode("approve(address,uint256)", [address, value])

    send_transaction(@token_contract, encoded_abi, private_key, gas_price, gas_limit)
  end

  @spec deposit_to_bank(String.t(), integer(), integer(), integer()) ::
          {:ok, map()} | {:error, term()}
  def deposit_to_bank(
        private_key,
        value,
        gas_price \\ @default_gas_price,
        gas_limit \\ @default_gas_limit
      ) do
    encoded_abi = ABI.encode("deposit(uint256)", [value])

    send_transaction(@bank_contract, encoded_abi, private_key, gas_price, gas_limit)
  end

  @spec get_bank_balance(String.t()) :: {:ok, integer()} | {:error, any()}
  def get_bank_balance(owner) do
    owner = owner |> String.slice(2..-1) |> Base.decode16!(case: :mixed)
    abi_encoded_data = ABI.encode("balanceOf(address)", [owner]) |> Base.encode16(case: :lower)

    params = %{
      data: "0x" <> abi_encoded_data,
      to: @bank_contract
    }

    with {:ok, res} <- Ethereumex.HttpClient.eth_call(params) do
      {:ok, hex_string_to_integer(res)}
    end
  end

  def bank_approve(
        private_key,
        server_addr,
        value,
        expired \\ 0,
        proxy \\ @registry_contract,
        gas_price \\ @default_gas_price,
        gas_limit \\ @default_gas_limit
      ) do
    server_addr = server_addr |> String.slice(2..-1) |> Base.decode16!(case: :mixed)
    proxy = proxy |> String.slice(2..-1) |> Base.decode16!(case: :mixed)

    encoded_abi =
      ABI.encode("approve(address,uint256,uint256,address)", [server_addr, value, expired, proxy])

    send_transaction(@bank_contract, encoded_abi, private_key, gas_price, gas_limit)
  end

  def bank_increase_approval(
        private_key,
        server_addr,
        value,
        expired \\ 0,
        gas_price \\ @default_gas_price,
        gas_limit \\ @default_gas_limit
      ) do
    server_addr = server_addr |> String.slice(2..-1) |> Base.decode16!(case: :mixed)

    encoded_abi =
      ABI.encode("increaseApproval(address,uint256,uint256)", [server_addr, value, expired])

    send_transaction(@bank_contract, encoded_abi, private_key, gas_price, gas_limit)
  end

  @spec bank_allowance(String.t(), String.t()) :: {:ok, map()} | {:error, any()}
  def bank_allowance(owner, server_addr) do
    owner = owner |> String.slice(2..-1) |> Base.decode16!(case: :mixed)
    server_addr = server_addr |> String.slice(2..-1) |> Base.decode16!(case: :mixed)

    abi_encoded_data =
      ABI.encode("allowance(address,address)", [owner, server_addr])
      |> Base.encode16(case: :lower)

    params = %{
      data: "0x" <> abi_encoded_data,
      to: @bank_contract
    }

    with {:ok, res} <- Ethereumex.HttpClient.eth_call(params) do
      res = res |> String.slice(2..-1) |> Base.decode16!(case: :mixed)

      <<cid::size(256), amount::size(256), paid::size(256), expired::size(256),
        proxy::binary-size(32)>> = res

      {:ok,
       %{
         cid: cid,
         amount: amount,
         paid: paid,
         expired: expired,
         proxy: decode_abi_address(proxy)
       }}
    end
  end

  def bank_cash(
        private_key,
        from,
        amount,
        sign,
        gas_price \\ @default_gas_price,
        gas_limit \\ @default_gas_limit
      ) do
    from = from |> String.slice(2..-1) |> Base.decode16!(case: :mixed)
    <<r::binary-size(64), s::binary-size(64), v::binary-size(2)>> = sign

    encoded_abi =
      ABI.encode("cash(address,uint256,uint8,bytes32,bytes32)", [
        from,
        amount,
        v,
        r,
        s
      ])

    send_transaction(@bank_contract, encoded_abi, private_key, gas_price, gas_limit)
  end

  @spec get_server_count() :: {:ok, integer()} | {:error, any()}
  def get_server_count() do
    encoded_abi = ABI.encode("serverCount()", []) |> Base.encode16(case: :lower)

    params = %{
      data: "0x" <> encoded_abi,
      to: @registry_contract
    }

    with {:ok, res} <- Ethereumex.HttpClient.eth_call(params) do
      <<count::size(256)>> = res |> String.slice(2..-1) |> Base.decode16!(case: :mixed)
      {:ok, count}
    end
  end

  @spec get_server_by_index(integer()) :: {:ok, integer()} | {:error, any()}
  def get_server_by_index(index) do
    encoded_abi = ABI.encode("serverByIndex(uint256)", [index]) |> Base.encode16(case: :lower)

    params = %{
      data: "0x" <> encoded_abi,
      to: @registry_contract
    }

    with {:ok, res} <- Ethereumex.HttpClient.eth_call(params) do
      res = res |> String.slice(2..-1) |> Base.decode16!(case: :mixed)

      <<addr::binary-size(32), ip::size(256), port::size(256), size::size(256),
        expired::size(256)>> = res

      {:ok,
       %{
         addr: decode_abi_address(addr),
         ip: integer_to_ip(ip),
         port: port,
         size: size,
         expired: expired
       }}
    end
  end

  @spec get_server_by_addr(String.t()) :: {:ok, map()} | {:error, any()}
  def get_server_by_addr(server_addr) do
    server_addr = server_addr |> String.slice(2..-1) |> Base.decode16!(case: :mixed)

    encoded_abi = ABI.encode("servers(address)", [server_addr]) |> Base.encode16(case: :lower)

    params = %{
      data: "0x" <> encoded_abi,
      to: @registry_contract
    }

    with {:ok, res} <- Ethereumex.HttpClient.eth_call(params) do
      res = res |> String.slice(2..-1) |> Base.decode16!(case: :mixed)

      <<ip::size(256), port::size(256), size::size(256), expired::size(256)>> = res

      {:ok,
       %{
         ip: integer_to_ip(ip),
         port: port,
         size: size,
         expired: expired
       }}
    end
  end

  def bind_server(
        private_key,
        server_addr,
        gas_price \\ @default_gas_price,
        gas_limit \\ @default_gas_limit
      ) do
    server_addr = server_addr |> String.slice(2..-1) |> Base.decode16!(case: :mixed)
    encoded_abi = ABI.encode("bindApp(address)", [server_addr])

    send_transaction(@registry_contract, encoded_abi, private_key, gas_price, gas_limit)
  end

  def unbind_server(
        private_key,
        server_addr,
        gas_price \\ @default_gas_price,
        gas_limit \\ @default_gas_limit
      ) do
    server_addr = server_addr |> String.slice(2..-1) |> Base.decode16!(case: :mixed)
    encoded_abi = ABI.encode("unbindApp(address)", [server_addr])

    send_transaction(@registry_contract, encoded_abi, private_key, gas_price, gas_limit)
  end

  @spec get_bind_server_expired(String.t(), String.t()) :: {:ok, map()} | {:error, any()}
  def get_bind_server_expired(dapp_addr, server_addr) do
    dapp_addr = dapp_addr |> String.slice(2..-1) |> Base.decode16!(case: :mixed)
    server_addr = server_addr |> String.slice(2..-1) |> Base.decode16!(case: :mixed)

    data = Crypto.keccak256(dapp_addr <> server_addr)

    encoded_abi =
      ABI.encode("bindings(bytes32)", [data])
      |> Base.encode16(case: :lower)

    params = %{
      data: "0x" <> encoded_abi,
      to: @registry_contract
    }

    with {:ok, res} <- Ethereumex.HttpClient.eth_call(params) do
      res = res |> String.slice(2..-1) |> Base.decode16!(case: :mixed)

      <<server_addr::binary-size(32), expired::size(256)>> = res

      {:ok,
       %{
         server_addr: decode_abi_address(server_addr),
         expired: expired
       }}
    end
  end

  @doc """
  Transfer arp to some one.
  """
  def transfer_arp(
        private_key,
        to,
        value,
        gas_price \\ @default_gas_price,
        gas_limit \\ @default_gas_limit
      ) do
    to = to |> String.slice(2..-1) |> Base.decode16!(case: :mixed)
    encoded_abi = ABI.encode("transfer(address,uint)", [to, value])

    send_transaction(@token_contract, encoded_abi, private_key, gas_price, gas_limit)
  end

  def get_bound_servers(address) do
    bind_topic =
      "0x" <> Base.encode16(Crypto.keccak256("AppBound(address,address)"), case: :lower)

    unbind_topic =
      "0x" <> Base.encode16(Crypto.keccak256("AppUnbound(address,address)"), case: :lower)

    encoded_address = String.replace_prefix(address, "0x", "0x000000000000000000000000")

    params = %{
      fromBlock: @first_registry_block,
      toBlock: "latest",
      address: @registry_contract,
      topics: [[bind_topic, unbind_topic], encoded_address]
    }

    with {:ok, id} <- Ethereumex.HttpClient.eth_new_filter(params),
         {:ok, logs} <- Ethereumex.HttpClient.eth_get_filter_logs(id),
         {:ok, _} <- Ethereumex.HttpClient.eth_uninstall_filter(id) do
      out =
        Enum.reduce(logs, [], fn item, acc ->
          if item["removed"] == false do
            [topic, _, server] = item["topics"]
            server = String.replace_prefix(server, "0x000000000000000000000000", "0x")

            if topic == bind_topic do
              [server | acc]
            else
              List.delete(acc, server)
            end
          else
            acc
          end
        end)

      {:ok, out}
    end
  end

  @doc """
  Send transaction to a contract.
  """
  @spec send_transaction(String.t(), String.t(), String.t(), integer(), integer()) ::
          {:ok, map()} | {:error, any()}
  def send_transaction(contract, encoded_abi, private_key, gas_price, gas_limit) do
    from = Crypto.eth_privkey_to_pubkey(private_key) |> Crypto.get_eth_addr()
    private_key = Base.decode16!(private_key, case: :mixed)
    contract = contract |> String.slice(2..-1) |> Base.decode16!(case: :mixed)

    with {:ok, nonce} <- get_transaction_count(from) do
      bt = %Blockchain.Transaction{
        nonce: nonce,
        gas_price: gas_price,
        gas_limit: gas_limit,
        to: contract,
        value: 0,
        v: 0,
        r: 0,
        s: 0,
        init: <<>>,
        data: encoded_abi
      }

      transaction_data =
        bt
        |> Blockchain.Transaction.Signature.sign_transaction(private_key, @chain_id)
        |> Blockchain.Transaction.serialize()
        |> ExRLP.encode()
        |> Base.encode16(case: :lower)

      res = Ethereumex.HttpClient.eth_send_raw_transaction("0x" <> transaction_data)

      case res do
        {:ok, tx_hash} ->
          get_transaction_receipt(tx_hash, @receipt_attempts)

        _ ->
          res
      end
    end
  end

  @doc """
  Get pending transaction count.
  """
  @spec get_transaction_count(String.t()) :: {:ok, integer()} | {:error, any()}
  def get_transaction_count(address) do
    with {:ok, res} <- Ethereumex.HttpClient.eth_get_transaction_count(address, "pending") do
      {:ok, hex_string_to_integer(res)}
    end
  end

  @doc """
  Get transaction receipt.
  """
  @spec get_transaction_receipt(String.t(), integer(), term()) :: {:ok, map()}
  def get_transaction_receipt(tx_hash, attempts, res \\ {:ok, nil})

  def get_transaction_receipt(_tx_hash, 0, _) do
    {:error, :timeout}
  end

  def get_transaction_receipt(_tx_hash, _attempts, {:error, reason}) do
    {:error, reason}
  end

  def get_transaction_receipt(_tx_hash, _attempts, {:ok, receipt}) when is_map(receipt) do
    {:ok, receipt}
  end

  def get_transaction_receipt(tx_hash, attempts, _) do
    Process.sleep(@receipt_block_time)
    res = Ethereumex.HttpClient.eth_get_transaction_receipt(tx_hash)
    get_transaction_receipt(tx_hash, attempts - 1, res)
  end

  @spec hex_string_to_integer(String.t()) :: integer()
  defp hex_string_to_integer(string) do
    string = String.trim_leading(string, "0x")
    len = String.length(string)

    string
    |> String.pad_leading(len + Integer.mod(len, 2), "0")
    |> Base.decode16!(case: :lower)
    |> :binary.decode_unsigned(:big)
  end

  def integer_to_ip(n) do
    "#{ipcalc(n, 3)}.#{ipcalc(n, 2)}.#{ipcalc(n, 1)}.#{ipcalc(n, 0)}"
  end

  def ipcalc(n, i), do: rem(trunc(n / :math.pow(256, i)), 256)

  def decode_abi_address(addr) do
    "0x" <> (addr |> binary_part(12, byte_size(addr) - 12) |> Base.encode16(case: :lower))
  end
end
