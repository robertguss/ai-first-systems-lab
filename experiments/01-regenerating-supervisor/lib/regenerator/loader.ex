defmodule Regenerator.Loader do
  @moduledoc false
  alias Regenerator.Store

  def candidate(directory, proposal, version) do
    with true <- proposal["kind"] == "fix",
         true <- review_complete?(proposal),
         true <- is_binary(proposal["probe_result"]) and proposal["probe_result"] != "",
         true <- get_in(proposal, ["tests", "passed"]) == true,
         true <- get_in(proposal, ["tests", "reproduction_failed"]) == true,
         true <- proposal["base_source_hash"] == version.source_hash,
         true <- proposal["base_contract_hash"] == version.contract_hash,
         {:ok, beam} <- File.read(Path.join(directory, "candidate.beam")),
         {:ok, source} <- File.read(Path.join(directory, "candidate.ex")),
         true <- Store.hash(beam) == proposal["candidate_hash"],
         true <- Store.hash(source) == proposal["candidate_source_hash"],
         {:ok, {ShippingEstimate, chunks}} <- :beam_lib.chunks(beam, [:exports, :attributes]),
         true <- {:estimate, 1} in chunks[:exports],
         false <- Keyword.has_key?(chunks[:attributes], :on_load),
         {:ok, ast} <- Code.string_to_quoted(source),
         false <- on_load?(ast) do
      {:ok, %{version | beam: beam, source: source, source_hash: Store.hash(source)}}
    else
      _ -> {:error, :invalid_or_stale_proposal}
    end
  rescue
    _ -> {:error, :invalid_or_stale_proposal}
  end

  def review_complete?(%{"review" => %{"status" => "skipped"}}), do: true

  def review_complete?(%{"review" => %{"status" => "completed", "verdict" => verdict}}),
    do: verdict in ["accept", "reject", "question"]

  def review_complete?(_), do: false

  def review_dissent?(proposal) do
    get_in(proposal, ["review", "status"]) == "completed" &&
      get_in(proposal, ["review", "verdict"]) in ["reject", "question"]
  end

  def load(version) do
    # A third generation must never kill requests still executing old code.
    if :code.soft_purge(ShippingEstimate) do
      case :code.load_binary(ShippingEstimate, ~c"approved-shipping-estimate", version.beam) do
        {:module, ShippingEstimate} -> :ok
        error -> {:error, inspect(error)}
      end
    else
      {:error, :old_code_in_use}
    end
  end

  defp on_load?(ast) do
    {_ast, found} =
      Macro.prewalk(ast, false, fn
        {:@, _, [{:on_load, _, _}]} = node, _ -> {node, true}
        node, found -> {node, found}
      end)

    found
  end
end
