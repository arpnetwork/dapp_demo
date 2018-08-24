defmodule DappDemo.API.Jsonrpc2.Client do
  use JSONRPC2.Server.Handler

  alias DappDemo.API.Jsonrpc2.Protocol
  alias DappDemo.{Account, DevicePool}

  def connected(session, nonce, sign) do
    private_key = Account.private_key()
    address = Account.address()

    with {:ok, dev_address} <- Protocol.verify(method(), [session], nonce, sign, address),
         {:ok, dev} <- DevicePool.lookup(dev_address),
         :ok <- DappDemo.Client.connected(dev.pid, session) do
      Protocol.response(%{}, nonce, dev_address, private_key)
    else
      err ->
        Protocol.response(err)
    end
  end

  def disconnected(session, nonce, sign) do
    private_key = Account.private_key()
    address = Account.address()

    with {:ok, dev_address} <- Protocol.verify(method(), [session], nonce, sign, address),
         {:ok, dev} <- DevicePool.lookup(dev_address),
         :ok <- DappDemo.Client.disconnected(dev.pid, session) do
      Protocol.response(%{}, nonce, dev_address, private_key)
    else
      err ->
        Protocol.response(err)
    end
  end
end
