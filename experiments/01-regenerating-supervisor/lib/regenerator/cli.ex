defmodule Regenerator.CLI do
  alias Regenerator.{Engine, Load}

  def main(args) do
    {opts, _, invalid} =
      OptionParser.parse(args,
        strict: [
          rate: :integer,
          seed: :integer,
          actor: :string,
          auto_repair: :boolean,
          threshold: :integer,
          scope: :string
        ]
      )

    rate = Keyword.get(opts, :rate, 10)
    threshold = Keyword.get(opts, :threshold, 3)
    scope = Keyword.get(opts, :scope, "narrow")
    actor = Keyword.get(opts, :actor, System.get_env("USER", "operator"))

    if invalid != [] or rate not in 1..1000 or threshold < 2 or scope not in ["narrow", "broad"],
      do: raise(ArgumentError, "Use --rate 1..1000 --threshold >=2 --scope narrow|broad")

    engine = [
      threshold: threshold,
      scope: scope,
      auto_repair: Keyword.get(opts, :auto_repair, true),
      agent_command: command_env("REGEN_AGENT_COMMAND"),
      reviewer_command: command_env("REGEN_REVIEWER_COMMAND")
    ]

    Application.put_env(:regenerator, :engine, engine)
    {:ok, _} = Application.ensure_all_started(:regenerator)
    # Expected task crashes are captured in bundles; keep them out of the card UI.
    Logger.configure(level: :critical)
    seed = Keyword.get(opts, :seed, 42)
    {:ok, _} = Load.start_link(rate: rate, seed: seed)

    IO.puts(
      "Mode A • #{rate} requests/sec • seed #{seed} • #{scope} context\nRun: #{Engine.status().run_dir}"
    )

    IO.puts(
      "Commands: status, list, show ID, repair ID, approve ID, reject ID reason, rule ID JSON, pause, resume, quit"
    )

    loop(actor)
  end

  def card(id, card) do
    proposal = card.proposal || %{}
    review = proposal["review"] || %{"status" => "not run"}
    tests = proposal["tests"] || %{}

    """
    ── Escalation #{id} [#{card.status}] ──
    What broke: #{card.bundle["reason"]}
    Scenario: #{JSON.encode!(card.bundle["input"])}
    Proposed behavior: #{proposal["description"] || "No fix proposed"}
    Question: #{proposal["question"] || "—"}
    Options: #{Enum.join(proposal["options"] || [], " | ")}
    Tests passed: #{inspect(tests["passed"])}; reproducer failed first: #{inspect(tests["reproduction_failed"])}
    Test output:
    #{tests["output"] || "Not available"}
    Independent review: #{review["status"]}; #{review["verdict"]}
    #{review["details"]}
    Runner error: #{proposal["error"] || "—"}
    Artifacts: #{card.output}
    Approval loads only a fix. A question needs an explicit rule and a separate later fix approval.
    """
  end

  defp loop(actor) do
    case IO.gets("supervisor> ") do
      :eof ->
        :ok

      {:error, _} ->
        :ok

      line ->
        case String.split(String.trim(line), " ", parts: 3, trim: true) do
          ["quit"] ->
            :ok

          parts ->
            execute(parts, actor)
            loop(actor)
        end
    end
  end

  defp execute(parts, actor) do
    case parts do
      ["status"] ->
        IO.inspect(Engine.status())

      ["list"] ->
        for {id, card} <- Engine.cards(),
            do: IO.puts("#{id} #{card.status} #{card.bundle["reason"]}")

      ["show", id] ->
        case Engine.cards()[id] do
          nil -> IO.puts("Unknown card")
          value -> IO.puts(card(id, value))
        end

      ["repair", id] ->
        IO.inspect(Engine.repair(id))

      ["approve", id] ->
        IO.inspect(Engine.decide(id, :approve, actor))

      ["approve", id, reason] ->
        IO.inspect(Engine.decide(id, :approve, actor, reason))

      ["reject", id, reason] ->
        IO.inspect(Engine.decide(id, :reject, actor, reason))

      ["rule", id, json] ->
        data = JSON.decode!(json)

        IO.inspect(
          Engine.rule(id, actor, Map.fetch!(data, "ruling"), Map.fetch!(data, "rationale"))
        )

      ["pause"] ->
        Load.pause()

      ["resume"] ->
        Load.resume()

      _ ->
        IO.puts(
          "Unknown command. For rulings: rule ID {\"ruling\":\"...\",\"rationale\":\"...\"}"
        )
    end
  rescue
    error -> IO.puts("Command failed: #{Exception.message(error)}")
  end

  defp command_env(name) do
    case System.get_env(name) do
      nil -> nil
      text -> JSON.decode!(text)
    end
  end
end
