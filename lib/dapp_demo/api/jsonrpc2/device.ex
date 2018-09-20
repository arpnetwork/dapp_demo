defmodule DappDemo.API.Jsonrpc2.Device do
  use JSONRPC2.Server.Handler

  alias DappDemo.API.Jsonrpc2.Protocol
  alias DappDemo.{Account, DevicePool}

  def offline(device_address, nonce, sign) do
    private_key = Account.private_key()
    address = Account.address()

    with {:ok, server_address} <-
           Protocol.verify(method(), [device_address], nonce, sign, address),
         {:ok, dev} <- DevicePool.lookup(device_address) do
      DappDemo.Device.release(dev.pid)
      Protocol.response(%{}, nonce, server_address, private_key)
    else
      err ->
        Protocol.response(err)
    end
  end
end
