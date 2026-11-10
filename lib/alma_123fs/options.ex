defmodule Alma123FS.Options do
  @moduledoc false
  # Keyword.validate!/2 without echoing values: messages may otherwise carry API keys or customer data.

  @spec validate!(term(), [atom() | {atom(), term()}]) :: keyword()
  def validate!(options, allowed) do
    unless Keyword.keyword?(options), do: raise(ArgumentError, "options must be a keyword list")

    names =
      Enum.map(allowed, fn
        {name, _default} -> name
        name -> name
      end)

    keys = Keyword.keys(options)

    case keys -- names do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown options #{inspect(Enum.uniq(unknown))}"
    end

    case keys -- Enum.uniq(keys) do
      [] -> :ok
      duplicate -> raise ArgumentError, "duplicate options #{inspect(Enum.uniq(duplicate))}"
    end

    defaults = for {name, default} <- allowed, do: {name, default}
    Keyword.merge(defaults, options)
  end
end
