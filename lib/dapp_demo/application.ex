defmodule DappDemo.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @jsonrpc_port Application.get_env(:dapp_demo, :port)
  @http_port @jsonrpc_port + 1

  def start(_type, _args) do
    DappDemo.Account.init()

    # List all child processes to be supervised
    children = [
      # Starts a worker by calling: DappDemo.Worker.start_link(arg)
      # {DappDemo.Worker, arg},
      DappDemo.Device,
      DappDemo.Server,
      DappDemo.API.Jsonrpc2.Nonce,
      DappDemo.SendNonce,
      Plug.Adapters.Cowboy2.child_spec(
        scheme: :http,
        plug:
          {JSONRPC2.Server.Plug,
           modules: [
             DappDemo.API.Jsonrpc2.Nonce,
             DappDemo.API.Jsonrpc2.App,
             DappDemo.API.Jsonrpc2.Client
           ]},
        options: [port: @jsonrpc_port]
      ),
      Plug.Adapters.Cowboy2.child_spec(
        scheme: :http,
        plug: DappDemo.API.Router,
        options: [
          port: @http_port
        ]
      )
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: DappDemo.Supervisor]
    {:ok, pid} = Supervisor.start_link(children, opts)

    # initialize
    case DappDemo.Init.init() do
      :ok ->
        {:ok, pid}

      :error ->
        {:error, :normal}
    end
  end
end
