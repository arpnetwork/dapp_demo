# This file is responsible for configuring your application
# and its dependencies with the aid of the Mix.Config module.
use Mix.Config

# This configuration is loaded before any dependency and is restricted
# to this project. If another project depends on this project, this
# file won't be loaded nor affect the parent project. For this reason,
# if you want to provide default values for your application for
# 3rd-party users, it should be done in your "mix.exs" file.

# You can configure your application as:
#
#     config :dapp_demo, key: :value
#
# and access this configuration in your application as:
#
#     Application.get_env(:dapp_demo, :key)
#
# You can also configure a 3rd-party app:
#
#     config :logger, level: :info
#

# It is also possible to import configuration files, relative to this
# directory. For example, you can emulate configuration per environment
# by uncommenting the line below and defining dev.exs, test.exs and such.
# Configuration from the imported file will override the ones defined
# here (which is why it is important to import them last).
#
#     import_config "#{Mix.env}.exs"

import_config "#{Mix.env()}.exs"

config :dapp_demo,
  data_dir: System.user_home() |> Path.join(".dapp_demo"),
  port: 8080,
  amount: 5000 * trunc(1.0e18),
  price: 100 * trunc(1.0e18),
  app_data_file: "public/data/app_list.json",
  app_data_file2: "public/data/app_packages.json",
  password: "123456789",
  ip: nil,
  keystore_file: nil,
  bind_server: nil
