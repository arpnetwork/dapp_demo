defmodule DappDemo.API.Response do
  @moduledoc """
  Render response.
  """

  alias Plug.Conn

  @default_content_type "application/json"

  def render(conn, data) when is_map(data) do
    render(conn, Conn.Status.code(:ok), data)
  end

  @doc false
  def render(conn, status, data) do
    conn
    |> Conn.put_resp_content_type(@default_content_type)
    |> Conn.send_resp(status, data |> format_data() |> Poison.encode!())
  end

  defp format_data(data) when is_map(data) do
    for item <- data, into: %{} do
      format_data(item)
    end
  end

  defp format_data(data) when is_list(data) do
    for item <- data, into: [] do
      format_data(item)
    end
  end

  defp format_data({key, value}) do
    {first, rest} =
      if(is_atom(key), do: Atom.to_string(key), else: key)
      |> Macro.camelize()
      |> String.split_at(1)

    new_key = String.downcase(first) <> rest

    {new_key, format_data(value)}
  end

  defp format_data(data) do
    data
  end
end
