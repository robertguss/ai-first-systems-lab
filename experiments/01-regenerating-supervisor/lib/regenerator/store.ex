defmodule Regenerator.Store do
  @moduledoc false

  def id, do: Base.encode16(:crypto.strong_rand_bytes(10), case: :lower)
  def hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  def now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  def create(root) do
    path = Path.join(root, id())
    File.mkdir_p!(path)
    path
  end

  def write_new(path, data), do: File.write(path, JSON.encode!(data) <> "\n", [:exclusive, :sync])

  def event(state, type, data \\ %{}) do
    record =
      Map.merge(data, %{
        "event" => type,
        "timestamp" => now(),
        "elapsed_ms" => System.monotonic_time(:millisecond) - state.started,
        "sequence" => state.sequence + 1,
        "run_id" => Path.basename(state.run_dir)
      })

    case File.write(Path.join(state.run_dir, "events.jsonl"), JSON.encode!(record) <> "\n", [
           :append,
           :sync
         ]) do
      :ok -> %{state | sequence: state.sequence + 1}
      {:error, reason} -> %{state | storage_error: inspect(reason)}
    end
  end
end
