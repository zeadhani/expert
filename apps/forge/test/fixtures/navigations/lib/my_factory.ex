defmodule MyApp.Factory do
  def create(attrs) when is_map(attrs) do
    struct(__MODULE__, attrs)
  end

  def build(attrs) when is_map(attrs) do
    Map.merge(%{id: nil}, attrs)
  end

  def insert(attrs) when is_map(attrs) do
    attrs |> create() |> Map.put(:id, System.unique_integer([:positive]))
  end
end
