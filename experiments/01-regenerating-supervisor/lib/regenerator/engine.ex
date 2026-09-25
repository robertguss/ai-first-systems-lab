defmodule Regenerator.Engine do
  use GenServer
  alias Regenerator.{Loader, Runner, Store}

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def quote(input, server \\ __MODULE__), do: GenServer.call(server, {:quote, input}, 5_000)
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)
  def cards(server \\ __MODULE__), do: GenServer.call(server, :cards)
  def load_event(data, server \\ __MODULE__), do: GenServer.call(server, {:load_event, data})

  def decide(id, action, actor, detail \\ "", server \\ __MODULE__),
    do: GenServer.call(server, {:decide, id, action, actor, detail})

  def repair(id, server \\ __MODULE__), do: GenServer.call(server, {:repair, id})

  def rule(id, actor, ruling, rationale, server \\ __MODULE__),
    do: GenServer.call(server, {:rule, id, actor, ruling, rationale})

  @impl true
  def init(opts) do
    root = Keyword.get(opts, :root, File.cwd!()) |> Path.expand()
    Code.ensure_loaded!(ShippingEstimate)
    {ShippingEstimate, beam, _} = :code.get_object_code(ShippingEstimate)
    beam = Keyword.get(opts, :initial_beam, beam)
    source = File.read!(Path.join(root, "lib/shipping_estimate.ex"))
    contract = File.read!(Path.join(root, "contracts/shipping_estimate.md"))

    state = %{
      root: root,
      run_dir: Store.create(Keyword.get(opts, :run_root, Path.join(root, "run"))),
      started: System.monotonic_time(:millisecond),
      sequence: 0,
      storage_error: nil,
      version: %{
        beam: beam,
        source: source,
        source_hash: Store.hash(source),
        contract: contract,
        contract_hash: Store.hash(contract)
      },
      previous: nil,
      requests: %{},
      repair_task: nil,
      queue: [],
      cards: %{},
      signatures: %{},
      failed: 0,
      succeeded: 0,
      expected: 0,
      opts: opts,
      threshold: Keyword.get(opts, :threshold, 3),
      window_ms: Keyword.get(opts, :window_ms, 10_000),
      request_timeout: Keyword.get(opts, :request_timeout, 250)
    }

    {:ok,
     Store.event(state, "run_started", %{
       "mode" => "A",
       "scope" => Keyword.get(opts, :scope, "narrow"),
       "threshold" => state.threshold,
       "window_ms" => state.window_ms,
       "source_hash" => state.version.source_hash,
       "contract_hash" => state.version.contract_hash
     })}
  end

  @impl true
  def handle_call({:quote, input}, from, state) do
    if replayable?(input) do
      {:noreply, request(state, input, {:caller, from})}
    else
      state = %{state | expected: state.expected + 1}

      state =
        Store.event(state, "request_completed", %{
          "outcome" => "expected",
          "source_hash" => state.version.source_hash
        })

      {:reply, {:error, :invalid_input}, state}
    end
  end

  def handle_call(:status, _from, state) do
    {:reply,
     Map.take(state, [:run_dir, :failed, :succeeded, :expected, :storage_error])
     |> Map.put(:source_hash, state.version.source_hash), state}
  end

  def handle_call(:cards, _from, state), do: {:reply, state.cards, state}

  def handle_call({:load_event, data}, _from, state),
    do: {:reply, :ok, Store.event(state, "load_generator", data)}

  def handle_call({:repair, id}, _from, state) do
    case state.cards[id] do
      %{status: :alarmed} ->
        {:reply, :ok, enqueue(state, id)}

      %{status: status} = card when status in [:rejected, :repair_failed, :proposed] ->
        {new_id, state} = bundle(state, card.bundle, id)
        {:reply, {:ok, new_id}, enqueue(state, new_id)}

      _ ->
        {:reply, {:error, :not_waiting_for_repair}, state}
    end
  end

  def handle_call({:decide, id, action, actor, detail}, _from, state) do
    case {state.cards[id], action, String.trim(actor) != "", state.storage_error} do
      {%{status: :proposed} = card, :reject, true, nil} ->
        state =
          Store.event(state, "decision", %{
            "id" => id,
            "action" => "reject",
            "actor" => actor,
            "reason" => detail
          })

        {:reply, :ok, put_in(state.cards[id], %{card | status: :rejected})}

      {%{status: :proposed, proposal: %{"kind" => "fix"}} = card, :approve, true, nil} ->
        approve(state, id, card, actor, detail)

      _ ->
        {:reply, {:error, :invalid_decision_or_storage_unavailable}, state}
    end
  end

  def handle_call({:rule, id, actor, ruling, rationale}, _from, state) do
    card = state.cards[id]

    valid =
      card && card.status == :proposed && card.proposal["kind"] == "question" &&
        Loader.review_complete?(card.proposal) &&
        Enum.all?([actor, ruling, rationale], &(is_binary(&1) and String.trim(&1) != "")) &&
        card.bundle["contract_hash"] == state.version.contract_hash && is_nil(state.storage_error) &&
        File.read(Path.join(state.root, "contracts/shipping_estimate.md")) ==
          {:ok, state.version.contract}

    if valid do
      entry =
        "\n### Human ruling #{id}\n\n- Date: #{Store.now()}\n- Actor: #{actor}\n- Scenario: `#{JSON.encode!(card.bundle["input"])}`\n- Ruling: #{ruling}\n- Rationale: #{rationale}\n"

      contract = state.version.contract <> entry

      state =
        Store.event(state, "decision", %{
          "id" => id,
          "action" => "rule",
          "actor" => actor,
          "ruling" => ruling,
          "rationale" => rationale
        })

      if is_nil(state.storage_error) do
        case File.write(Path.join(state.root, "contracts/shipping_estimate.md"), contract, [:sync]) do
          :ok ->
            version = %{state.version | contract: contract, contract_hash: Store.hash(contract)}
            state = %{state | version: version} |> put_in([:cards, id, :status], :ruled)

            state =
              Store.event(state, "contract_ruling", %{
                "id" => id,
                "contract_hash" => version.contract_hash
              })

            {new_id, state} = bundle(state, card.bundle, id)
            {:reply, {:ok, new_id}, enqueue(state, new_id)}

          {:error, reason} ->
            {:reply, {:error, reason}, %{state | storage_error: inspect(reason)}}
        end
      else
        {:reply, {:error, :storage_unavailable}, state}
      end
    else
      {:reply, {:error, :not_a_current_question_or_missing_ruling_details}, state}
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    cond do
      Map.has_key?(state.requests, ref) ->
        Process.demonitor(ref, [:flush])
        {:noreply, finish_request(state, ref, {:ok, result})}

      state.repair_task && state.repair_task.ref == ref ->
        Process.demonitor(ref, [:flush])
        {:noreply, finish_repair(state, result)}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    cond do
      Map.has_key?(state.requests, ref) ->
        {:noreply, finish_request(state, ref, {:crash, reason})}

      state.repair_task && state.repair_task.ref == ref ->
        {:noreply, finish_repair(state, %{"kind" => "failed", "error" => inspect(reason)})}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:request_timeout, ref}, state) do
    case state.requests[ref] do
      nil ->
        {:noreply, state}

      request ->
        Process.exit(request.pid, :kill)
        Process.demonitor(ref, [:flush])
        {:noreply, finish_request(state, ref, {:crash, :request_timeout})}
    end
  end

  defp request(state, input, recipient) do
    task =
      Task.Supervisor.async_nolink(Regenerator.Requests, ShippingEstimate, :estimate, [input])

    timer = Process.send_after(self(), {:request_timeout, task.ref}, state.request_timeout)

    request = %{
      input: input,
      recipient: recipient,
      pid: task.pid,
      timer: timer,
      version: state.version
    }

    put_in(state.requests[task.ref], request)
  end

  defp replayable?(input) when is_map(input) do
    JSON.decode!(JSON.encode!(input)) === input
  rescue
    _ -> false
  end

  defp replayable?(_), do: false

  defp finish_request(state, ref, result) do
    {request, requests} = Map.pop(state.requests, ref)
    Process.cancel_timer(request.timer)
    state = %{state | requests: requests}

    case request.recipient do
      {:caller, from} ->
        case result do
          {:ok, value} ->
            GenServer.reply(from, value)
            key = if match?({:error, _}, value), do: :expected, else: :succeeded
            state = Map.update!(state, key, &(&1 + 1))

            Store.event(state, "request_completed", %{
              "outcome" => Atom.to_string(key),
              "source_hash" => request.version.source_hash
            })

          {:crash, reason} ->
            GenServer.reply(from, {:error, :unavailable})
            failure(state, request, reason)
        end

      {:verify, id} ->
        card = state.cards[id]

        verified =
          case result do
            {:ok, value} -> inspect(value, limit: :infinity) == card.proposal["probe_result"]
            _ -> false
          end

        status = if verified, do: :loaded, else: :verification_failed
        state = put_in(state.cards[id].status, status)

        Store.event(state, "load_verified", %{
          "id" => id,
          "verified" => verified,
          "result" => inspect(result),
          "source_hash" => state.version.source_hash,
          "failed_requests_total" => state.failed
        })
    end
  end

  defp failure(state, request, reason) do
    {exception, stack} =
      case reason do
        {exception, stack} when is_list(stack) -> {exception, stack}
        other -> {other, []}
      end

    location = Enum.find(stack, fn {module, _, _, _} -> module == ShippingEstimate end)

    location =
      case location do
        {module, function, args, _} ->
          {module, function, if(is_list(args), do: length(args), else: args)}

        nil ->
          :unknown
      end

    type = if is_map(exception), do: Map.get(exception, :__struct__, :error), else: exception
    signature = Store.hash(:erlang.term_to_binary({request.version.source_hash, type, location}))
    now = System.monotonic_time(:millisecond)

    previous =
      Map.get(state.signatures, signature, %{
        times: [],
        alarmed: false,
        first: Store.now(),
        failed: 0
      })

    occurrence = %{
      previous
      | times:
          [now | Enum.filter(previous.times, &(now - &1 <= state.window_ms))]
          |> Enum.take(state.threshold),
        failed: previous.failed + 1
    }

    state = %{state | failed: state.failed + 1} |> put_in([:signatures, signature], occurrence)

    state =
      Store.event(state, "request_failed", %{
        "signature" => signature,
        "source_hash" => request.version.source_hash,
        "failed_requests_total" => state.failed,
        "signature_failed_requests" => occurrence.failed
      })

    if length(occurrence.times) >= state.threshold && !occurrence.alarmed do
      state = put_in(state.signatures[signature].alarmed, true)

      evidence = %{
        "signature" => signature,
        "reason" => Exception.format_banner(:error, exception),
        "stacktrace" => Exception.format_stacktrace(stack),
        "input" => request.input,
        "first_failure_at" => occurrence.first
      }

      state =
        Store.event(state, "alarm", %{
          "signature" => signature,
          "first_failure_at" => occurrence.first,
          "failed_requests_total" => state.failed
        })

      {id, state} = bundle(state, evidence, nil, request.version)
      if Keyword.get(state.opts, :auto_repair, false), do: enqueue(state, id), else: state
    else
      state
    end
  end

  defp bundle(state, evidence, parent, version \\ nil) do
    version = version || state.version
    id = Store.id()

    data =
      Map.merge(evidence, %{
        "id" => id,
        "timestamp" => Store.now(),
        "parent_id" => parent,
        "source" => version.source,
        "contract" => version.contract,
        "source_hash" => version.source_hash,
        "contract_hash" => version.contract_hash
      })

    path = Path.join(state.run_dir, "#{id}.bundle.json")

    case Store.write_new(path, data) do
      :ok ->
        card = %{
          status: :alarmed,
          bundle: data,
          bundle_path: path,
          proposal: nil,
          output: Path.join(state.run_dir, id)
        }

        state = put_in(state.cards[id], card)
        {id, Store.event(state, "bundle", %{"id" => id, "path" => path, "parent_id" => parent})}

      {:error, reason} ->
        {nil, %{state | storage_error: inspect(reason)}}
    end
  end

  defp enqueue(state, nil), do: state

  defp enqueue(state, id) do
    state = put_in(state.cards[id].status, :queued)
    dispatch(%{state | queue: state.queue ++ [id]})
  end

  defp dispatch(%{repair_task: nil, queue: [id | rest]} = state) do
    card = state.cards[id]
    runner = Keyword.get(state.opts, :runner, &Runner.run/4)

    task =
      Task.Supervisor.async_nolink(Regenerator.Repairs, fn ->
        runner.(state.root, card.bundle_path, card.output, state.opts)
      end)

    state = %{state | repair_task: %{ref: task.ref, id: id}, queue: rest}
    state = put_in(state.cards[id].status, :repairing)
    Store.event(state, "regeneration_started", %{"id" => id})
  end

  defp dispatch(state), do: state

  defp finish_repair(state, result) do
    id = state.repair_task.id

    result =
      if is_map(result),
        do: result,
        else: %{"kind" => "failed", "error" => "Invalid runner response"}

    status = if result["kind"] in ["fix", "question"], do: :proposed, else: :repair_failed
    state = put_in(state.cards[id].proposal, result) |> put_in([:cards, id, :status], status)

    state =
      Store.event(state, "proposal", %{
        "id" => id,
        "kind" => result["kind"],
        "output" => state.cards[id].output,
        "error" => result["error"]
      })

    state =
      Store.event(state, "review", %{
        "id" => id,
        "review" => result["review"] || %{"status" => "skipped", "verdict" => "Not run"}
      })

    dispatch(%{state | repair_task: nil})
  end

  defp approve(state, id, card, actor, detail) do
    if map_size(state.requests) > 0 do
      {:reply, {:error, :requests_in_flight_retry}, state}
    else
      case Loader.candidate(card.output, card.proposal, state.version) do
        {:ok, candidate} ->
          if Loader.review_dissent?(card.proposal) && String.trim(detail) == "" do
            {:reply, {:error, :reviewer_dissent_requires_reason}, state}
          else
            load_approved(state, id, card, candidate, actor, detail)
          end

        error ->
          {:reply, error, state}
      end
    end
  end

  defp load_approved(state, id, card, candidate, actor, detail) do
    state =
      Store.event(state, "decision", %{
        "id" => id,
        "action" => "approve",
        "actor" => actor,
        "reason" => detail,
        "candidate_hash" => card.proposal["candidate_hash"]
      })

    if is_nil(state.storage_error) do
      # Retain exact bytes; code.get_object_code/1 may point to the baseline on disk.
      prior_path = Path.join(state.run_dir, "#{id}.previous.beam")

      with :ok <- File.write(prior_path, state.version.beam, [:exclusive, :sync]),
           :ok <- Loader.load(candidate) do
        state =
          %{state | previous: state.version, version: candidate}
          |> put_in([:cards, id, :status], :verifying)

        state =
          Store.event(state, "load", %{
            "id" => id,
            "candidate_hash" => card.proposal["candidate_hash"],
            "previous_path" => prior_path,
            "app_pid" => inspect(Process.whereis(Regenerator.Supervisor))
          })

        {:reply, {:ok, :verifying}, request(state, card.bundle["input"], {:verify, id})}
      else
        error ->
          {:reply, error,
           Store.event(state, "load_failed", %{"id" => id, "reason" => inspect(error)})}
      end
    else
      {:reply, {:error, :storage_unavailable}, state}
    end
  end
end
