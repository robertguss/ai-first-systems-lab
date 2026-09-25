#!/usr/bin/env python3
"""Two-stage maintenance proposals. All untrusted execution uses sandbox.py."""
import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import tempfile

from sandbox import run

SOURCE = "lib/shipping_estimate.ex"
CONTRACT = "contracts/shipping_estimate.md"
TEST = "test/shipping_estimate_test.exs"
REPRO = "test/reproduction_test.exs"
EXCLUDED = {"experiment", "secret", "run", "_build", "deps", "node_modules",
            "scripts", "docs", "AGENTS.md", "CLAUDE.md", "GEMINI.md", "README.md"}
MIX = '''defmodule Maintenance.MixProject do
  use Mix.Project
  def project, do: [app: :maintenance, version: "0.1.0", elixir: ">= 1.14.0"]
  def application, do: []
end
'''
POLICY = """Handle this maintenance incident using the supplied contract. Do not invent
contract policy. If the contract is silent on a required decision, write a question
with at least two concrete options instead of changing code. Write response.json as
either {"kind":"fix","description":"behavior description"} or
{"kind":"question","question":"...","options":["...","..."]}.
Do not change the contract or original tests. Do not use network except your model
provider. The host independently checks all modifications and executes tests.
"""


def digest(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def artifact(path, limit=8_000_000):
    # No host-side blocking reads of untrusted FIFOs/devices, and no unbounded
    # allocation after the timed sandbox process has already exited.
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            raise ValueError("artifact must be a bounded regular file: " + str(path.name))
        data = stream.read(limit + 1)
        if len(data) > limit:
            raise ValueError("artifact exceeds size limit")
        return data


def sanitized_copy(source, destination, omitted=()):
    """Copy ordinary visible project files, never follow links or instruction files."""
    for item in source.iterdir():
        if (item in omitted or item.name.startswith(".") or item.name in EXCLUDED or item.is_symlink()
                or item.name.lower() in {"agents.md", "claude.md", "gemini.md"}):
            continue
        target = destination / item.name
        if item.is_dir():
            target.mkdir()
            sanitized_copy(item, target, omitted)
        elif item.is_file():
            shutil.copyfile(item, target)


def snapshot(root):
    result = {}
    for path in root.rglob("*"):
        # Agents may run Mix themselves. Never reuse their build artifacts for
        # host verification, which always starts from fresh trusted files.
        if "_build" in path.relative_to(root).parts:
            continue
        if path.is_symlink():
            raise ValueError(f"symlink is forbidden: {path.relative_to(root)}")
        if path.is_file():
            result[str(path.relative_to(root))] = artifact(path)
        elif not path.is_dir():
            raise ValueError("non-regular workspace entry")
    return result


def restore(root, files):
    for path, data in files.items():
        target = root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)


def enforce(before, after, allowed):
    changed = {name for name in before.keys() | after.keys()
               if before.get(name) != after.get(name)}
    forbidden = changed - set(allowed)
    if forbidden:
        raise ValueError("unauthorized changes: " + ", ".join(sorted(forbidden)))


def capture_changes(output, label, before, after):
    changes = {k: v for k, v in after.items() if before.get(k) != v}
    restore(output / (label + "-files"), changes)
    write_json(output / (label + "-changes.json"), {
        "files": {k: digest(v) for k, v in changes.items()},
        "deleted": sorted(before.keys() - after.keys())})


def read_response(root):
    value = json.loads((root / "response.json").read_text())
    if value.get("kind") == "question":
        if not isinstance(value.get("question"), str) or not value["question"].strip():
            raise ValueError("question must be nonempty")
        options = value.get("options")
        if not isinstance(options, list) or len(options) < 2 or not all(
                isinstance(o, str) and o.strip() for o in options):
            raise ValueError("question requires at least two nonempty options")
    elif value.get("kind") == "fix":
        if not isinstance(value.get("description"), str) or not value["description"].strip():
            raise ValueError("fix requires a behavior description")
    else:
        raise ValueError("response kind must be fix or question")
    keys = ("kind", "question", "options") if value["kind"] == "question" else ("kind", "description")
    return {key: value[key] for key in keys}


