defmodule Regenerator.LoadTest do
  use ExUnit.Case, async: true

  defp inputs(seed) do
    Enum.map_reduce(1..100, :rand.seed_s(:exsss, seed), fn _, state ->
      Regenerator.Load.sample(state)
    end)
    |> elem(0)
  end

  test "same seed replays the input stream; distinct seeds change ordering" do
    assert inputs(73) == inputs(73)
    refute inputs(73) == inputs(74)
    assert length(Enum.uniq(inputs(73))) > 20
  end
end
