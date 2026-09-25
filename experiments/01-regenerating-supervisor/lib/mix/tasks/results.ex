defmodule Mix.Tasks.Results do
  use Mix.Task
  @shortdoc "Summarize saved Mode A run directories without starting the app"
  @requirements ["compile"]

  def run(args) do
    {opts, directories, invalid} = OptionParser.parse(args, strict: [json: :boolean])

    if invalid != [] || directories == [],
      do: Mix.raise("Usage: mix results [--json] RUN_DIRECTORY [RUN_DIRECTORY ...]")

    results =
      directories
      |> Enum.map(&Path.expand/1)
      |> Enum.uniq()
      |> Enum.map(&Regenerator.Results.summarize/1)

    if opts[:json] do
      Mix.shell().info(JSON.encode!(%{schema_version: 1, runs: results}))
    else
      Mix.shell().info(Enum.map_join(results, "\n\n", &Regenerator.Results.format/1))
    end
  end
end
