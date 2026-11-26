defmodule Testor.Select do
  @moduledoc """
  A job's selection (`"select"`): what part of a suite it runs, as data the agent hands to the
  command the way its `agent.json` says (separate arguments, never a shell string).

    * `files`: up to 2,000 paths inside the workspace (`Testor.Snapshots.path?/1`);
    * `names`: up to 50 test-name patterns, 200 characters each, no control characters;
    * `affected`: `true`, or `"then-all"` (the affected tests first, then the rest), on a
      snapshot job: testor adds the files that changed since the branch's previous snapshot as
      `changed` (`Testor.Snapshots.changed/3`).

  A run's record keeps the selection, so a scoped run is never taken for a full one: release
  gates and commit statuses leave scoped runs out unless a gate says `"scoped": true`.
  """

  @max_files 2_000
  @max_names 50

  def max_files, do: @max_files

  @doc "The selection, checked: `{:ok, map | nil}` or `{:error, message}`."
  def check(nil), do: {:ok, nil}

  def check(%{} = select) do
    files = Map.get(select, "files", [])
    names = Map.get(select, "names", [])
    affected = Map.get(select, "affected", false)

    cond do
      Map.keys(select) -- ["files", "names", "affected"] != [] ->
        {:error, "select has files, names and affected"}

      not (is_list(files) and length(files) <= @max_files and Enum.all?(files, &Testor.Snapshots.path?/1)) ->
        {:error, "select.files is up to #{@max_files} paths inside the workspace"}

      not (is_list(names) and length(names) <= @max_names and Enum.all?(names, &name?/1)) ->
        {:error, "select.names is up to #{@max_names} test names of 200 characters, no control characters"}

      affected not in [true, false, "then-all"] ->
        {:error, ~s(select.affected is true or "then-all")}

      files == [] and names == [] and affected == false ->
        {:error, "select names files, names or affected"}

      true ->
        {:ok,
         %{}
         |> put_if("files", Enum.uniq(files), files != [])
         |> put_if("names", Enum.uniq(names), names != [])
         |> put_if("affected", affected, affected != false)}
    end
  end

  def check(_), do: {:error, "select is an object: {files, names, affected}"}

  defp name?(name),
    do:
      is_binary(name) and String.length(name) in 1..200 and String.valid?(name) and
        not Regex.match?(~r/[\x00-\x1f\x7f]/, name)

  defp put_if(map, key, value, true), do: Map.put(map, key, value)
  defp put_if(map, _key, _value, false), do: map
end
