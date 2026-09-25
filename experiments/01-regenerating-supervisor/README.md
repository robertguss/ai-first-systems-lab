# Experiment 1 — The regenerating supervisor

**Phase 1 only:** a reversible shipping calculator, Mode A (fail fast and wait
for human approval). No language, Mode B, refund processor, offline replay
tournament, decoys, or review-batch study is implemented.

The experiment has three module-local implementation defects and one missing
contract policy. Ground truth and an operator-only detection audit live under
`experiment/secret/`. Do not give that directory or this README to a repair or
review agent. The baseline tests intentionally cover only established examples;
passing them does not mean the entire shipping contract is implemented.

## Run

Requirements: Linux with unprivileged user/mount/PID/network namespaces,
Bubblewrap, Python 3.11+, Elixir 1.20.4 / OTP 29.1.1, and Claude Code. The
repository-root `.agents/setup` provides the tested Debian 12 x86-64 setup.
Other installations must place sandbox-visible tools beneath
`/opt/regenerator-tools/bin` (or use distribution tools under `/usr/bin`). Host
`/usr/local` and HOME are deliberately invisible to the agent.

From this experiment directory:

```sh
mix test
python3 -m unittest discover -s scripts -p 'test_*.py' -v

# Detection and CLI only, without a model or model charges:
mix run --no-start -e 'Regenerator.CLI.main(System.argv())' -- \
  --no-auto-repair --rate 10 --seed 42 --actor robert

# Normal run: configure ANTHROPIC_API_KEY securely in your environment first.
# The runner forwards only this provider key, not your general environment.
mix run --no-start -e 'Regenerator.CLI.main(System.argv())' -- \
  --rate 10 --seed 42 --actor robert
```

Use a foreground terminal for the interactive CLI. In an Amp orb, use the
Terminal tab. For unattended load without a CLI, use a supervised orb service:

```sh
amp orb service start shipping-load --command \
  "mix run --no-halt -e 'Regenerator.Load.start_link(rate: 10, seed: 42)'"
amp orb service logs shipping-load
amp orb service stop shipping-load
```

That unattended command records alarms only: automatic repair is enabled by the
interactive CLI, not by the application default. There is no web server or
portal.

### Commands and cards

- `status` — run directory, failed/successful/expected-rejection counts, storage
  health.
- `list` — incident IDs and states. Nothing is approved automatically.
- `show ID` — what broke, input scenario, proposed behavior, test output,
  independent review verdict, and artifact location. Questions show their
  proposed options.
- `repair ID` — invoke repair manually. For failed/rejected/stale proposals,
  create a new linked attempt with a new bundle; never overwrite the old
  evidence.
- `approve ID` — approve a tested fix. An in-flight request can cause a
  retryable busy response; retry, or briefly `pause` load. Check `show ID` for
  `loaded` after live verification, not merely `verifying`.
- `approve ID reason` — record why you override an independent reviewer’s reject
  or question verdict. Failed/malformed configured reviews cannot be approved.
- `reject ID reason` — retain the failure and record the rejection.
- `rule ID {"ruling":"...","rationale":"..."}` — resolve a question, appending
  the actor, date, concrete scenario, ruling, and rationale to the contract’s
  precedents. This starts a **new** repair attempt. It does not approve its
  code.
- `pause`, `resume` — preserve the seeded input sequence while pausing arrivals.
- `quit` — end the run. Runtime hot loads are not written into the baseline
  source.

Do not hand-edit the contract during a run: use `rule`. External edits cause
rulings to fail rather than overwrite unseen work. The human chooses the ruling;
the runner never consults the hidden manifest to supply a policy or classify a
gap.

### Agent configuration

Default regeneration uses Claude Code headless inside an OS sandbox. To choose
models/commands, supply JSON argv arrays (no shell evaluation):

```sh
export REGEN_AGENT_COMMAND='["claude","--print","--bare","--model","sonnet","--permission-mode","bypassPermissions","--no-session-persistence"]'
export REGEN_REVIEWER_COMMAND='["claude","--print","--bare","--model","opus","--permission-mode","bypassPermissions","--no-session-persistence"]'
```

The stage prompt is appended as the final argument. Use genuinely different
models for meaningful independent review. With no reviewer command, the card
explicitly says review was skipped. Builder transcripts and behavior
descriptions are not given to the reviewer. Original builder responses survive
reviewer dissent; reviewer corrections do not turn a builder’s invented policy
into successful gap escalation.

`--scope narrow` is the Phase 1 default. `--scope broad` is available for later
work, but does not run an offline replay study. Broad means the experiment
project minus explicit exclusions, including all git metadata, operator
documents, orchestration scripts, secret manifests, runtime data, dependencies,
dotfiles, instruction files, and symlinks. See
[runner protocol and isolation](scripts/README.md) for standalone invocation,
provider allowlists, limits, and the proposal schema.

## How the running application survives

