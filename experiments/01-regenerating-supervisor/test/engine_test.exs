defmodule Regenerator.EngineTest do
  use ExUnit.Case, async: false
  alias Regenerator.{Engine, Loader, Store}
  @moduletag capture_log: true

  # These independent arithmetic fixtures exercise the controller, not shipping policy.
  @source """
  defmodule ShippingEstimate do
    def estimate(%{"n" => 0}), do: raise(ArgumentError, "zero has no result")
    def estimate(%{"n" => -1}), do: raise(ArithmeticError, "negative is undefined")
    def estimate(%{"n" => "wait"}), do: Process.sleep(10_000)
    def estimate(%{"n" => n}) when is_integer(n), do: {:ok, n * 3}
    def estimate(_), do: {:error, :invalid_input}
  end
  """
  @contract "Purpose: multiply nonnegative integers by three. Negative input has no defined policy."

  setup do
    Code.ensure_loaded!(ShippingEstimate)
    {ShippingEstimate, original, _} = :code.get_object_code(ShippingEstimate)
    old_options = Code.compiler_options(ignore_module_conflict: true)
    [{ShippingEstimate, beam}] = Code.compile_string(@source)
    root = Path.join(System.tmp_dir!(), "controller-#{Store.id()}")
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "contracts"))
    File.write!(Path.join(root, "lib/shipping_estimate.ex"), @source)
    File.write!(Path.join(root, "contracts/shipping_estimate.md"), @contract)

    on_exit(fn ->
      :ok = Loader.load(%{beam: original})
      Code.compiler_options(old_options)
      File.rm_rf!(root)
    end)

    %{root: root, beam: beam}
  end

  defp engine(context, opts \\ []) do
    start_supervised!(
      {Engine, [root: context.root, initial_beam: context.beam, name: :test_engine] ++ opts}
    )
  end

  defp failures(server, n \\ 0, count \\ 3) do
    for _ <- 1..count, do: assert(Engine.quote(%{"n" => n}, server) == {:error, :unavailable})
    Engine.cards(server)
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end

  defp candidate(context) do
    source = String.replace(@source, "raise(ArgumentError, \"zero has no result\")", "{:ok, 0}")
    [{ShippingEstimate, beam}] = Code.compile_string(source)
    :ok = Loader.load(%{beam: context.beam})

    runner = fn _root, bundle_path, output, _opts ->
      bundle = File.read!(bundle_path) |> JSON.decode!()
      File.mkdir_p!(output)
      File.write!(Path.join(output, "candidate.ex"), source)
      File.write!(Path.join(output, "candidate.beam"), beam)

      %{
        "kind" => "fix",
        "description" => "Return zero for zero.",
        "base_source_hash" => bundle["source_hash"],
        "base_contract_hash" => bundle["contract_hash"],
        "candidate_hash" => Store.hash(beam),
        "candidate_source_hash" => Store.hash(source),
        "probe_result" => "{:ok, 0}",
        "tests" => %{
          "passed" => true,
          "reproduction_failed" => true,
          "output" => "Synthetic fixture"
        },
        "review" => %{"status" => "skipped", "verdict" => "Not configured"}
      }
    end

    runner
  end

  test "requests fail fast while healthy requests survive and alarms deduplicate", context do
    server = engine(context)
    app = Process.whereis(Regenerator.Supervisor)
    requests = Process.whereis(Regenerator.Requests)
    assert Engine.quote(%{"n" => 0}, server) == {:error, :unavailable}
    assert Engine.cards(server) == %{}
    assert Engine.quote(%{"n" => 7}, server) == {:ok, 21}
    assert Engine.quote(%{}, server) == {:error, :invalid_input}
    [{id, card}] = failures(server, 0, 20) |> Map.to_list()
    assert card.status == :alarmed
    bundle = File.read!(card.bundle_path) |> JSON.decode!()
    assert bundle["id"] == id
    assert bundle["source"] == @source
    assert bundle["contract"] == @contract
    assert bundle["input"] == %{"n" => 0}
    assert bundle["stacktrace"] =~ "estimate"
    assert bundle["reason"] =~ "zero has no result"
    assert Engine.status(server).failed == 21
    assert Process.whereis(Regenerator.Supervisor) == app
    assert Process.whereis(Regenerator.Requests) == requests
    assert Process.alive?(server)
    assert Engine.quote(%{"n" => 11}, server) == {:ok, 33}

    events =
      Path.join(Engine.status(server).run_dir, "events.jsonl")
      |> File.stream!()
      |> Enum.map(&JSON.decode!/1)

    assert Enum.count(events, &(&1["event"] == "alarm")) == 1
    assert Enum.count(events, &(&1["event"] == "request_failed")) == 21
    assert Enum.map(events, & &1["sequence"]) == Enum.to_list(1..length(events))
  end

  test "non-replayable nested values are invalid inputs, never fatal evidence", context do
    server = engine(context)

    for extra <- [self(), make_ref(), {:tuple, 1}, <<255>>, %{atom_key: 3}] do
      for _ <- 1..4 do
        assert Engine.quote(%{"n" => 0, "extra" => [extra]}, server) == {:error, :invalid_input}
      end
    end

    assert Process.alive?(server)
    assert Engine.cards(server) == %{}
    assert Engine.quote(%{"n" => 3}, server) == {:ok, 9}
  end

  test "reviewer dissent requires a recorded human reason; failed review blocks loading",
       context do
    builder = candidate(context)

    runner = fn a, b, c, d ->
      builder.(a, b, c, d)
      |> Map.put("review", %{
        "status" => "completed",
        "verdict" => "reject",
        "details" => "Insufficient cases"
      })
    end

    server = engine(context, auto_repair: true, runner: runner)
    [{id, _}] = failures(server) |> Map.to_list()
    eventually(fn -> Engine.cards(server)[id].status == :proposed end)

    assert Engine.decide(id, :approve, "operator", "", server) ==
             {:error, :reviewer_dissent_requires_reason}

    card = Engine.cards(server)[id]
    version = :sys.get_state(server).version
    failed = put_in(card.proposal, ["review", "status"], "failed")
    assert {:error, _} = Loader.candidate(card.output, failed, version)

    assert {:error, _} =
             Loader.candidate(card.output, Map.put(card.proposal, "tests", "invalid"), version)

    assert {:ok, :verifying} =
             Engine.decide(id, :approve, "operator", "I checked the disputed case", server)

    eventually(fn -> Engine.cards(server)[id].status == :loaded end)
  end

  test "different crashes have distinct signatures and old occurrences expire", context do
    server = engine(context, window_ms: 100)

    for _ <- 1..3 do
      Engine.quote(%{"n" => 0}, server)
      Process.sleep(120)
    end

    assert Engine.cards(server) == %{}
    failures(server)
    assert map_size(failures(server, -1)) == 2
  end

  test "request timeouts and runner crashes never escalate through application supervision",
       context do
    server =
      engine(context,
        request_timeout: 100,
        auto_repair: true,
        runner: fn _, _, _, _ -> exit(:unavailable_agent) end
      )

    started = System.monotonic_time(:millisecond)
    assert Engine.quote(%{"n" => "wait"}, server) == {:error, :unavailable}
    assert System.monotonic_time(:millisecond) - started < 500
    failures(server)

    eventually(fn ->
      Enum.any?(Engine.cards(server), fn {_, c} -> c.status == :repair_failed end)
    end)

    assert Process.alive?(server)
    assert Engine.quote(%{"n" => 9}, server) == {:ok, 27}
  end

  test "approval loads exact candidate, verifies live behavior, and retains prior bytes",
       context do
    runner = candidate(context)
    server = engine(context, auto_repair: true, runner: runner)
    app = Process.whereis(Regenerator.Supervisor)
    [{id, _}] = failures(server) |> Map.to_list()
    eventually(fn -> Engine.cards(server)[id].status == :proposed end)
    assert Engine.quote(%{"n" => 0}, server) == {:error, :unavailable}
    assert Engine.decide(id, :approve, "operator", "", server) == {:ok, :verifying}
    eventually(fn -> Engine.cards(server)[id].status == :loaded end)
    assert Engine.quote(%{"n" => 0}, server) == {:ok, 0}
    assert Engine.quote(%{"n" => 7}, server) == {:ok, 21}
    assert Process.whereis(Regenerator.Supervisor) == app
    previous = File.read!(Path.join(Engine.status(server).run_dir, "#{id}.previous.beam"))
    assert previous == context.beam

    assert Engine.decide(id, :approve, "operator", "", server) ==
             {:error, :invalid_decision_or_storage_unavailable}

    # Swap-back primitive works from retained bytes without a restart.
    assert Loader.load(%{beam: previous}) == :ok
    assert_raise ArgumentError, fn -> ShippingEstimate.estimate(%{"n" => 0}) end
  end

  test "rejection leaves the failure live; new attempts preserve old bundles", context do
    server = engine(context, auto_repair: true, runner: candidate(context))
    [{id, card}] = failures(server) |> Map.to_list()
    eventually(fn -> Engine.cards(server)[id].status == :proposed end)
    bytes = File.read!(card.bundle_path)
    assert :ok = Engine.decide(id, :reject, "operator", "Unconvincing", server)
    assert Engine.quote(%{"n" => 0}, server) == {:error, :unavailable}
    assert {:ok, other} = Engine.repair(id, server)
    assert other != id
    assert File.read!(card.bundle_path) == bytes
    assert Engine.cards(server)[other].bundle["parent_id"] == id
  end

  test "a gap ruling updates precedent and starts a separate unapproved attempt", context do
    owner = self()

    runner = fn _, bundle_path, _, _ ->
      send(owner, {:bundle, File.read!(bundle_path) |> JSON.decode!()})

      %{
        "kind" => "question",
        "question" => "What is the negative input policy?",
        "options" => ["Reject", "Multiply"],
        "review" => %{"status" => "skipped"}
      }
    end

    server = engine(context, auto_repair: true, runner: runner)
    [{id, card}] = failures(server, -1) |> Map.to_list()
    eventually(fn -> Engine.cards(server)[id].status == :proposed end)
    assert_receive {:bundle, original}
    assert {:error, _} = Engine.decide(id, :approve, "operator", "", server)

    assert {:ok, new_id} =
             Engine.rule(
               id,
               "operator",
               "Reject negative input.",
               "Only nonnegative values are meaningful.",
               server
             )

    assert_receive {:bundle, revised}, 1000
    assert revised["parent_id"] == id
    assert revised["contract"] =~ "Reject negative input."
    assert revised["contract_hash"] != original["contract_hash"]
    assert File.read!(card.bundle_path) |> JSON.decode!() == original
    assert Engine.quote(%{"n" => -1}, server) == {:error, :unavailable}
    eventually(fn -> Engine.cards(server)[new_id].status == :proposed end)
    assert Engine.cards(server)[id].status == :ruled
  end

  test "tampered artifacts, stale contracts, and failed evidence cannot be approved", context do
    server = engine(context, auto_repair: true, runner: candidate(context))
    [{id, _}] = failures(server) |> Map.to_list()
    eventually(fn -> Engine.cards(server)[id].status == :proposed end)
    card = Engine.cards(server)[id]
    version = :sys.get_state(server).version

    assert {:error, _} =
             Loader.candidate(card.output, card.proposal, %{version | contract_hash: "changed"})

    assert {:error, _} =
             Loader.candidate(
               card.output,
               put_in(card.proposal, ["tests", "passed"], false),
               version
             )

    File.write!(Path.join(card.output, "candidate.beam"), "not the reviewed bytes")

    assert {:error, :invalid_or_stale_proposal} =
             Engine.decide(id, :approve, "operator", "", server)

    assert Engine.quote(%{"n" => 0}, server) == {:error, :unavailable}
  end

  test "failed storage preserves service and forbids unlogged loads", context do
    server = engine(context, auto_repair: true, runner: candidate(context))
    [{id, _}] = failures(server) |> Map.to_list()
    eventually(fn -> Engine.cards(server)[id].status == :proposed end)
    log = Path.join(Engine.status(server).run_dir, "events.jsonl")
    File.rename!(log, log <> ".preserved")
    File.mkdir!(log)
    assert {:error, :storage_unavailable} = Engine.decide(id, :approve, "operator", "", server)
    assert Process.alive?(server)
    assert Engine.quote(%{"n" => 2}, server) == {:ok, 6}
    assert Engine.status(server).storage_error != nil
  end
end
