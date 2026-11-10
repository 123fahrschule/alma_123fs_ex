defmodule Alma123FS.Decode do
  @moduledoc false
  # Strict-but-tolerant field readers: missing fields become nil, wrong types abort the parse.

  @spec run((-> value)) :: {:ok, value} | :error when value: term()
  def run(fun) do
    {:ok, fun.()}
  catch
    {__MODULE__, :invalid} -> :error
  end

  @spec invalid() :: no_return()
  def invalid, do: throw({__MODULE__, :invalid})

  @spec required_string(map(), String.t()) :: String.t()
  def required_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> value
      _ -> invalid()
    end
  end

  @spec string(map(), String.t()) :: String.t() | nil
  def string(map, key), do: typed(map, key, &is_binary/1)

  @spec integer(map(), String.t()) :: integer() | nil
  def integer(map, key), do: typed(map, key, &is_integer/1)

  @spec boolean(map(), String.t()) :: boolean() | nil
  def boolean(map, key), do: typed(map, key, &is_boolean/1)

  @spec map(map(), String.t()) :: map() | nil
  def map(map, key), do: typed(map, key, &is_map/1)

  @spec timestamp(map(), String.t()) :: DateTime.t() | nil
  def timestamp(map, key) do
    case integer(map, key) do
      nil ->
        nil

      seconds ->
        case DateTime.from_unix(seconds) do
          {:ok, datetime} -> datetime
          {:error, _} -> invalid()
        end
    end
  end

  @spec enum(map(), String.t(), %{String.t() => atom()}) :: atom() | nil
  def enum(map, key, mapping) do
    case Map.get(map, key) do
      nil -> nil
      value when is_binary(value) -> Map.get(mapping, value, :unknown)
      _ -> :unknown
    end
  end

  @spec list(map(), String.t(), (map() -> value)) :: [value] when value: term()
  def list(map, key, item_fun) do
    case Map.get(map, key) do
      nil -> []
      items when is_list(items) -> Enum.map(items, &item(&1, item_fun))
      _ -> invalid()
    end
  end

  defp item(value, item_fun) when is_map(value), do: item_fun.(value)
  defp item(_, _), do: invalid()

  defp typed(map, key, guard) do
    case Map.get(map, key) do
      nil -> nil
      value -> if guard.(value), do: value, else: invalid()
    end
  end
end
