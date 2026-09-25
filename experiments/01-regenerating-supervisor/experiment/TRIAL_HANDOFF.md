# Phase 1 trial-agent handoff

**Operator-only. Never give this file to the regeneration or review model.** It
lives under `experiment/`, which both agent context scopes exclude.

## Paste this prompt into the trial agent

```text
You are the trial operator for ai-first-systems-lab Experiment 1, Phase 1:
the regenerating supervisor, Mode A, reversible shipping calculator.

Read experiments/01-regenerating-supervisor/experiment/TRIAL_HANDOFF.md in full,
then follow its preparation, human gates, execution, and archival procedures.
Repository: https://github.com/robertguss/ai-first-systems-lab

Your role is to operate and document trials, not to repair the calculator.
Run the no-model preflight first. Before paid calls, ask the owner to confirm
the trial plan, models, reviewer choice, budget, retry limits, time limits,
and stopping/pausing rules. Do not turn suggested settings into an approved
experimental protocol. Do not run Phase 2 or later work.

Use only the provided sandbox runner for regeneration and independent review.
Never give those models the original checkout, history, operator instructions,
run archives, or secret manifest. Do not inspect the ground-truth manifest to
choose incidents or coach repairs. Never fix planted failures yourself or
silently alter contracts, tests, prompts, runner limits, or isolation.

Explicit human approval is required for each code load, rejection decision,
contract ruling, and override of reviewer dissent. Show the actual card and
evidence, relay the human's decision faithfully, and record the real human
actor. Running trials is not permission to approve proposals on their behalf.
A contract ruling starts a new paid repair; get authorization for that too.

Never print or archive credentials. Do not run models outside the sandbox to
work around authentication or network errors. Do not use --bare with OAuth.
Keep unsuccessful attempts and interrupted runs; never restart a run and
describe it as a continuation of the same VM. Preserve evidence before doing
anything that could replace a checkout or contract.

At completion, summarize every attempted run, including authentication and
infrastructure failures. Distinguish mechanically verified live loads from
semantic correctness and from sustained recovery. Give the owner artifact
locations, warnings, costs when available, and unresolved decisions. Stop at
Phase 1; do not commit or push trial artifacts or deploy anything.
```

## State you are inheriting

