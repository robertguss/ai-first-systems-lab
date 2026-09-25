defmodule Regenerator.Load do
  use GenServer
  alias Regenerator.Engine

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def stop, do: GenServer.stop(__MODULE__)
  def pause, do: GenServer.call(__MODULE__, {:pause, true})
  def resume, do: GenServer.call(__MODULE__, {:pause, false})

  def sample(random) do
    {weight, random} = choose([1000, 2000, 3000, 1001, 2500], random)
    {zone, random} = choose(["domestic", "domestic", "international"], random)
    {service, random} = choose(["standard", "standard", "express"], random)
    {destination, random} = choose(["street", "street", "street", "po_box"], random)

    {%{"weight_g" => weight, "zone" => zone, "service" => service, "destination" => destination},
     random}
  end

  def init(opts) do
    rate = Keyword.fetch!(opts, :rate)
    seed = Keyword.fetch!(opts, :seed)

    state = %{
      random: :rand.seed_s(:exsss, seed),
      interval: 1000 / rate,
      deadline: System.monotonic_time(:millisecond),
      index: 0,
      paused: false,
      engine: Keyword.get(opts, :engine, Engine)
    }

    Engine.load_event(%{"action" => "start", "rate" => rate, "seed" => seed}, state.engine)
    send(self(), :tick)
    {:ok, state}
  end

  def handle_call({:pause, paused}, _from, state) do
    Engine.load_event(
      %{"action" => if(paused, do: "pause", else: "resume"), "index" => state.index},
      state.engine
    )

    {:reply, :ok, %{state | paused: paused}}
  end

  def handle_info(:tick, %{paused: true} = state) do
    Process.send_after(self(), :tick, max(1, round(state.interval)))
    {:noreply, %{state | deadline: System.monotonic_time(:millisecond)}}
  end

  def handle_info(:tick, state) do
    {input, random} = sample(state.random)
    Engine.quote(input, state.engine)
    deadline = max(state.deadline + state.interval, System.monotonic_time(:millisecond))

    Process.send_after(
      self(),
      :tick,
      max(0, round(deadline - System.monotonic_time(:millisecond)))
    )

    {:noreply, %{state | random: random, deadline: deadline, index: state.index + 1}}
  end

  defp choose(values, random) do
    {index, random} = :rand.uniform_s(length(values), random)
    {Enum.at(values, index - 1), random}
  end
end
