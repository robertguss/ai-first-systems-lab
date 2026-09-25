defmodule Regenerator.Runner do
  @moduledoc false

  def run(root, bundle_path, output, opts) do
    args = [
      Path.join(root, "scripts/repair.py"),
      "--workspace",
      root,
      "--bundle",
      bundle_path,
      "--output",
      output,
      "--scope",
      Keyword.get(opts, :scope, "narrow")
    ]

    args =
      Enum.reduce(
        [agent_command: "--command-json", reviewer_command: "--reviewer-command-json"],
        args,
        fn {key, flag}, args ->
          case Keyword.get(opts, key) do
            nil -> args
            command -> args ++ [flag, JSON.encode!(command)]
          end
        end
      )

    {log, status} = System.cmd("python3", args, stderr_to_stdout: true)

    case File.read(Path.join(output, "proposal.json")) do
      {:ok, json} ->
        JSON.decode!(json)

      {:error, reason} ->
        %{
          "kind" => "failed",
          "error" =>
            "Runner exited #{status}: #{inspect(reason)} #{String.slice(log, -4000, 4000)}"
        }
    end
  rescue
    exception -> %{"kind" => "failed", "error" => Exception.message(exception)}
  end
end