def narrow(workspace, bundle):
    original_test = workspace / TEST
    if original_test.is_symlink() or any(p.is_symlink() for p in original_test.parents):
        raise ValueError("original test must not be a symlink")
    return {SOURCE: bundle["source"].encode(), CONTRACT: bundle["contract"].encode(),
            TEST: original_test.read_bytes(), "mix.exs": MIX.encode(),
            "test/test_helper.exs": b"ExUnit.start()\n"}


def executed(root, command, output, label, args, agent=False):
    result = run(root, command, timeout=args.timeout, max_output=args.max_output,
                 hosts=args.provider_host if agent else (),
                 credentials={k: os.environ[k] for k in args.credential_env
                              if k in os.environ} if agent else {})
    write_json(output / (label + ".execution.json"), result)
    (output / (label + ".log")).write_text(result["output"])
    if result["error"] and not agent:
        raise ValueError(result["error"])
    return result


def test_run(files, command, output, label, args):
    with tempfile.TemporaryDirectory(prefix="repair-test-") as temp:
        root = Path(temp)
        restore(root, files)
        return executed(root, command, output, label, args)


def failed_tests(result):
    # ExUnit's summary distinguishes a real test failure from compiler errors.
    return result["exit_code"] != 0 and bool(re.search(
        r"\b[1-9][0-9]* tests?, [1-9][0-9]* failures?\b|"
        r"^Failed: [1-9][0-9]* tests?\s*$", result["output"], re.MULTILINE))


def passed_tests(result):
    return result["exit_code"] == 0 and bool(re.search(
        r"\b[1-9][0-9]* tests?, 0 failures\b|"
        r"Result: [1-9][0-9]* passed\s*$", result["output"], re.MULTILINE))


COMPILE = r'''
compiled = Code.compile_file("lib/shipping_estimate.ex")
case compiled do
  [{ShippingEstimate, beam}] ->
    File.write!("candidate.beam", beam)
  _ -> raise "exactly ShippingEstimate must be compiled"
end
'''

VALIDATE = r'''
    beam = File.read!("candidate.beam")
    {:ok, {ShippingEstimate, chunks}} = :beam_lib.chunks(beam, [:attributes, :exports])
    attrs = Keyword.fetch!(chunks, :attributes)
    exports = Keyword.fetch!(chunks, :exports)
    {:ok, {ShippingEstimate, [{:abstract_code, {:raw_abstract_v1, forms}}]}} =
      :beam_lib.chunks(beam, [:abstract_code])
    on_load = Enum.any?(forms, fn
      {:attribute, _, :on_load, _} -> true
      _ -> false
    end)
    if on_load or Keyword.has_key?(attrs, :on_load), do: raise("on_load forbidden")
    unless {:estimate, 1} in exports, do: raise("estimate/1 export required")
'''


def elixir_term(value):
    """JSON semantics: map keys stay strings, and strings cannot inject Elixir."""
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, str):
        return "<<" + ",".join(str(b) for b in value.encode()) + ">>"
    if isinstance(value, list):
        return "[" + ",".join(elixir_term(v) for v in value) + "]"
    if isinstance(value, dict):
        return "%{" + ",".join(elixir_term(k) + "=>" + elixir_term(v)
                                 for k, v in value.items()) + "}"
    if isinstance(value, (int, float)):
        return json.dumps(value, allow_nan=False)
    raise ValueError("unsupported JSON value")


