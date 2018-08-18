defmodule DappDemo.Client do
  @moduledoc false

  alias DappDemo.Device

  def connected(address, session) do
    Device.verify(address, session)
  end

  def disconnected(address, session) do
    Device.idle(address, session)
  end
end
