defmodule Testor.Reports.XML do
  @moduledoc """
  A guarded XML reader for report files (JUnit, TRX, Cobertura), on OTP's
  `:xmerl_sax_parser`, without a dependency. A document with a `<!DOCTYPE` or `<!ENTITY` is
  refused before it is parsed (no external entities, no entity expansion), and parsing stops
  past #{64} levels of nesting or #{500_000} elements. Text is kept up to #{2048} bytes per
  element.

  `parse/1` gives a tree of `{name, attributes, children, text}`: the local name, a map of
  attribute names to values, the child elements in order, and the element's own text.
  """

  @max_depth 64
  @max_elements 500_000
  @max_text 2048

  @doc "`{:ok, root}` or `{:error, reason}`."
  def parse(xml) when is_binary(xml) do
    if Regex.match?(~r/<!(DOCTYPE|ENTITY)/i, xml) do
      {:error, "DOCTYPE and ENTITY are not accepted"}
    else
      run(xml)
    end
  end

  # Past a limit, the rest of the document is read without being kept (xmerl gives no way to
  # stop it from the event function), and the answer is the limit.
  defp run(xml) do
    state = %{stack: [], root: nil, count: 0, error: nil}

    case :xmerl_sax_parser.stream(xml, event_fun: &event/3, event_state: state, external_entities: :none) do
      {:ok, %{error: nil, root: root}, _rest} ->
        {:ok, root}

      {:ok, %{error: why}, _rest} ->
        {:error, why}

      {_tag, _location, reason, _end_tags, _state} ->
        {:error, "not well-formed: #{inspect(reason) |> String.slice(0, 200)}"}
    end
  end

  defp event(_event, _location, %{error: why} = state) when why != nil, do: state

  defp event({:startElement, _uri, local, _qname, attributes}, _location, state) do
    count = state.count + 1
    max = Application.get_env(:testor, :xml_max_elements, @max_elements)

    cond do
      count > max ->
        %{state | error: "more than #{max} elements"}

      length(state.stack) >= @max_depth ->
        %{state | error: "nested deeper than #{@max_depth}"}

      true ->
        attrs =
          Map.new(attributes, fn {_uri, _prefix, name, value} -> {to_string(name), to_string(value)} end)

        %{state | stack: [{to_string(local), attrs, [], ""} | state.stack], count: count}
    end
  end

  defp event({:characters, chars}, _location, %{stack: [{name, attrs, children, text} | rest]} = state) do
    text =
      if String.length(text) < @max_text, do: String.slice(text <> to_string(chars), 0, @max_text), else: text

    %{state | stack: [{name, attrs, children, text} | rest]}
  end

  defp event(
         {:endElement, _uri, _local, _qname},
         _location,
         %{stack: [{name, attrs, children, text} | rest]} = state
       ) do
    element = {name, attrs, Enum.reverse(children), text}

    case rest do
      [] -> %{state | stack: [], root: element}
      [{pn, pa, pc, pt} | up] -> %{state | stack: [{pn, pa, [element | pc], pt} | up]}
    end
  end

  defp event(_event, _location, state), do: state

  # --- walking -------------------------------------------------------------------------------

  @doc "Every element named `name` below (and including) `element`, depth first."
  def all({el_name, _, children, _} = element, name) do
    here = if el_name == name, do: [element], else: []
    here ++ Enum.flat_map(children, &all(&1, name))
  end

  @doc "The first child named `name`, or nil."
  def child({_, _, children, _}, name), do: Enum.find(children, &(elem(&1, 0) == name))

  def name({name, _, _, _}), do: name
  def attr({_, attrs, _, _}, key), do: attrs[key]
  def text({_, _, _, text}), do: text
end