def review(args, bundle, baseline, proposal, output, candidate=None):
    if not args.reviewer_command_json:
        return
    proposal["review"] = {"status": "failed", "verdict": "", "details": ""}
    try:
        with tempfile.TemporaryDirectory(prefix="repair-review-") as temp:
            root = Path(temp)
            restore(root, baseline)
            # Mechanical evidence only: no builder response, description, or transcript.
            write_json(root / "incident.json", {k: bundle[k] for k in
                       ("id", "timestamp", "reason", "stacktrace", "input")})
            if candidate is not None:
                (root / "candidate.ex").write_bytes(candidate)
            if (output / "reproduction_test.exs").exists():
                (root / REPRO).write_bytes((output / "reproduction_test.exs").read_bytes())
            (root / "patch.diff").write_text((output / "patch.diff").read_text()
                                             if (output / "patch.diff").exists() else "")
            write_json(root / "test_results.json", proposal["tests"])
            before = snapshot(root)
            prompt = ("Independently review this maintenance incident against the contract. "
                      "The original source is lib/shipping_estimate.ex. A candidate, if any, "
                      "is candidate.ex. Do not invent contract policy; if silent, request "
                      "clarification. Write only review.json with verdict accept, reject, "
                      "or question and nonempty string details. Do not modify other files.")
            # Review process logs deliberately are not persisted: only structured review.
            result = run(root, [*args.reviewer_command_json, prompt],
                         timeout=args.timeout, max_output=args.max_output,
                         hosts=args.provider_host, credentials={k: os.environ[k]
                         for k in args.credential_env if k in os.environ})
            if result["exit_code"] or result["error"]:
                raise ValueError("reviewer execution failed: " + result["error"])
            enforce(before, snapshot(root), ["review.json"])
            value = json.loads((root / "review.json").read_text())
            if value.get("verdict") not in ("accept", "reject", "question") or not (
                    isinstance(value.get("details"), str) and value["details"].strip()):
                raise ValueError("invalid structured review")
            value = {key: value[key] for key in ("verdict", "details")}
            write_json(output / "review.json", value)
            proposal["review"] = {"status": "completed", **value}
    except Exception as error:
        proposal["review"]["details"] = str(error)
        if proposal["kind"] != "question":
            proposal["kind"] = "failed"
            proposal["error"] = "review failed: " + str(error)


