defmodule DappDemo.API.Jsonrpc2.App do
  use JSONRPC2.Server.Handler

  alias DappDemo.API.Jsonrpc2.Protocol
  alias DappDemo.Account

  def notify_install(package, result, nonce, sign) do
    address = Account.address()

    with {:ok, dev_address} <- Protocol.verify(method(), [package, result], nonce, sign, address) do
      DappDemo.App.install_notify(dev_address, package, result)
    end
  end
end
