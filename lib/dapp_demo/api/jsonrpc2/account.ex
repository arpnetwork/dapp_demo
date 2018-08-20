defmodule DappDemo.API.Jsonrpc2.Account do
  use JSONRPC2.Server.Handler

  alias DappDemo.API.Jsonrpc2.Protocol
  alias DappDemo.Account
  alias DappDemo.Device
  alias DappDemo.Server
  alias DappDemo.ServerRegistry
  alias DappDemo.Utils

  def request_payment(amount, nonce, sign) do
    decoded_amount = Utils.decode_hex(amount)

    private_key = Account.private_key()
    address = Account.address()

    with {:ok, dev_address} <- Protocol.verify(method(), [amount], nonce, sign, address),
         dev when not is_nil(dev) <- Device.lookup(dev_address),
         {:ok, amount} <- Account.settle(dev.inserted_at, dev.price, dev.paid, decoded_amount),
         {:ok, server} <- ServerRegistry.lookup(dev.server_address),
         :ok <- Server.pay(server, dev_address, amount) do
      Protocol.response(%{}, nonce, dev_address, private_key)
    else
      err ->
        Protocol.response(err)
    end
  end
end
