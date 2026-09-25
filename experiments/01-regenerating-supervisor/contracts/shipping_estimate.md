# ShippingEstimate

## Purpose

Return a deterministic shipping price in USD cents and a transit duration in
business days. This is an estimate, not a purchase or delivery guarantee.

## Requires

Input is a map with string keys: `weight_g` is an integer from 1 through 20,000;
`zone` is `domestic` or `international`; `service` is `standard` or `express`;
`destination` is a nonempty string identifying a destination category.

## Promises

For street destinations, return
`{:ok, %{cents: integer, business_days: integer}}`. Billable kilograms are
weight rounded UP to the next whole kilogram, including any fractional kilogram.
Exactly 1,000 grams is one billable kilogram.

| Zone          | Standard price                   | Standard transit |
| ------------- | -------------------------------- | ---------------- |
| domestic      | 500 + 125 × billable kilograms   | 4 business days  |
| international | 1,500 + 300 × billable kilograms | 9 business days  |

Express adds 900 cents to the standard price and subtracts 2 business days from
the standard transit duration. These promises are checked by executable
examples, not formal proofs. Equal inputs produce equal outputs.

## May use

Integer arithmetic and immutable data only. No clock, randomness, files,
network, process state, payment operations, or other external effects.

## Expected failures

Missing fields, invalid types, weight outside the permitted interval, an unknown
zone or service, or an empty destination → `{:error, :invalid_input}`. These
expected rejections do not raise an operational alarm.

## Precedents

None.
