defmodule DappDemo.API.Jsonrpc2.Nonce do
  alias DappDemo.API.Jsonrpc2.Protocol
  alias DappDemo.{Account, Nonce, Utils}

  use JSONRPC2.Server.Handler

  def get(address) do
    self_addr = Account.address()
    nonce = Nonce.get(address, self_addr)

    Protocol.response(%{nonce: Utils.encode_int(nonce)})
  end
end
