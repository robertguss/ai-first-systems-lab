# Isolated maintenance proposals

Run from the experiment root:

```sh
python3 scripts/repair.py --workspace . --bundle /path/incident.json \
  --output /path/new-proposal --scope narrow
python3 -m unittest discover -s scripts -p 'test_*.py' -v
```

The output directory must not exist. The source project is never modified. Only
Python's standard library, Linux Bubblewrap, Elixir/Mix/Erlang and the
configured agent executable are needed. No Python packages or network-fetched
Mix dependencies are used. Missing namespace support fails closed; there is no
directory-only mode.

The default command is
`claude --print --permission-mode bypassPermissions --no-session-persistence`.
The entire Claude process (including tools) runs inside Bubblewrap. `--bare` is
omitted because it disables Claude Code's OAuth authentication.
`--command-json '["executable","arg"]'` and
`--reviewer-command-json '["executable","arg"]'` replace executable argv. The
runner appends the stage prompt as the **final argument**. Executables must
exist in the mounted runtime, `/opt/regenerator-tools/bin`, or sanitized
workspace; host scripts outside these mounts cannot execute. Each stage is a
fresh process and HOME, but both builder stages share one sanitized working
copy.

## Isolation and disclosure boundary

Each invocation has private user, mount, PID, network, IPC, UTS and cgroup
namespaces, a fresh `/proc`, `/dev`, HOME and `/tmp`, and a cleared environment.
Standard runtime directories `/usr`, `/bin`, `/lib`, `/lib64`,
`/opt/regenerator-tools`, and system CA certificates are read-only. These
runtime trees must themselves be trusted and must not contain credentials or
repository copies. Toolchain symlinks must resolve within these trees. Original
HOME, repository, git history, host `/proc`, output evidence, and other host
paths are absent. `/usr/local` is masked with an empty read-only mount, not
exposed as host tools. Only `/opt/regenerator-tools` is mounted from `/opt`.

Only agents receive the selected credential: `CLAUDE_CODE_OAUTH_TOKEN` when
configured, otherwise `ANTHROPIC_API_KEY`. They never receive both by default.
Repeat `--credential-env NAME` to explicitly replace that list with other
uppercase provider KEY/TOKEN variables. Tests, compilation, validation and
probes receive **no credentials and no network**. Agents have no direct network;
their local HTTPS proxy relays to a host Unix socket. The host permits CONNECT
only to `api.anthropic.com:443`. Repeat `--provider-host HOST` to replace that
allowlist. No wildcard or other port is supported. A configured CLI must honor
HTTPS_PROXY; unsupported providers fail rather than gain host network. Do not
allow untrusted proxy destinations: the model credential is intentionally
available to the agent, and the chosen provider is an explicit disclosure
boundary.

Narrow context contains the snapshot shipping source and contract, original
module tests, a generated dependency-free Mix project/test helper, and
incident.json. Broad context recursively copies visible project files, excluding
all dotfiles, symlinks, `experiment`, `secret`, `run`, `_build`, `deps`,
`node_modules`, `scripts`, `docs`, `README.md`, and AGENTS/CLAUDE/GEMINI
instruction files at every depth. The current output and bundle paths are also
excluded. These are explicit exclusions from whole-repo context: application
code, contracts, tests and Mix configuration remain available, operator
documents and orchestration do not. Put experiment-only documents, manifests and
runtime data under excluded paths; arbitrary visible files cannot be classified
as secret automatically. Both scopes overwrite source/contract with the bundle
snapshot, never current workspace versions. Both have identical editing
permissions: only the shipping module and new reproducer. Bundle SHA256 values
are checked. The signature is a diagnostic crash fingerprint, not a
cryptographic signature; the controller supplies its own recorded bundle, not an
agent-selected path.

## Protocol and evidence

1. The builder may only add `test/reproduction_test.exs` and `response.json`. A
   question may only create response.json and skips tests.
2. For a fix, the host independently runs that reproducer against unchanged
   snapshot source and requires a nonzero exit with a real ExUnit failure
   summary. Compile errors are not reproduction. It then invokes the builder
   again to change only `lib/shipping_estimate.ex` and response.json. Reproducer
   bytes must not change. An agent may discover a gap at this stage and return a
   question, provided it leaves source unchanged. Agents may run Mix; their
   `_build` directory is discarded and never used for host verification.
3. Trusted baseline files are restored in another private workspace. All narrow
   module tests run, followed by the full project suite in a separate sandbox
   when a project Mix file exists. This does not widen agent context.
   Compilation, BEAM inspection, and incident probe use fresh isolated VMs.
   Exactly ShippingEstimate, estimate/1 and no on_load are required.
   `probe_result` is
   `inspect(ShippingEstimate.estimate(input), limit: :infinity)`; JSON map keys
   remain **strings**, matching ordinary JSON decoding.
4. An optional independent reviewer receives original/candidate source,
   contract, incident, patch and mechanical test evidence, never builder
   transcripts or descriptions. It writes review.json `{verdict, details}`. Only
   those structured fields are captured. Missing/malformed reviews fail closed;
   a builder question remains a question with review.status failed. A valid
   reject/question verdict preserves the builder's original kind: downstream
   approval must inspect review.

Builder response.json is either `{ "kind": "fix", "description": "..." }` or
`{ "kind": "question", "question": "...", "options": ["...", "..."] }`. No
prompt describes experimental cases. Ambiguous policy must become a question.

Host-only evidence includes proposal.json, original structured builder
responses, stage output/exit records, reproduction_test.exs, candidate.ex,
patch.diff, candidate.beam, probe.txt and provenance.json, as stages become
available. Changed files and deletion lists from each builder stage are
retained, including rejected edits. Failures keep existing evidence. `--timeout`
defaults to 180 seconds per invocation; `--max-output` defaults to 2,000,000
bytes per invocation. Exceeding either fails and terminates the sandbox PID
namespace; output up to the bound is preserved. The reviewer only stores its
validated structured review, not its console reasoning. Host reads of generated
artifacts require regular files and are bounded to 8 MB; FIFOs, devices and
symlinks cannot turn a completed sandbox run into an unbounded host read.

This runner proposes; it does not approve, load into a live VM, commit, or
deploy. The parent runtime must gate review outcomes, compare base hashes,
select its own bundle, verify candidate hashes, and compare a fresh live
request's exact inspected value with probe_result after approval. Mechanical
tests are evidence, not a proof against intentionally dishonest generated test
code.