def repair(args):
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    proposal = {"kind": "failed", "description": "", "question": "", "options": [],
                "base_source_hash": "", "base_contract_hash": "", "candidate_hash": "",
                "candidate_source_hash": "", "probe_result": "", "tests": {"passed": False, "output": "",
                "reproduction_failed": False}, "review": {"status": "skipped",
                "verdict": "", "details": "No reviewer configured."}}
    candidate = None
    try:
        bundle = json.loads(args.bundle.read_text())
        for key in ("id", "timestamp", "reason", "stacktrace", "source", "contract",
                    "source_hash", "contract_hash", "signature"):
            if not isinstance(bundle.get(key), str):
                raise ValueError(f"bundle {key} must be a string")
        if not isinstance(bundle.get("input"), dict):
            raise ValueError("bundle input must be an object")
        for key in ("source", "contract"):
            actual = digest(bundle[key].encode())
            if actual != bundle[key + "_hash"]:
                raise ValueError(f"bundle {key} hash mismatch")
            proposal["base_" + key + "_hash"] = actual
        baseline = narrow(args.workspace, bundle)
        write_json(output / "provenance.json", {"bundle_id": bundle["id"],
                   "timestamp": bundle["timestamp"], "signature": bundle["signature"],
                   "scope": args.scope, "source_hash": bundle["source_hash"],
                   "contract_hash": bundle["contract_hash"],
                   "signature_kind": "crash_fingerprint"})
        incident = {k: bundle[k] for k in ("id", "timestamp", "reason", "stacktrace", "input")}
        with tempfile.TemporaryDirectory(prefix="repair-agent-") as temp:
            root = Path(temp)
            if args.scope == "broad":
                sanitized_copy(args.workspace.resolve(), root, (output, args.bundle.resolve()))
            restore(root, baseline if args.scope == "narrow" else {
                SOURCE: baseline[SOURCE], CONTRACT: baseline[CONTRACT]})
            write_json(root / "incident.json", incident)
            before = snapshot(root)
            prompt = POLICY + "\nRead incident.json. First reproduce the incident: ONLY add " \
                "test/reproduction_test.exs and response.json. Do not fix the source yet. " \
                "For a question, write response.json only."
            result = executed(root, [*args.command_json, prompt], output, "reproduce-agent", args, True)
            after = snapshot(root)
            if "response.json" in after:
                (output / "reproduce-response.json").write_bytes(after["response.json"])
            capture_changes(output, "reproduce", before, after)
            if result["exit_code"] or result["error"]:
                raise ValueError(result["error"] or "reproduction agent exited unsuccessfully")
            response = read_response(root)
            enforce(before, after, ["response.json"] if response["kind"] == "question"
                    else ["response.json", REPRO])
            if response["kind"] == "question":
                proposal.update(response)
            else:
                reproduction = after.get(REPRO)
                if not reproduction or REPRO in before:
                    raise ValueError("a new reproduction test is required")
                (output / "reproduction_test.exs").write_bytes(reproduction)
                result = test_run({**baseline, REPRO: reproduction},
                                  ["mix", "test", REPRO, "--seed", "0"],
                                  output, "reproduction-test", args)
                proposal["tests"]["output"] = result["output"]
                if not failed_tests(result):
                    raise ValueError("reproducer must fail an actual ExUnit test on unchanged source")
                proposal["tests"]["reproduction_failed"] = True
                before_fix = snapshot(root)
                prompt = POLICY + "\nThe host confirmed a failing reproduction. Fix ONLY " \
                    "lib/shipping_estimate.ex and write response.json kind fix with a behavior " \
                    "description. Keep the reproduction test byte-for-byte unchanged. Run all " \
                    "tests with mix test; the host will independently rerun them. If you " \
                    "discover a policy gap, leave source unchanged and return a question instead."
                result = executed(root, [*args.command_json, prompt], output, "fix-agent", args, True)
                after_fix = snapshot(root)
                capture_changes(output, "fix", before_fix, after_fix)
                if "response.json" in after_fix:
                    (output / "fix-response.json").write_bytes(after_fix["response.json"])
                if SOURCE in after_fix:
                    (output / "candidate.ex").write_bytes(after_fix[SOURCE])
                if result["exit_code"] or result["error"]:
                    raise ValueError(result["error"] or "fix agent exited unsuccessfully")
                enforce(before_fix, after_fix, [SOURCE, "response.json"])
                response = read_response(root)
                if response["kind"] == "question":
                    enforce(before_fix, after_fix, ["response.json"])
                    proposal.update(response)
                    review(args, bundle, baseline, proposal, output)
                    write_json(output / "proposal.json", proposal)
                    return proposal
                candidate = after_fix[SOURCE]
                proposal.update(response)
                proposal["candidate_source_hash"] = digest(candidate)
                patch = "".join(difflib.unified_diff(bundle["source"].splitlines(True),
                                candidate.decode().splitlines(True), fromfile="a/" + SOURCE,
                                tofile="b/" + SOURCE))
                (output / "patch.diff").write_text(patch)
                result = test_run({**baseline, SOURCE: candidate, REPRO: reproduction},
                                  ["mix", "test", "--seed", "0"], output, "candidate-tests", args)
                proposal["tests"]["output"] += "\n" + result["output"]
                if not passed_tests(result):
                    raise ValueError("candidate tests did not pass")
                # Full-project checks stay host-controlled and do not widen the
                # agent's context. Minimal standalone fixtures have no mix.exs.
                if (args.workspace / "mix.exs").is_file():
                    with tempfile.TemporaryDirectory(prefix="repair-integration-") as temp:
                        integration = Path(temp)
                        sanitized_copy(args.workspace.resolve(), integration,
                                       (output, args.bundle.resolve()))
                        restore(integration, {SOURCE: candidate, CONTRACT: baseline[CONTRACT],
                                              TEST: baseline[TEST], REPRO: reproduction})
                        result = executed(integration, ["mix", "test", "--seed", "0"],
                                          output, "integration-tests", args)
                        proposal["tests"]["output"] += "\nFull project:\n" + result["output"]
                        if not passed_tests(result):
                            raise ValueError("full-project tests did not pass")
                with tempfile.TemporaryDirectory(prefix="repair-compile-") as build:
                    compile_root = Path(build)
                    restore(compile_root, {SOURCE: candidate})
                    result = executed(compile_root, ["elixir", "-e", COMPILE],
                                      output, "candidate-compile", args)
                    if result["exit_code"]:
                        raise ValueError("candidate BEAM validation failed")
                    beam_path = compile_root / "candidate.beam"
                    if beam_path.is_symlink():
                        raise ValueError("candidate BEAM must not be a symlink")
                    beam = artifact(beam_path)
                result = test_run({"candidate.beam": beam}, ["elixir", "-e", VALIDATE],
                                  output, "candidate-validate", args)
                if result["exit_code"]:
                    raise ValueError("candidate BEAM validation failed")
                (output / "candidate.beam").write_bytes(beam)
                proposal["candidate_hash"] = digest(beam)
                with tempfile.TemporaryDirectory(prefix="repair-probe-") as temp:
                    probe_root = Path(temp)
                    restore(probe_root, {"candidate.beam": beam})
                    probe = ('{:module, ShippingEstimate} = :code.load_binary(ShippingEstimate, '
                             '~c"candidate.beam", File.read!("candidate.beam")); '
                             'result = ShippingEstimate.estimate(' + elixir_term(bundle["input"]) + '); '
                             'File.write!("probe.txt", inspect(result, limit: :infinity))')
                    result = executed(probe_root, ["elixir", "-e", probe], output, "candidate-probe", args)
                    if result["exit_code"] or (probe_root / "probe.txt").is_symlink():
                        raise ValueError("candidate probe failed")
                    proposal["probe_result"] = artifact(probe_root / "probe.txt").decode()
                    (output / "probe.txt").write_text(proposal["probe_result"])
                proposal["tests"]["passed"] = True
        review(args, bundle, baseline, proposal, output, candidate)
    except Exception as error:
        proposal["kind"] = "failed"
        proposal["error"] = str(error)
    write_json(output / "proposal.json", proposal)
    return proposal


