defmodule Engine.CodeIntelligence.HeexComponent do
  @moduledoc """
  Parses HEEX component syntax to extract component references.

  Handles:
  - Aliased components: `<Button.button>`
  - Imported components: `<.card>`
  """

  alias Forge.Document

  @doc """
  Extracts component information at the given position in a document.

  Returns `{:ok, {:aliased, alias_name, function_name}}` for `<Button.button>`,
  `{:ok, {:imported, function_name}}` for `<.card>`, or `{:error, :not_component}`
  if the cursor is not on a component.
  """
  @spec component_at(Document.t(), {pos_integer(), pos_integer()}) ::
          {:ok, {:aliased, String.t(), String.t()}}
          | {:ok, {:imported, String.t()}}
          | {:error, :not_component}
  def component_at(%Document{} = document, {line, column}) do
    with {:ok, text} <- Document.fetch_text_at(document, line),
         {:ok, component} <- extract_component(text, column) do
      {:ok, component}
    else
      _ -> {:error, :not_component}
    end
  end

  defp extract_component(text, column) do
    case find_component_at_position(text, column) do
      {:ok, component_text} -> parse_component(component_text)
      :error -> {:error, :not_component}
    end
  end

  defp find_component_at_position(text, column) do
    {before, after_cursor} = String.split_at(text, column - 1)

    with {:ok, tag_start} <- find_tag_start(before),
         {:ok, tag_end} <- find_tag_end(after_cursor) do
      tag_text = String.slice(before, tag_start..-1//1) <> tag_end
      {:ok, tag_text}
    else
      _ -> :error
    end
  end

  defp find_tag_start(text) do
    parts = String.split(text, "<")
    last_part = List.last(parts)

    case last_part do
      nil ->
        :error

      part ->
        if Regex.match?(~r/^[A-Z.]/, part) do
          {:ok, String.length(text) - String.length(part) - 1}
        else
          :error
        end
    end
  end

  defp find_tag_end(text) do
    case Regex.run(~r/^[^>\s]*/, text) do
      [match] -> {:ok, match}
      _ -> :error
    end
  end

  defp parse_component(tag_text) do
    component = tag_text |> String.trim_leading("<") |> String.split(~r/[\s>]/) |> hd()

    cond do
      String.starts_with?(component, ".") ->
        function_name = String.trim_leading(component, ".")
        {:ok, {:imported, function_name}}

      String.contains?(component, ".") ->
        parts = String.split(component, ".")

        case parts do
          [_single] ->
            {:error, :not_component}

          multi_part ->
            function_name = List.last(multi_part)
            alias_parts = Enum.slice(multi_part, 0..-2//1)
            alias_name = Enum.join(alias_parts, ".")
            {:ok, {:aliased, alias_name, function_name}}
        end

      true ->
        {:error, :not_component}
    end
  end
end
