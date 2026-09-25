defmodule Regenerator.Results do
  @moduledoc "Read-only analysis of Mode A run snapshots. Never starts the application."

  def summarize(directory) do
    directory = Path.expand(directory)
    {events, warnings} = read_events(Path.join(directory, "events.jsonl"))
    warnings = warnings ++ check_events(events)
    bundles = Enum.filter(events, &(&1["event"] == "bundle"))

    {attempts, warnings} =
      Enum.reduce(bundles, {%{}, warnings}, fn event, {attempts, warnings} ->
        id = event["id"]
        {bundle, errors} = read_bundle(directory, event)
        duplicate = if Map.has_key?(attempts, id), do: ["Duplicate bundle ID #{id}"], else: []
        {Map.put(attempts, id, %{event: event, bundle: bundle}), warnings ++ errors ++ duplicate}
      end)

    {roots, lineage_errors} =
      Enum.reduce(Map.keys(attempts), {%{}, []}, fn id, {roots, errors} ->
        case root(id, attempts, MapSet.new()) do
          {:ok, ancestor} -> {Map.put(roots, id, ancestor), errors}
          {:error, error} -> {Map.put(roots, id, id), [error | errors]}
        end
      end)

    alarms = Enum.filter(events, &(&1["event"] == "alarm"))
    signatures = for {_, attempt} <- attempts, do: attempt.bundle["signature"]
    missing = Enum.reject(alarms, &(&1["signature"] in signatures))

    orphan_ids =
      for event <- events,
          is_binary(event["id"]),
          !Map.has_key?(attempts, event["id"]),
          do: event["id"]

    warnings =
      warnings ++
        lineage_errors ++
        Enum.map(missing, &"Alarm #{&1["signature"]} has no readable bundle") ++
        Enum.map(Enum.uniq(orphan_ids), &"Events reference missing bundle #{&1}")

    groups = Enum.group_by(roots, fn {_id, ancestor} -> ancestor end, fn {id, _} -> id end)

    {incidents, incident_errors} =
      Enum.map(groups, fn {id, ids} -> incident(id, ids, attempts, events) end) |> Enum.unzip()

    warnings = Enum.uniq(warnings ++ List.flatten(incident_errors))
    consistent = warnings == []

    incidents =
      Enum.map(incidents, fn incident ->
        if consistent,
          do: incident,
          else: %{incident | status: "unverifiable", recovery_ms: nil, censored_after_ms: nil}
      end) ++
        Enum.map(missing, fn alarm ->
          %{
            id: nil,
            signature: alarm["signature"],
            attempt_ids: [],
            status: "unverifiable",
            recovery_ms: nil,
            censored_after_ms: nil,
            observed_verified_loads: 0,
            observed_failed_requests:
              Enum.count(
                events,
                &(&1["event"] == "request_failed" && &1["signature"] == alarm["signature"])
              )
          }
        end)

    durations = for %{status: "recovered", recovery_ms: ms} <- incidents, do: ms
    reviews = Enum.filter(events, &(&1["event"] == "review"))

    %{
      directory: directory,
      run_id: get_in(List.first(events) || %{}, ["run_id"]),
      evidence: if(consistent, do: "consistent_snapshot", else: "incomplete_or_inconsistent"),
      warnings: warnings,
      observation_ms: (List.last(events) || %{})["elapsed_ms"],
      observed_requests: %{
        failed: Enum.count(events, &(&1["event"] == "request_failed")),
        succeeded:
          Enum.count(
            events,
            &(&1["event"] == "request_completed" && &1["outcome"] == "succeeded")
          ),
        expected_rejections:
          Enum.count(events, &(&1["event"] == "request_completed" && &1["outcome"] == "expected"))
      },
      alarms: length(alarms),
      attempts: map_size(attempts),
      proposals: frequencies(events, "proposal", "kind"),
      decisions: frequencies(events, "decision", "action"),
      review_statuses: Enum.frequencies_by(reviews, &get_in(&1, ["review", "status"])),
      reviewer_verdicts:
        reviews
        |> Enum.filter(&(get_in(&1, ["review", "status"]) == "completed"))
        |> Enum.frequencies_by(&get_in(&1, ["review", "verdict"])),
      loads: Enum.count(events, &(&1["event"] == "load")),
      failed_loads: Enum.count(events, &(&1["event"] == "load_failed")),
      failed_verifications:
        Enum.count(events, &(&1["event"] == "load_verified" && &1["verified"] == false)),
      recovery: %{
        sample_count: length(durations),
        mean_ms: mean(durations),
        median_ms: median(durations)
      },
      incidents: Enum.sort_by(incidents, &(&1.id || &1.signature))
    }
  end

  def format(result) do
    counts = result.observed_requests

    rows =
      for incident <- result.incidents do
        "  #{incident.id || incident.signature}: #{incident.status}; attempts=#{length(incident.attempt_ids)}; " <>
          "observed failures=#{incident.observed_failed_requests}; recovery_ms=#{display(incident.recovery_ms)}; " <>
          "censored_after_ms=#{display(incident.censored_after_ms)}"
      end

    Enum.join(
      [
        "Run #{result.run_id || "unknown"} — #{result.evidence}",
        "Directory: #{result.directory}",
        "Observed requests: #{counts.failed} failed, #{counts.succeeded} succeeded, #{counts.expected_rejections} expected rejections",
        "Alarms: #{result.alarms}; attempts: #{result.attempts}; loads: #{result.loads}; failed loads: #{result.failed_loads}; failed verifications: #{result.failed_verifications}",
        "Proposals: #{JSON.encode!(result.proposals)}; decisions: #{JSON.encode!(result.decisions)}",
        "Reviews: #{JSON.encode!(result.review_statuses)}; completed verdicts: #{JSON.encode!(result.reviewer_verdicts)}",
        "Verified recovery samples: #{result.recovery.sample_count}; mean_ms=#{display(result.recovery.mean_ms)}; median_ms=#{display(result.recovery.median_ms)}",
        Enum.join(rows, "\n"),
        Enum.map_join(result.warnings, "\n", &"WARNING: #{&1}"),
        "Snapshot only: no run-end marker exists. Unresolved cases are censored at the last recorded event."
      ],
      "\n"
    )
  end

  defp read_events(path) do
    case File.read(path) do
      {:ok, content} ->
        trailing =
          if String.ends_with?(content, "\n"),
            do: [],
            else: ["Log lacks a final newline; the last write may be truncated"]

        {events, errors, _seen} =
          content
          |> String.split("\n", trim: true)
          |> Enum.with_index(1)
          |> Enum.reduce({[], trailing, MapSet.new()}, fn {line, number},
                                                          {events, errors, seen} ->
            case JSON.decode(line) do
              {:ok, event} when is_map(event) ->
                cond do
                  !valid_envelope?(event) ->
                    {events, ["Invalid event envelope on line #{number}" | errors], seen}

                  !valid_payload?(event) ->
                    {events, ["Invalid event payload on line #{number}" | errors], seen}

                  MapSet.member?(seen, event["sequence"]) ->
                    {events, ["Duplicate sequence on line #{number}" | errors], seen}

                  true ->
                    {[event | events], errors, MapSet.put(seen, event["sequence"])}
                end

              _ ->
                {events, ["Invalid JSON object on line #{number}" | errors], seen}
            end
          end)

        {Enum.reverse(events), Enum.reverse(errors)}

      {:error, error} ->
        {[], ["Cannot read events.jsonl: #{error}"]}
    end
  end

  defp valid_envelope?(e) do
    is_binary(e["event"]) && is_binary(e["run_id"]) && is_integer(e["sequence"]) &&
      e["sequence"] > 0 &&
      is_integer(e["elapsed_ms"]) && e["elapsed_ms"] >= 0 && is_binary(e["timestamp"]) &&
      match?({:ok, _, _}, DateTime.from_iso8601(e["timestamp"]))
  end

  defp valid_payload?(e) do
    identity = !Map.has_key?(e, "id") || safe_id?(e["id"])
    parent = is_nil(e["parent_id"]) || safe_id?(e["parent_id"])

    fields =
      case e["event"] do
        "run_started" ->
          e["mode"] == "A"

        "request_completed" ->
          e["outcome"] in ["succeeded", "expected"]

        type when type in ["request_failed", "alarm"] ->
          is_binary(e["signature"])

        "proposal" ->
          e["kind"] in ["fix", "question", "failed"]

        "decision" ->
          e["action"] in ["approve", "reject", "rule"]

        "review" ->
          is_map(e["review"]) && e["review"]["status"] in ["completed", "skipped", "failed"] &&
            (e["review"]["status"] != "completed" ||
               e["review"]["verdict"] in ["accept", "reject", "question"])

        "load_verified" ->
          is_boolean(e["verified"])

        type
        when type in [
               "bundle",
               "regeneration_started",
               "contract_ruling",
               "load",
               "load_failed",
               "load_generator"
             ] ->
          true

        _ ->
          false
      end

    needs_id =
      e["event"] in [
        "bundle",
        "regeneration_started",
        "proposal",
        "review",
        "decision",
        "contract_ruling",
        "load",
        "load_failed",
        "load_verified"
      ]

    identity && parent && fields && (!needs_id || safe_id?(e["id"]))
  end

  defp safe_id?(id), do: is_binary(id) && Regex.match?(~r/\A[a-zA-Z0-9_-]+\z/, id)

  defp check_events([]), do: ["No readable events"]

  defp check_events(events) do
    first = hd(events)

    initial =
      if first["event"] == "run_started" && first["mode"] == "A",
        do: [],
        else: ["Missing Mode A run_started event"]

    {_, _, _, _, errors} =
      Enum.reduce(events, {0, 0, 0, %{}, initial}, fn e,
                                                      {seq, ms, failed, per_signature, errors} ->
        errors =
          if e["sequence"] == seq + 1,
            do: errors,
            else: ["Nonconsecutive sequence #{e["sequence"]}" | errors]

        errors =
          if e["elapsed_ms"] >= ms, do: errors, else: ["Elapsed time moved backwards" | errors]

        errors = if e["run_id"] == first["run_id"], do: errors, else: ["Mixed run IDs" | errors]

        {failed, per_signature, errors} =
          if e["event"] == "request_failed" do
            count = Map.get(per_signature, e["signature"], 0) + 1

            valid =
              is_binary(e["signature"]) && e["failed_requests_total"] == failed + 1 &&
                e["signature_failed_requests"] == count

            {failed + 1, Map.put(per_signature, e["signature"], count),
             if(valid,
               do: errors,
               else: ["Failure counter/signature mismatch at sequence #{e["sequence"]}" | errors]
             )}
          else
            {failed, per_signature, errors}
          end

        errors =
          if Map.has_key?(e, "failed_requests_total") && e["failed_requests_total"] != failed,
            do: ["Cumulative failure count mismatch at sequence #{e["sequence"]}" | errors],
            else: errors

        {e["sequence"], e["elapsed_ms"], failed, per_signature, errors}
      end)

    Enum.reverse(errors)
  end

  defp read_bundle(directory, event) do
    id = event["id"]
    path = Path.join(directory, "#{id}.bundle.json")

    with {:ok, %{type: :regular}} <- File.lstat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, bundle} when is_map(bundle) <- JSON.decode(bytes),
         true <-
           bundle["id"] == id && bundle["parent_id"] == event["parent_id"] &&
             is_binary(bundle["signature"]) do
      {bundle, []}
    else
      _ -> {%{}, ["Missing, invalid, or symlinked bundle #{id}"]}
    end
  end

  defp root(id, attempts, seen) do
    cond do
      MapSet.member?(seen, id) -> {:error, "Cyclic attempt lineage at #{id}"}
      !Map.has_key?(attempts, id) -> {:error, "Missing parent attempt #{id}"}
      is_nil(attempts[id].event["parent_id"]) -> {:ok, id}
      true -> root(attempts[id].event["parent_id"], attempts, MapSet.put(seen, id))
    end
  end

  defp incident(id, ids, attempts, events) do
    signature = attempts[id].bundle["signature"]

    failures =
      Enum.filter(events, &(&1["event"] == "request_failed" && &1["signature"] == signature))

    related = Enum.filter(events, &(&1["id"] in ids))
    verified = Enum.filter(related, &(&1["event"] == "load_verified" && &1["verified"] == true))

    errors =
      Enum.flat_map(verified, fn event ->
        prior =
          Enum.filter(related, &(&1["id"] == event["id"] && &1["sequence"] < event["sequence"]))

        load = Enum.find(Enum.reverse(prior), &(&1["event"] == "load"))

        approval =
          Enum.find(
            Enum.reverse(prior),
            &(&1["event"] == "decision" && &1["action"] == "approve")
          )

        if load && approval && approval["sequence"] < load["sequence"] &&
             is_binary(load["candidate_hash"]) &&
             approval["candidate_hash"] == load["candidate_hash"],
           do: [],
           else: ["Verified load #{event["id"]} lacks matching prior approval/load"]
      end)

    errors =
      if failures == [], do: ["Incident #{id} has no first-failure event" | errors], else: errors

    errors =
      if Enum.all?(ids, &(attempts[&1].bundle["signature"] == signature)),
        do: errors,
        else: ["Attempt signature changed within incident #{id}" | errors]

    errors =
      if Enum.any?(events, &(&1["event"] == "alarm" && &1["signature"] == signature)),
        do: errors,
        else: ["Incident #{id} has no matching alarm" | errors]

    first = List.first(failures)
    recovered = List.first(verified)
    last = recovered || List.last(events)
    duration = if first && last, do: last["elapsed_ms"] - first["elapsed_ms"]

    errors =
      if is_integer(duration) && duration < 0,
        do: ["Recovery precedes first failure for #{id}" | errors],
        else: errors

    {%{
       id: id,
       signature: signature,
       attempt_ids: Enum.sort(ids),
       status: if(recovered, do: "recovered", else: "unresolved"),
       recovery_ms: if(recovered, do: duration),
       censored_after_ms: if(!recovered, do: duration),
       observed_verified_loads: length(verified),
       observed_failed_requests:
         Enum.count(failures, &(!recovered || &1["sequence"] < recovered["sequence"]))
     }, errors}
  end

  defp frequencies(events, type, key),
    do: events |> Enum.filter(&(&1["event"] == type)) |> Enum.frequencies_by(& &1[key])

  defp mean([]), do: nil
  defp mean(values), do: Enum.sum(values) / length(values)
  defp median([]), do: nil

  defp median(values) do
    sorted = Enum.sort(values)
    middle = div(length(sorted), 2)

    if rem(length(sorted), 2) == 1,
      do: Enum.at(sorted, middle),
      else: (Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2
  end

  defp display(nil), do: "n/a"
  defp display(value), do: to_string(value)
end
