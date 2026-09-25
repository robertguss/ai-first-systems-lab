# AI-first systems lab

Experiments in AI-authored software: contracts, supervision, regeneration,
simulation, and human oversight. This repository is a lab, not a language
implementation or a production self-repair platform.

## Experiments

- [01 — The regenerating supervisor](experiments/01-regenerating-supervisor/README.md):
  Elixir/OTP, shipping estimates, fail-fast service, isolated repair proposals,
  independent review, human approval, and hot loading. **Phase 1 / Mode A
  only.**

Each experiment owns its application, contracts, tests, and operating
instructions. Future experiments can live beside it without sharing runtime
dependencies.

## Development environment

The checked-in `.agents/setup` installs Elixir 1.20.4, Erlang/OTP 29.1.1, Claude
Code, and Bubblewrap in an x86-64 Debian 12 orb. Run it from this directory:

```sh
.agents/setup
cd experiments/01-regenerating-supervisor
mix test
python3 -m unittest discover -s scripts -p 'test_*.py' -v
```

No database, web framework, Hex dependency, or Python package is required.
Actual model calls require your own provider credentials; tests do not.
