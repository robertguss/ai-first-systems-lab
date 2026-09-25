defmodule ShippingEstimate do
  @moduledoc "Deterministic shipping quotations."

  def estimate(%{
        "weight_g" => weight,
        "zone" => zone,
        "service" => service,
        "destination" => destination
      })
      when is_integer(weight) and weight >= 1 and weight <= 20_000 and
             zone in ["domestic", "international"] and service in ["standard", "express"] and
             is_binary(destination) and byte_size(destination) > 0 do
    price(weight, zone, service, destination)
  end

  def estimate(_), do: {:error, :invalid_input}

  defp price(weight, zone, service, "street") do
    kilograms = whole_kilograms(weight, rem(weight, 1000))
    {base, per_kg, days} = tariff(zone)
    {surcharge, reduction} = delivery(service)
    {:ok, %{cents: base + per_kg * kilograms + surcharge, business_days: days - reduction}}
  end

  defp whole_kilograms(weight, 0), do: div(weight, 1000)
  defp tariff("domestic"), do: {500, 125, 4}
  defp delivery("standard"), do: {0, 0}
end