`Regenerator.Supervisor` supervises separate request and repair task supervisors
and `Regenerator.Engine`. Every shipping call uses a fresh temporary, monitored,
unlinked task. A crashed invocation is not retried indefinitely; the next
request gets a fresh process. This uses the spec’s **crash-signature tracker**
alternative instead of intentionally exhausting the application’s restart
budget.

The Engine groups exception type and shipping stack location by source version.
Three occurrences in ten seconds raise one alarm per signature/version. The
threshold is configurable with `--threshold`; `window_ms` and request timeout
(250 ms) are application options. Expected invalid-input rejections do not
alarm. The ingress API accepts JSON-replayable maps and rejects unsupported
terms. `Regenerator.Engine.quote(input)` returns a quote,
`{:error, :invalid_input}`, or `{:error, :unavailable}`. Repair never holds an
affected request open.

Repair tasks run separately and serially, while requests continue. A failed
command, missing credential, timeout, invalid proposal, or reviewer failure
becomes an escalation outcome, not a supervisor restart. Rate is a target
request rate, not a promise under host saturation; seed fixes input ordering,
not thread scheduling or model output. Pauses and load parameters are logged.

## Evidence, approval, and hot loading

Each run creates a new `run/<run-id>/` directory:

- `events.jsonl`: append-only events with UTC timestamp, monotonic elapsed time,
  sequence, run ID, alarms, bundles, proposals, reviews, decisions, loads,
  verified results, and per-signature/total failed-request counts.
- `<incident-id>.bundle.json`: immutable input, reason, stacktrace, timestamp,
  first-failure time, source, contract, version hashes, and parent-attempt
  linkage.
- `<incident-id>/`: raw builder responses, change sets, patch, reproduction
  test, mechanically captured test results, review, candidate source/BEAM and
  hashes.
- `<incident-id>.previous.beam`: exact pre-load bytecode, also retained in
  memory.

The runner enforces a two-stage protocol: a failing ExUnit reproduction against
unchanged code **before** allowing a source edit, then unchanged reproduction
plus all existing module tests against the candidate. It also runs the full
project suite in a separate host-controlled sandbox without widening agent
context. Compiler errors are not accepted as reproduction. All compilation and
generated test execution happen outside the running VM, with no network or
credentials.

Approval verifies the source/contract versions and candidate bytes. Stale or
tampered proposals cannot load. Only `ShippingEstimate` may be loaded, and
`on_load` callbacks are rejected. The controller checks for old-code users
before loading: it never brutally purges a process to make room. After loading,
a fresh live request must equal the candidate’s independently captured probe
result. The card becomes `loaded` only after this comparison. Verification
failure is recorded explicitly; Phase 1 does **not** implement automatic
rollback.

The BEAM provides two code generations, not a callable rollback API. The prior
version’s exact bytes are retained for swap-back; `Regenerator.Loader.load/1` is
the low-level tested primitive. There is no Mode B provisional-state manager or
automatic swap-back policy yet.

For measures, join a successful `load_verified` to its bundle ID (following
`parent_id` for ruling/retry attempts). Recovery time is verification time minus
the original `first_failure_at`; `request_failed` events between those points
give failed requests. Signature counts isolate the affected failure; global
counts include other simultaneous incidents. Unresolved cases are censored, not
zero-time recoveries. Keep the whole run directory for later replay.

These are append-only application writes, not tamper-proof storage against the
host operator. Storage errors remain visible and prevent unlogged approvals;
requests continue, but metrics are incomplete from that point. Run on disposable
local data. Restarting the VM starts a new run with baseline code; runtime state
is not recovered from the audit log. Human contract rulings persist in the
contract file, so preserve a fresh checkout if you want a fresh baseline trial.

## Verification and limitations

```sh
mix format --check-formatted
mix test
python3 -m unittest discover -s scripts -p 'test_*.py' -v
# Operator-only: verifies alarms without invoking or approving any repair.
mix run experiment/secret/audit.exs
```

Controller tests use unrelated arithmetic fixtures for approval, refusal, hot
loading, swap-back bytes, timeouts, gap rulings, stale versions, and failed
storage. Runner tests use synthetic agents with real Bubblewrap and real Elixir
compilation. They are infrastructure evidence, not evidence of any model’s
repair quality. The planted shipping failures remain unfixed.

The Elixir application has no dependencies; a Python-stdlib/Bubblewrap runner is
the deliberate stack addition for OS isolation and a provider-only HTTPS proxy.
It is Linux-only and fails closed if isolation is unavailable. This prevents
agents reading the live checkout or reaching the VM; a copied directory alone
would not. The approved module still runs with BEAM privileges: the human
approval gate stands in for a capability system. This is not a hostile-code
production VM.

Before Phase 2, choose the provisional-fix observation window, rollback criteria
and scope, and how to count harm/recovery across rollback. Also choose a
reviewer model and run real authenticated Phase 1 trials. Do not infer Mode B
safety or human review quality from these infrastructure tests.
