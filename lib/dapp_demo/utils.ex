defmodule DappDemo.Utils do
  @moduledoc """
  Util functions.
  """

  @doc """
  Decode hex string to integer

  ## Examples
      iex> DappDemo.Utils.decode_hex("0xa1b2")
      41394
      iex> DappDemo.Utils.decode_hex("a1b2")
      41394
      iex> DappDemo.Utils.decode_hex("1b2")
      434
      iex> DappDemo.Utils.decode_hex("0xA1b2")
      41394
  """
  @spec decode_hex(String.t()) :: integer()
  def decode_hex(string) do
    string = String.trim_leading(string, "0x")
    len = String.length(string)

    string
    |> String.pad_leading(len + Integer.mod(len, 2), "0")
    |> Base.decode16!(case: :mixed)
    |> :binary.decode_unsigned(:big)
  end

  @doc """
  Encode integer to hex string
  """
  def encode_int(int) do
    hex = int |> :binary.encode_unsigned(:big) |> Base.encode16(case: :lower)
    "0x" <> hex
  end
end
