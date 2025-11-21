defmodule Engine.CodeIntelligence.Definition do
  alias ElixirSense.Providers.Location, as: ElixirSenseLocation
  alias Engine.CodeIntelligence.Entity
  alias Engine.Search.Store
  alias Forge.Ast
  alias Forge.Ast.Analysis
  alias Forge.Document
  alias Forge.Document.Location
  alias Forge.Document.Position
  alias Forge.Formats
  alias Forge.Search.Indexer.Entry
  alias Forge.Text
  alias Future.Code

  require Logger

  @doc """
  Finds the definition location for the entity at the given position.

  This function searches for definitions in the following order:
  1. Project code and dependencies via the search index
  2. Elixir/OTP library source files
  3. ElixirSense as a fallback for other cases

  Returns `{:ok, location}` for a single match, `{:ok, [locations]}` for multiple matches,
  `{:ok, nil}` when no definition is found, or `{:error, reason}` if an error occurs.
  """
  @spec definition(Document.t(), Position.t()) ::
          {:ok, Location.t()} | {:ok, [Location.t()]} | {:ok, nil} | {:error, String.t()}
  def definition(%Document{} = document, %Position{} = position) do
    with {:ok, _, analysis} <- Document.Store.fetch(document.uri, :analysis),
         {:ok, entity, _range} <- Entity.resolve(analysis, position) do
      fetch_definition(entity, analysis, position)
    end
  end

  defp fetch_definition({type, entity} = resolved, %Analysis{} = analysis, %Position{} = position)
       when type in [:struct, :module] do
    module = Formats.module(entity)

    locations =
      case Store.exact(module, type: type, subtype: :definition) do
        {:ok, entries} ->
          for entry <- entries,
              result = to_location(entry),
              match?({:ok, _}, result) do
            {:ok, location} = result
            location
          end

        _ ->
          []
      end

    maybe_fallback_to_elixir_sense(resolved, locations, analysis, position)
  end

  defp fetch_definition(
         {:call, module, function, arity} = resolved,
         %Analysis{} = analysis,
         %Position{} = position
       ) do
    mfa = Formats.mfa(module, function, arity)

    definitions =
      mfa
      |> query_search_index(subtype: :definition)
      |> Stream.flat_map(fn entry ->
        case entry do
          %Entry{type: {:function, :delegate}} ->
            mfa = get_in(entry, [:metadata, :original_mfa])
            query_search_index(mfa, subtype: :definition) ++ [entry]

          _ ->
            [entry]
        end
      end)
      |> Stream.uniq_by(& &1.subject)

    locations =
      for entry <- definitions,
          result = to_location(entry),
          match?({:ok, _}, result) do
        {:ok, location} = result
        location
      end

    case locations do
      [] ->
        case find_elixir_library_definition(module, function, arity) do
          {:ok, location} -> {:ok, location}
          :error -> maybe_fallback_to_elixir_sense(resolved, locations, analysis, position)
        end

      _ ->
        maybe_fallback_to_elixir_sense(resolved, locations, analysis, position)
    end
  end

  defp fetch_definition(_, %Analysis{} = analysis, %Position{} = position) do
    elixir_sense_definition(analysis, position)
  end

  defp maybe_fallback_to_elixir_sense(
         {:call, module, function, arity} = resolved,
         locations,
         analysis,
         position
       ) do
    case locations do
      [] ->
        Logger.info("No definition found for #{inspect(resolved)} with Indexer.")

        case find_elixir_library_definition(module, function, arity) do
          {:ok, location} -> {:ok, location}
          :error -> elixir_sense_definition(analysis, position)
        end

      [location] ->
        {:ok, location}

      _ ->
        {:ok, locations}
    end
  end

  defp maybe_fallback_to_elixir_sense(resolved, locations, analysis, position) do
    case locations do
      [] ->
        Logger.info("No definition found for #{inspect(resolved)} with Indexer.")

        elixir_sense_definition(analysis, position)

      [location] ->
        {:ok, location}

      _ ->
        {:ok, locations}
    end
  end

  defp elixir_sense_definition(%Analysis{} = analysis, %Position{} = position) do
    analysis.document
    |> Document.to_string()
    |> ElixirSense.definition(position.line, position.character)
    |> parse_location(analysis.document)
  end

  defp parse_location(%ElixirSenseLocation{} = location, document) do
    %{file: file, line: line, column: column, type: type} = location
    file_path = file || document.path
    uri = Document.Path.ensure_uri(file_path)

    with {:ok, document} <- Document.Store.open_temporary(uri),
         {:ok, text} <- Document.fetch_text_at(document, line) do
      {line, column} = maybe_move_cursor_to_next_token(type, document, line, column)
      range = to_precise_range(document, text, line, column)
      {:ok, Location.new(range, document)}
    else
      _ ->
        {:error, "Could not open source file or fetch line text: #{inspect(file_path)}"}
    end
  end

  defp parse_location(nil, _) do
    {:ok, nil}
  end

  defp maybe_move_cursor_to_next_token(type, document, line, column)
       when type in [:function, :module, :macro] do
    position = Position.new(document, line, column)

    with {:ok, zipper} <- Ast.zipper_at(document, position),
         %{node: {entity_name, meta, _}} <- Sourceror.Zipper.next(zipper) do
      meta =
        if entity_name == :when do
          %{node: {_entity_name, meta, _}} = Sourceror.Zipper.next(zipper)
          meta
        else
          meta
        end

      {meta[:line], meta[:column]}
    else
      _ ->
        {line, column}
    end
  end

  defp maybe_move_cursor_to_next_token(_, _, line, column), do: {line, column}

  defp to_precise_range(%Document{} = document, text, line, column) do
    case Code.Fragment.surround_context(text, {line, column}) do
      %{begin: start_pos, end: end_pos} ->
        Entity.to_range(document, start_pos, end_pos)

      _ ->
        # If the column is 1, but the code doesn't start on the first column, which isn't what we want.
        # The cursor will be placed to the left of the actual definition.
        column = if column == 1, do: Text.count_leading_spaces(text) + 1, else: column
        pos = {line, column}
        Entity.to_range(document, pos, pos)
    end
  end

  defp to_location(entry) do
    uri = Document.Path.ensure_uri(entry.path)

    case Document.Store.open_temporary(uri) do
      {:ok, document} ->
        {:ok, Location.new(entry.range, document)}

      _ ->
        :error
    end
  end

  defp query_search_index(subject, condition) do
    case Store.exact(subject, condition) do
      {:ok, entries} ->
        entries

      _ ->
        []
    end
  end

  defp find_elixir_library_definition(module, function, arity) do
    with true <- elixir_library_module?(module),
         beam_path when is_list(beam_path) <- :code.which(module),
         source_path when is_binary(source_path) <- beam_to_source_path(beam_path),
         uri <- Document.Path.ensure_uri(source_path),
         {:ok, document} <- Document.Store.open_temporary(uri),
         {:ok, line} <- find_definition_line(document, function, arity) do
      {:ok, text} = Document.fetch_text_at(document, line)
      range = to_precise_range(document, text, line, 1)
      {:ok, Location.new(range, document)}
    else
      _ ->
        :error
    end
  end

  defp elixir_library_module?(module) when is_atom(module) do
    with beam_path when is_list(beam_path) <- :code.which(module),
         beam_string <- List.to_string(beam_path),
         elixir_lib_dir_charlist <- :code.lib_dir(:elixir),
         elixir_lib_dir <- elixir_lib_dir_charlist |> List.to_string() |> Path.dirname() do
      String.starts_with?(beam_string, elixir_lib_dir)
    else
      _ -> false
    end
  end

  defp beam_to_source_path(beam_path) when is_list(beam_path) do
    beam_string = List.to_string(beam_path)
    base_path = String.replace(beam_string, ~r/\/ebin\/[^\/]+\.beam$/, "")
    module_name = Path.basename(beam_string, ".beam")
    source_name = module_name |> String.replace_prefix("Elixir.", "") |> Macro.underscore()
    Path.join([base_path, "lib", "#{source_name}.ex"])
  rescue
    _ -> nil
  end

  defp find_definition_line(document, function, _arity) do
    content = Document.to_string(document)
    function_name = function |> to_string() |> Regex.escape()
    pattern = ~r/^\s*(def|defp|defmacro|defmacrop)\s+#{function_name}\s*\(/m

    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.find_value(fn {line, line_number} ->
      if Regex.match?(pattern, line) do
        line_number
      end
    end)
    |> case do
      nil -> :error
      line_number -> {:ok, line_number}
    end
  end
end
