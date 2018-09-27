# DappDemo

**Demo of Dapp. Request device from ARP server and do whatever you want.**

## Configuration

Edit `config/config.exs` like:

```elixir
  config :dapp_demo,
    data_dir: System.user_home() |> Path.join(".dapp_demo"),
    port: 33223,
    eth_node: "http://localhost:8545",
    amount: 5_000 * round(1.0e18),
    price: 50 * round(1.0e18),
    app_list: "public/data/app_list.json",
    ip: "192.168.0.164",
    keystore_file: "/path/to/keystore/file",
    min_idle_device: 20
```

## Run

to start application:

```bash
$ iex -S mix
```

and unlock your account to start server, this will take a while:

```bash
iex(1)> DappDemo.Admin.start("keystore_password")
```

if first run, you need add ARP server:

```bash
iex(2)> DappDemo.Admin.add_server("server_address")
```

## License

Dapp demo source code is released under Apache 2 License.

Check [LICENSE](LICENSE) file for more information.
