defmodule DappDemo.Client do
  @moduledoc false

  alias DappDemo.Device

  def connected(pid, session) do
    Device.verify(pid, session)
  end

  def disconnected(pid, session) do
    Device.idle(pid, session)
  end
end
