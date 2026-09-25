defmodule Regenerator.ResultsTest do
  use ExUnit.Case, async: true
  alias Regenerator.Results

  setup do
    dir = Path.join(System.tmp_dir!(), "results-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "groups ruling and rejected retries; uses monotonic time and isolates signatures", %{
    dir: dir
  } do
    events = [
      event("run_started", 0, mode: "A"),
      failure(10, "s", 1, 1),
      failure(25, "other", 2, 1),
      event("alarm", 30, signature: "s", failed_requests_total: 2),
      bundle("a", 31),
      event("alarm", 32, signature: "other", failed_requests_total: 2),
      bundle("b", 33),
      event("proposal", 40, id: "a", kind: "question"),
      event("review", 45, id: "a", review: %{"status" => "skipped"}),
      event("decision", 50, id: "a", action: "rule"),
      bundle("retry", 55, "a"),
      event("proposal", 60, id: "retry", kind: "fix"),
      event("review", 65, id: "retry", review: %{"status" => "completed", "verdict" => "reject"}),
      event("decision", 70, id: "retry", action: "reject"),
      failure(75, "s", 3, 2),
      bundle("final", 80, "retry"),
      event("proposal", 90, id: "final", kind: "fix"),
      event("decision", 100, id: "final", action: "approve", candidate_hash: "candidate"),
      event("load", 110, id: "final", candidate_hash: "candidate"),
      event("load_verified", 150, id: "final", verified: true, failed_requests_total: 3),
      failure(170, "other", 4, 2),
      event("request_completed", 190, outcome: "succeeded"),
      event("request_completed", 210, outcome: "expected")
    ]

    write_run(dir, events, [
      {"a", "s", nil},
      {"b", "other", nil},
      {"retry", "s", "a"},
      {"final", "s", "retry"}
    ])

    result = Results.summarize(dir)
    assert result.warnings == []
    assert result.observed_requests == %{failed: 4, succeeded: 1, expected_rejections: 1}
    assert result.proposals == %{"question" => 1, "fix" => 2}
    assert result.reviewer_verdicts == %{"reject" => 1}
    assert result.decisions == %{"rule" => 1, "reject" => 1, "approve" => 1}
    assert result.recovery == %{sample_count: 1, mean_ms: 140.0, median_ms: 140}
    assert [a, b] = result.incidents
    assert a.attempt_ids == ["a", "final", "retry"]
    assert a.status == "recovered"
    assert a.observed_failed_requests == 2
    assert b.status == "unresolved"
    assert b.censored_after_ms == 185
    assert b.recovery_ms == nil
    assert Results.format(result) =~ "recovery_ms=140"
    assert JSON.decode!(JSON.encode!(result))["recovery"]["sample_count"] == 1
  end

  test "approval alone, failed loads, and failed verification do not count as recovery", %{
    dir: dir
  } do
    for tail <- [
          [],
          [event("load_failed", 80, id: "a")],
          [
            event("load", 80, id: "a", candidate_hash: "c"),
            event("load_verified", 100, id: "a", verified: false)
          ]
        ] do
      write_run(
        dir,
        baseline() ++
          [event("decision", 70, id: "a", action: "approve", candidate_hash: "c")] ++ tail
      )

      result = Results.summarize(dir)
      assert result.warnings == []
      assert result.recovery.sample_count == 0
      assert hd(result.incidents).status == "unresolved"
    end
  end

  test "unapproved and mismatched candidate loads cannot produce recovery metrics", %{dir: dir} do
    for approval <- [
          [],
          [event("decision", 60, id: "a", action: "approve", candidate_hash: "wrong")]
        ] do
      write_run(
        dir,
        baseline() ++
          approval ++
          [
            event("load", 80, id: "a", candidate_hash: "c"),
            event("load_verified", 100, id: "a", verified: true)
          ]
      )

      assert_invalid(dir)
    end
  end

  test "copied directory ignores old absolute paths and does not mutate evidence", %{dir: dir} do
    write_run(dir, baseline())
    before = snapshot(dir)
    result = Results.summarize(dir)
    assert result.run_id == "original-run"
    assert result.warnings == []
    assert snapshot(dir) == before
  end

  test "missing, corrupt and symlinked bundles suppress metrics", %{dir: dir} do
    write_run(dir, successful())
    path = Path.join(dir, "a.bundle.json")
    File.rm!(path)
    assert_invalid(dir)
    File.write!(path, "{")
    assert_invalid(dir)
    File.rm!(path)
    File.ln_s!("events.jsonl", path)
    assert_invalid(dir)
  end

  test "truncated, duplicate, gapped, reordered and inconsistent logs are flagged", %{dir: dir} do
    write_run(dir, successful())
    path = Path.join(dir, "events.jsonl")
    original = File.read!(path)
    lines = String.split(original, "\n", trim: true)

    changed_counter =
      String.replace(original, "\"failed_requests_total\":1", "\"failed_requests_total\":99")

    for bytes <- [
          original <> "{",
          String.trim_trailing(original),
          original <> Enum.at(lines, 1) <> "\n",
          Enum.join(List.delete_at(lines, 1), "\n") <> "\n",
          Enum.join(Enum.reverse(lines), "\n") <> "\n",
          changed_counter
        ] do
      File.write!(path, bytes)
      assert_invalid(dir)
    end

    File.write!(path, original <> Enum.at(lines, 1) <> "\n")
    assert Results.summarize(dir).observed_requests.failed == 1
  end

  test "malformed nested fields and identifiers yield serializable warnings, not crashes", %{
    dir: dir
  } do
    for bad <- [
          event("review", 60, id: "a", review: "broken"),
          event("review", 60, id: "a", review: %{"status" => "completed", "verdict" => %{}}),
          event("proposal", 60, id: "a", kind: %{}),
          event("bundle", 60, id: %{bad: "id"}),
          event("bundle", 60, id: "../outside"),
          event("bundle", 60, id: "b", parent_id: %{}),
          event("load_verified", 60, id: "a", verified: "true")
        ] do
      write_run(dir, baseline() ++ [bad])
      assert_invalid(dir)
    end
  end

  test "cycles, missing parents, and changed lineage signatures are flagged", %{dir: dir} do
    for {events, bundles} <- [
          {baseline() ++ [bundle("b", 60, "missing")], [{"a", "s", nil}, {"b", "s", "missing"}]},
          {Enum.take(baseline(), 3) ++ [bundle("a", 50, "b"), bundle("b", 60, "a")],
           [{"a", "s", "b"}, {"b", "s", "a"}]},
          {baseline() ++ [bundle("b", 60, "a")], [{"a", "s", nil}, {"b", "other", "a"}]}
        ] do
      write_run(dir, events, bundles)
      assert_invalid(dir)
    end
  end

  test "missing and empty logs are not empty successful trials", %{dir: dir} do
    assert_invalid(dir)
    File.write!(Path.join(dir, "events.jsonl"), "")
    assert_invalid(dir)
  end

  defp assert_invalid(dir) do
    result = Results.summarize(dir)
    assert result.evidence == "incomplete_or_inconsistent"
    assert result.warnings != []
    assert result.recovery.sample_count == 0
    assert Enum.all?(result.incidents, &(&1.recovery_ms == nil))
    assert is_binary(Results.format(result))
    assert is_binary(JSON.encode!(result))
  end

  defp baseline do
    [
      event("run_started", 0, mode: "A"),
      failure(10, "s", 1, 1),
      event("alarm", 30, signature: "s", failed_requests_total: 1),
      bundle("a", 40)
    ]
  end

  defp successful do
    baseline() ++
      [
        event("decision", 60, id: "a", action: "approve", candidate_hash: "c"),
        event("load", 80, id: "a", candidate_hash: "c"),
        event("load_verified", 100, id: "a", verified: true)
      ]
  end

  defp event(type, ms, fields) do
    Map.merge(
      %{
        "event" => type,
        "elapsed_ms" => ms,
        "run_id" => "original-run",
        "timestamp" => if(ms > 100, do: "2026-01-01T00:00:00Z", else: "2026-02-01T00:00:00Z")
      },
      Map.new(fields, fn {key, value} -> {Atom.to_string(key), value} end)
    )
  end

  defp failure(ms, signature, total, count),
    do:
      event("request_failed", ms,
        signature: signature,
        failed_requests_total: total,
        signature_failed_requests: count
      )

  defp bundle(id, ms, parent \\ nil),
    do: event("bundle", ms, id: id, parent_id: parent, path: "/original/machine/never/read.json")

  defp write_run(dir, events, bundles \\ [{"a", "s", nil}]) do
    lines =
      events
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {e, seq} -> JSON.encode!(Map.put(e, "sequence", seq)) end)

    File.write!(Path.join(dir, "events.jsonl"), lines <> "\n")

    for {id, signature, parent} <- bundles do
      File.write!(
        Path.join(dir, "#{id}.bundle.json"),
        JSON.encode!(%{id: id, signature: signature, parent_id: parent})
      )
    end
  end

  defp snapshot(dir), do: Path.wildcard(Path.join(dir, "*")) |> Map.new(&{&1, File.read!(&1)})
end
