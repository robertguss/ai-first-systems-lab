# Operator-only audit. Never include this file in an agent workspace.
alias Regenerator.Engine
Logger.configure(level: :critical)
manifest = File.read!("experiment/secret/manifest.json") |> JSON.decode!()
supervisor = Process.whereis(Regenerator.Supervisor)

for failure <- manifest["failures"] do
  for _ <- 1..3 do
    {:error, :unavailable} = Engine.quote(failure["input"])
  end
end

cards = Engine.cards()
4 = map_size(cards)
12 = Engine.status().failed
^supervisor = Process.whereis(Regenerator.Supervisor)
{:ok, %{cents: 875, business_days: 4}} = Engine.quote(%{"weight_g" => 3000, "zone" => "domestic", "service" => "standard", "destination" => "street"})
for {_, card} <- cards do
  :alarmed = card.status
  true = File.exists?(card.bundle_path)
end
IO.puts("4/4 incidents alarmed; 12 failed requests; healthy request succeeded; supervisor unchanged; no repair invoked.")