- The implemented runtime baseline is commit
  [`daf5346ca97a90527ef791c07346ec8fe2c5c5ca`](https://github.com/robertguss/ai-first-systems-lab/commit/daf5346ca97a90527ef791c07346ec8fe2c5c5ca).
  This includes the OAuth fix and read-only results summarizer. Pin this
  revision for the first cohort unless the owner chooses another baseline. The
  handoff may arrive in a later documentation commit or as a separate file.
- Infrastructure checks passed here: 22 ExUnit tests and 23 Python tests with
  real Bubblewrap, including synthetic controller-to-runner-to-hot-load tests.
  Rerun them on the trial machine; these results are not portable proof.
- **No successful real-model repair trial has been completed.** An earlier OAuth
  attempt failed with HTTP 401 / invalid bearer token. Do not assume a newly
  supplied credential is valid or repeat that failed attempt indefinitely.
- Only Phase 1 exists. The shipping module is stateless; ordinary requests run
  in temporary isolated tasks. A mechanical signature tracker raises alarms.
  Three implementation defects and one policy gap remain intentionally present.
  Their locations are not in this document. Baseline passing tests do not prove
  full contract compliance.
- Agents only propose. The host requires a reproducer against unchanged source,
  then a fix preserving that reproducer, module/full-project tests, validated
  candidate bytes, human approval, and exact live-probe comparison.
- Contract silence requires a human question, not invented policy. A ruling
  changes the contract on disk and starts another attempt. That attempt requires
  a separate code approval. Runtime fixes do not update baseline source files.
- Independent review is configurable; skipped review is allowed but must be
  reported. Failed/malformed configured review blocks approval. Valid reviewer
  dissent requires a human override reason, not an automatic veto or approval.

Read the experiment `README.md` and `scripts/README.md` for the complete
runtime/runner protocol. Do not forward either to the models. No web app,
database, payment processor, or deployment is involved.

## Decisions required before paid trials

Ask the owner for one explicit plan and record it before execution:

1. Builder and reviewer model IDs and argv; or an explicit choice to skip
   independent review. Prefer exact available model IDs. If aliases such as
   `sonnet`/`opus` are used, record that fact and any resolved IDs available
   from provider evidence; do not guess versions.
2. Spending cap, who monitors provider usage, and maximum repair attempts. The
   CLI has **no aggregate cost/attempt cap**. A repair may make two builder
   calls plus a reviewer call. `rule` and `repair` can incur more calls.
3. Number of measured trials, rate, seed(s), detection threshold, and whether
   measured trials use automatic or manually dispatched regeneration. Suggested
   starting settings are rate 10, seed 42, threshold 3, narrow context; they are
   not a statistical study design. Keep the smoke test separate from the cohort.
4. Wall-clock observation deadline, retries allowed per incident, and the
   stopping rule. Record whether time awaiting the human remains part of the
   observation window and what happens if the human is unavailable.
5. Pause policy, human availability, incident-selection order, and treatment of
   stale proposals after a different fix loads. Do not choose only easy cases or
   omit failures from results. A stable selection order can be chosen without
   looking at hidden ground truth.
6. Whether each trial resets all contract rulings or intentionally starts from
   an agreed ruled contract. Fresh baseline trials must use fresh checkouts.
   Decisions about a gap belong to the owner, never the trial agent.

Do not start paid runs while these choices are unresolved. No software-enforced
hard budget should be claimed. The default per-invocation runner timeout is 180
seconds, not a whole-trial deadline; the interactive CLI does not expose a
timeout option. Do not silently change that limit after seeing outcomes.

## Machine preparation and fresh baselines

Use a disposable **Linux** host/VM with working unprivileged user, mount, PID,
and network namespaces. macOS alone is not supported; containers may deny
Bubblewrap even when the executable is installed. Do not disable isolation.

The tested versions are Elixir 1.20.4, OTP 29.1.1, Python 3.11+, Bubblewrap
0.8.0, and Claude Code 2.1.282. Mix has no external dependencies; the runner
uses the Python standard library. Tools used inside the sandbox must resolve
under `/usr/bin` or `/opt/regenerator-tools`; `/usr/local` is masked. Node and
toolchain symlink targets must also be sandbox-visible.

Repository `.agents/setup` describes the tested Debian 12 x86-64 installation.
It downloads toolchains and Claude Code, uses sudo, and changes tool symlinks.
Inspect it and get permission before running it on a non-disposable/shared
machine. Do not assume it supports another CPU architecture or distribution.

After cloning the repository, create a new detached worktree for **each** trial
(including a separate smoke-test worktree). From the repository root:

```sh
BASELINE=daf5346ca97a90527ef791c07346ec8fe2c5c5ca
# Set this to a new absolute sibling directory, not an existing checkout.
TRIAL_DIR=/absolute/path/to/trial-001
git worktree add --detach "$TRIAL_DIR" "$BASELINE"
```

If the commit is missing in a shallow clone, fetch it from origin first. Never
use `reset --hard`, `clean`, or `restore` to prepare a reused checkout
containing evidence. Keep finished worktrees until archival has been checked. A
new VM starts a new run: the controller does not resume an old run from its
JSONL log.

Run the commands below from `$TRIAL_DIR/experiments/01-regenerating-supervisor`.
Keep operator notes, logs, and exports in `experiment/secret/trials/` (excluded
from agent context), or outside the repository entirely. Do not add a top-level
trial-notes file that could enter broad context later. Never put credentials in
these directories.

## No-model preflight

These commands test infrastructure, not authentication or model quality:

```sh
git rev-parse HEAD
git status --short
elixir --version
python3 --version
bwrap --version
claude --version
mix format --check-formatted
mix test
python3 -m unittest discover -s scripts -p 'test_*.py' -v
python3 scripts/repair.py --help
mix compile
```

Require all tests to pass with **zero skipped tests**, particularly the real
namespace and runner integration tests. A missing Bubblewrap installation can
cause skipped tests rather than a failing suite. Save the logs and actual
versions. Do not dump `env`, shell tracing, authentication files, or tokens.

For a no-model detection smoke test, start the CLI below, allow load for several
seconds, inspect `status`, `list`, and `show ID`, then `pause` and `quit`:

```sh
mix run --no-start -e 'Regenerator.CLI.main(System.argv())' -- \
  --no-auto-repair --scope narrow --rate 10 --seed 42 --threshold 3 --actor robert
```

Use the actual human actor rather than `robert` if someone else owns decisions.
Record the printed run path; summarize it using the archival commands below.
Require nil `storage_error`, failed requests and alarms, and continuing healthy
requests while incidents remain unresolved. Do not invoke `repair`, `rule`, or
approval in this no-model check. This run is preflight, not a measured trial.

## Configure authentication without exposing credentials

Have the owner inject either `CLAUDE_CODE_OAUTH_TOKEN` (subscription token from
`claude setup-token`) or `ANTHROPIC_API_KEY` securely. No raw credential should
appear in chat, shell command arguments/history, transcripts, or the record. If
both are present, OAuth takes precedence; an invalid OAuth value masks a valid
API key. Inspect variable **presence only**, not contents. Login files in host
HOME are intentionally not visible inside the sandbox.

Explicit command configuration, after confirming model choices:

```sh
export REGEN_AGENT_COMMAND='["claude","--print","--model","sonnet","--permission-mode","bypassPermissions","--no-session-persistence"]'
export REGEN_REVIEWER_COMMAND='["claude","--print","--model","opus","--permission-mode","bypassPermissions","--no-session-persistence"]'
# Only if the owner chose no reviewer:
# unset REGEN_REVIEWER_COMMAND
```

Replace these aliases with agreed model IDs where available. Do not append a
custom prompt: the runner supplies the stage prompt. Do not add `--bare` for
OAuth. Bypass-permissions mode is confined by Bubblewrap, not an excuse to run
the command on the original checkout. Network access is limited to proxy CONNECT
to `api.anthropic.com:443`; tests/probes have neither credentials nor network.
Do not expand provider destinations without review and permission.

## First paid smoke test: one controlled repair

Use a fresh smoke worktree and the **same `--no-auto-repair` command** above. It
suppresses automatic repair, but explicit `repair ID` still invokes a model.
Leave load running while waiting unless the agreed pause policy says otherwise.

1. Record `status` and `list`, select an incident by the agreed rule, and show
   its card. Record the run/incident ID, configuration, and start time.
2. With paid-call authorization, issue `repair ID` once. Poll `list`/`show ID`
   until a proposal/question or failure is available; do not submit duplicate
   repairs while one is running. The runner is serial even with multiple alarms.
3. If authentication fails, archive the failure and stop paid work. Ask the
   owner to correct credentials. Do not repeatedly retry, silently switch auth,
   or bypass the proxy. A 401 is not evidence about model repair quality.
4. Show the human the complete card and relevant patch/test artifacts. Passing
   tests do not authorize a load. For a fix, wait for a concrete approve/reject
   instruction. For a question, show its options without choosing policy.
5. Relay an authorized decision with `approve ID`, `reject ID reason`, or
   `approve ID human-override-reason` when the reviewer dissents. A question
   requires `rule ID {"ruling":"HUMAN TEXT","rationale":"HUMAN REASON"}`; this
   writes the contract and invokes another repair even in manual mode. Confirm
   that additional work is within the approved call budget first.
6. After approval, wait for `loaded` and `load_verified` with `verified: true`.
   `{:ok, :verifying}` is not success. On busy, retry per the agreed policy; any
   pause must be logged. A stale proposal must be regenerated through the
   controller, not patched manually or approved around the hash checks.
7. Verify `status` remains accessible, `storage_error` is nil, and ordinary
   successful requests continue. Record failed verification explicitly; Phase 1
   does not automatically roll back. Never manually hot-load code to turn a
   failed trial into a success.
8. Before `quit`, check there is no still-running repair and collect final
   status/cards. `pause` stops arrivals, **not queued/running repairs**. If the
   deadline interrupts work, record interruption and preserve partial artifacts;
   do not claim all requests were drained or all child processes stopped merely
   because the CLI exited. Confirm process exit using the host's process tools
   without printing full command lines that might contain sensitive arguments.

If the first incident is a question, do not hunt for an easier incident and
report the smoke as a successful fix. Record what actually happened; ask the
owner whether a second smoke attempt is authorized.

## Measured trials

Only start after smoke results and the cohort plan are accepted. In a fresh
worktree per trial, use the agreed options; automatic regeneration is enabled by
omitting `--no-auto-repair`:

```sh
mix run --no-start -e 'Regenerator.CLI.main(System.argv())' -- \
  --scope narrow --rate 10 --seed 42 --threshold 3 --actor robert
```

This can spend on multiple alarms before the first human decision. Repair is
serial; later proposals can become stale when a different module version loads.
An approved fix changes the signature's source-version component, so later
alarms may be distinct incidents. Do not treat a chosen number of planted cases
as an automatic stopping condition or expect exactly four lifetime cards.

The seed controls input order, not scheduler timing, provider output, or cost.
Human waiting and repair queue time affect recovery. Pausing lowers observed
failed requests; it must not be hidden. Keep rate/seed/model/retry/pause rules
fixed within a cohort or label deviations and analyze separately. This is an
initial feasibility study, not evidence that Mode B or human review is safe.

## Trial record and archival

Before the first paid call, create a record in the excluded operator directory.
Use this template, leaving unknown values explicitly null rather than guessed:

```json
{
  "trial_id": "smoke-001",
  "purpose": "smoke",
  "baseline_commit": "daf5346ca97a90527ef791c07346ec8fe2c5c5ca",
  "checkout": null,
  "run_id": null,
  "run_directory": null,
  "human_actor": null,
  "host_os_arch": null,
  "tool_versions": {},
  "auth_variable_name_only": null,
  "builder_argv_without_secrets": [],
  "reviewer_argv_without_secrets_or_null": null,
  "scope": "narrow",
  "rate": null,
  "seed": null,
  "threshold": null,
  "window_ms": 10000,
  "request_timeout_ms": 250,
  "runner_invocation_timeout_seconds": 180,
  "automatic_regeneration": null,
  "budget_and_attempt_limit": null,
  "stopping_retry_selection_pause_rules": null,
  "baseline_contract_sha256": null,
  "start_utc": null,
  "end_utc": null,
  "final_contract_sha256": null,
  "process_exit_confirmed": false,
  "interrupted": null,
  "stop_reason": null,
  "preflight_logs": [],
  "human_decisions_and_rulings": [],
  "deviations_and_infrastructure_errors": [],
  "provider_usage_and_cost_or_unknown": null,
  "evidence_location": null
}
```

Copy only known non-secret argv into the record; do not serialize the whole
environment. Record wall-clock start/end externally because there is no
`run_ended` event. Save contract hashes using `sha256sum` before and after the
run and preserve the final ruled contract. The runtime log does not record all
model/configuration choices, so this record is necessary, not optional.

After the run is stopped and any remaining worker writes have ceased, preserve:

- The **whole** `run/<run-id>/` directory, including JSONL, all bundles and
  unsuccessful proposals, patch/test/stage outputs, candidate and prior BEAMs.
- The trial record, agreed plan, preflight logs, final cards/status and the
  final contract. Capture human decision text/approval provenance outside the
  model workspace; the runtime `actor` string is not authentication.
- The runtime revision and any operator-side diff. Do not replace the baseline
  with candidate source or commit a ruled contract as an unmarked fresh
  baseline.
- Text and JSON summaries, preserving the originals even if warnings appear.

From the experiment directory, use a new destination for each trial:

```sh
set -euo pipefail
RUN_DIR=/absolute/path/to/experiment/run/actual-run-id
ARCHIVE=/absolute/path/outside/repo/trial-001
# mkdir without -p refuses an existing destination rather than merging evidence.
mkdir "$ARCHIVE"
cp -a "$RUN_DIR" "$ARCHIVE/run"
cp contracts/shipping_estimate.md "$ARCHIVE/final-contract.md"
mix compile
mix results "$ARCHIVE/run" > "$ARCHIVE/summary.txt"
mix results --json "$ARCHIVE/run" > "$ARCHIVE/summary.json"
python3 -m json.tool "$ARCHIVE/summary.json" >/dev/null
```

Copy the trial record and other logs into that new archive too. Compare hashes
of every copied run file against the stopped original before deleting anything.
Retain a checksum inventory with relative paths for later verification. If
artifacts unexpectedly contain credentials, quarantine them; do not publish or
silently edit the originals. Make separately labeled redacted sharing copies
with the owner's approval. Do not push run archives or raw model output to
GitHub.

For a cohort, pass the archived **run** subdirectories, not archive parents:

```sh
mix results --json /path/to/trial-001/run /path/to/trial-002/run \
  > /path/outside/repo/cohort-results.json
```

Compilation must happen before redirecting JSON to avoid Mix compile chatter.
The summarizer never starts the application or invokes an agent. It groups
retry/ruling attempts by parent ID and measures first logged failure to verified
load using monotonic elapsed time. Unresolved incidents are censored at the last
logged event; they are not zero-time recoveries. Evidence warnings suppress
recovery durations for that run, while observed counts remain available.

Even a `consistent_snapshot` cannot prove the tail was captured or the trial
finished. A matching live probe is evidence for that scenario, not proof of
semantic correctness or durable recovery under continued load. Keep skipped
review, reviewer dissent, infrastructure failure, and unresolved policy
distinct.

## Required final report from the trial agent

Report all attempted run IDs, purpose (preflight/smoke/measured), revision and
configuration, paid attempts/cost if known, and archive locations. For each run,
report observed request counts, alarms, proposals/questions, reviewer outcomes,
human decisions, verified/failed loads, unresolved incidents, recovery durations
and summarizer warnings. Include rejected and interrupted attempts. State
whether the process and artifacts finished cleanly, which human rulings persist,
and whether the next trial can start from a verified fresh baseline.

Stop and ask the owner about authentication, isolation failures, missing human
decisions, exhausted budget, damaged evidence, or any protocol change. Propose
implementation fixes separately; do not change a measured trial mid-run. Before
Phase 2, the owner still must choose the provisional observation window,
rollback triggers/scope, and recovery/harm accounting across rollback. Do not
implement those features as part of this handoff.
