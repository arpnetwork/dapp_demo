defmodule DappDemo.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @jsonrpc_port Application.get_env(:dapp_demo, :port)
  @http_port @jsonrpc_port + 1

  def start(_type, _args) do
    data_dir = Application.get_env(:dapp_demo, :data_dir)

    unless File.exists?(data_dir) do
      File.mkdir_p(data_dir)
    end

    DappDemo.Account.init()

    # List all child processes to be supervised
    children = [
      # Starts a worker by calling: DappDemo.Worker.start_link(arg)
      # {DappDemo.Worker, arg},
      {DynamicSupervisor, name: DappDemo.DSupervisor, strategy: :one_for_one},
      DappDemo.Config,
      DappDemo.Nonce,
      DappDemo.ServerRegistry,
      DappDemo.DevicePool,
      Plug.Adapters.Cowboy2.child_spec(
        scheme: :http,
        plug:
          {JSONRPC2.Server.Plug,
           modules: [
             DappDemo.API.Jsonrpc2.Nonce,
             DappDemo.API.Jsonrpc2.App,
             DappDemo.API.Jsonrpc2.Client,
             DappDemo.API.Jsonrpc2.Account,
             DappDemo.API.Jsonrpc2.Device
           ]},
        options: [port: @jsonrpc_port]
      ),
      Plug.Adapters.Cowboy2.child_spec(
        scheme: :http,
        plug: DappDemo.API.Router,
        options: [
          port: @http_port
        ]
      ),
      DappDemo.Admin
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: DappDemo.AppSupervisor]
    Supervisor.start_link(children, opts)
  end
end
