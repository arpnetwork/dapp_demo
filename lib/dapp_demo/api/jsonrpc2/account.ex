defmodule DappDemo.API.Jsonrpc2.Account do
  use JSONRPC2.Server.Handler

  alias DappDemo.API.Jsonrpc2.Protocol
  alias DappDemo.Account
  alias DappDemo.Device
  alias DappDemo.Server

  def request_payment(amount, nonce, sign) do
    private_key = Account.private_key()
    address = Account.address()

    with {:ok, dev_address} <- Protocol.verify(method(), [amount], nonce, sign, address),
         dev when not is_nil(dev) <- Device.lookup(dev_address),
         {:ok, amount} <- Account.settle(dev.inserted_at, dev.price, dev.paid, amount),
         :ok <- Server.pay(dev.server_address, dev_address, amount) do
      Protocol.response(%{}, nonce, dev_address, private_key)
    else
      err ->
        Protocol.response(err)
    end
  end
end