def argv_json(value):
    result = json.loads(value)
    if not isinstance(result, list) or not result or not all(
            isinstance(item, str) and item for item in result):
        raise argparse.ArgumentTypeError("expected a nonempty JSON string argv array")
    return result


def default_credential_env():
    # Forward one authentication method, never the general host environment.
    if os.environ.get("CLAUDE_CODE_OAUTH_TOKEN"):
        return ["CLAUDE_CODE_OAUTH_TOKEN"]
    return ["ANTHROPIC_API_KEY"]


def parser():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("--workspace", type=Path, required=True)
    cli.add_argument("--bundle", type=Path, required=True)
    cli.add_argument("--output", type=Path, required=True)
    cli.add_argument("--scope", choices=["narrow", "broad"], required=True)
    cli.add_argument("--command-json", type=argv_json, default=["claude", "--print",
                     "--permission-mode", "bypassPermissions", "--no-session-persistence"])
    cli.add_argument("--reviewer-command-json", type=argv_json)
    cli.add_argument("--provider-host", action="append", default=None,
                     help="allowed CONNECT DNS host on port 443; repeatable")
    cli.add_argument("--credential-env", action="append", default=None,
                     help="explicit provider credential environment variable; repeatable")
    cli.add_argument("--timeout", type=float, default=180)
    cli.add_argument("--max-output", type=int, default=2_000_000)
    return cli


def main():
    args = parser().parse_args()
    args.provider_host = args.provider_host or ["api.anthropic.com"]
    args.credential_env = args.credential_env or default_credential_env()
    if any(not re.fullmatch(r"[A-Z][A-Z0-9_]*(?:KEY|TOKEN)", key)
           for key in args.credential_env):
        raise SystemExit("credential names must be explicit uppercase KEY or TOKEN variables")
    if any(not re.fullmatch(r"[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?", host)
           for host in args.provider_host):
        raise SystemExit("provider hosts must be DNS names without ports or wildcards")
    if args.timeout <= 0 or args.max_output <= 0:
        raise SystemExit("timeout and output limit must be positive")
    try:
        result = repair(args)
    except FileExistsError:
        raise SystemExit("output already exists; refusing to overwrite evidence")
    print(json.dumps(result))
    raise SystemExit(1 if result["kind"] == "failed" else 0)


if __name__ == "__main__":
    main()
