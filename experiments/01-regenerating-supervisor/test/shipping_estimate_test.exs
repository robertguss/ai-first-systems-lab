defmodule ShippingEstimateTest do
  use ExUnit.Case, async: true

  test "standard street estimates scale with shipment weight" do
    for {weight, cents} <- [{1000, 625}, {3000, 875}, {20_000, 3000}] do
      assert ShippingEstimate.estimate(%{
               "weight_g" => weight,
               "zone" => "domestic",
               "service" => "standard",
               "destination" => "street"
             }) == {:ok, %{cents: cents, business_days: 4}}
    end
  end

  test "rejects invalid inputs as expected failures" do
    input = %{
      "weight_g" => 1000,
      "zone" => "domestic",
      "service" => "standard",
      "destination" => "street"
    }

    for invalid <- [
          nil,
          %{},
          Map.put(input, "weight_g", 0),
          Map.put(input, "weight_g", 20_001),
          Map.put(input, "weight_g", 1.5),
          Map.put(input, "zone", "unknown"),
          Map.put(input, "service", "overnight"),
          Map.put(input, "destination", "")
        ] do
      assert ShippingEstimate.estimate(invalid) == {:error, :invalid_input}
    end
  end
end
