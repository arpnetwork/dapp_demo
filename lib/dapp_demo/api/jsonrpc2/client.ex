defmodule DappDemo.API.Jsonrpc2.Client do
  use JSONRPC2.Server.Handler

  alias DappDemo.API.Jsonrpc2.Protocol
  alias DappDemo.Account

  def connected(session, nonce, sign) do
    private_key = Account.private_key()
    address = Account.address()

    with {:ok, dev_address} <- Protocol.verify(method(), [session], nonce, sign, address),
         :ok <- DappDemo.Client.connected(dev_address, session) do
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
         :ok <- DappDemo.Client.disconnected(dev_address, session) do
      Protocol.response(%{}, nonce, dev_address, private_key)
    else
      err ->
        Protocol.response(err)
    end
  end
end
