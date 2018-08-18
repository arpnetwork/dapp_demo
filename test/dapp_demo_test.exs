defmodule DappDemoTest do
  use ExUnit.Case
  doctest DappDemo

  test "greets the world" do
    assert DappDemo.hello() == :world
  end
end
