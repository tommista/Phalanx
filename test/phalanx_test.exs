defmodule PhalanxTest do
  use ExUnit.Case
  doctest Phalanx

  test "greets the world" do
    assert Phalanx.hello() == :world
  end
end
