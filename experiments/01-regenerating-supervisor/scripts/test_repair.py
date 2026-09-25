"""Synthetic fixtures only; no dependency on the experiment's shipping policy."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import repair
import sandbox

SOURCE = 'defmodule ShippingEstimate do\n  def estimate(input), do: input["n"]\nend\n'
FIXED = SOURCE.replace('input["n"]', 'input["n"] * 3')
CONTRACT = 'For this synthetic fixture only, return three times the input n.\n'
ORIGINAL = '''defmodule OriginalTest do
  use ExUnit.Case
  test "zero", do: assert ShippingEstimate.estimate(%{"n" => 0}) == 0
end
'''
REPRO = '''defmodule ReproductionTest do
  use ExUnit.Case
  test "nonzero", do: assert ShippingEstimate.estimate(%{"n" => 7}) == 21
end
'''


def python(code):
    return ["/usr/bin/python3", "-c", code]


def agent(mode="fix", candidate=FIXED):
    return python(f'''
import json
from pathlib import Path
source = Path({repair.SOURCE!r})
repro = Path({repair.REPRO!r})
response = {{"kind":"fix", "description":"Apply the documented multiplier."}}
if {mode!r} == "question":
    response = {{"kind":"question", "question":"Which policy applies?", "options":["A", "B"]}}
elif not repro.exists():
    repro.write_text({REPRO!r})
    if {mode!r} == "early": source.write_text({candidate!r})
    if {mode!r} == "syntax": repro.write_text("this is not Elixir (((")
else:
    if {mode!r} == "late-question":
        response = {{"kind":"question", "question":"Which policy applies?", "options":["A", "B"]}}
    else:
        source.write_text({candidate!r})
    if {mode!r} == "test-change": repro.write_text({REPRO!r} + "# altered\\n")
    if {mode!r} == "run-tests":
        import subprocess
        subprocess.run(['mix', 'test'], check=True)
Path("response.json").write_text(json.dumps(response))
''')


class CopyTests(unittest.TestCase):
    def test_excludes_metadata_secrets_instructions_and_symlinks_recursively(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            src, dst = root / "src", root / "dst"
            src.mkdir(); dst.mkdir()
            for name in ("lib/keep.ex", "lib/CLAUDE.md", "lib/.env", ".git/config",
                         "experiment/private", "secret/manifest", "run/events",
                         "_build/cache", "deps/code", ".amp/data", ".agents/setup",
                         "README.md", "docs/design.md", "scripts/operator.py"):
                file = src / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text("fixture")
            (src / "leak").symlink_to("/etc/passwd")
            (src / "linked-dir").symlink_to(root, target_is_directory=True)
            repair.sanitized_copy(src, dst)
            self.assertEqual(set(repair.snapshot(dst)), {"lib/keep.ex"})

    def test_compile_error_is_not_a_reproduction(self):
        self.assertFalse(repair.failed_tests({"exit_code": 1, "output": "SyntaxError"}))
        self.assertFalse(repair.failed_tests({"exit_code": 0, "output": "1 test, 1 failure"}))
        self.assertTrue(repair.failed_tests({"exit_code": 2, "output": "3 tests, 2 failures"}))
        self.assertTrue(repair.failed_tests({"exit_code": 2, "output": "Result: 0/1 passed\nFailed: 1 test\n"}))
        self.assertTrue(repair.passed_tests({"exit_code": 0, "output": "Result: 2 passed\n"}))
        self.assertFalse(repair.passed_tests({"exit_code": 0, "output": "Result: 0/1 passed\nFailed: 1 test\n"}))

    def test_artifacts_must_be_bounded_regular_files(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "candidate.beam"
            os.mkfifo(path)
            with self.assertRaisesRegex(ValueError, "regular file"):
                repair.artifact(path)
            path.unlink()
            path.write_bytes(b"12345")
            with self.assertRaisesRegex(ValueError, "regular file"):
                repair.artifact(path, limit=4)


@unittest.skipUnless(shutil.which("bwrap"), "bubblewrap is not installed")
class IsolationTests(unittest.TestCase):
    def test_mount_pid_network_and_environment_isolation(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            outside = root / "outside"
            outside.write_text("must remain inaccessible")
            work = root / "work"; work.mkdir()
            code = f'''
import os, pathlib, socket
assert not pathlib.Path({str(outside)!r}).exists()
assert not pathlib.Path('/proc/1/root' + {str(outside)!r}).exists()
assert not pathlib.Path('/home/user').exists()
assert not pathlib.Path('/etc/passwd').exists()
assert list(pathlib.Path('/usr/local').iterdir()) == []
assert 'ANTHROPIC_API_KEY' not in os.environ
assert 'HOME' in os.environ and os.environ['HOME'] == '/home/agent'
assert not pathlib.Path('/bridge/proxy.sock').exists()
try:
    socket.create_connection(('1.1.1.1', 443), timeout=0.2)
except OSError:
    pass
else:
    raise AssertionError('network escaped')
print('isolated')
'''
            result = sandbox.run(work, python(code), timeout=5)
            self.assertEqual(result["exit_code"], 0, result)
            self.assertEqual(result["output"].strip(), "isolated")

    def test_proxy_denies_unconfigured_host_and_port(self):
        with tempfile.TemporaryDirectory() as temp:
            result = sandbox.run(Path(temp), python('''
import os, socket
assert os.environ['SYNTHETIC_API_KEY'] == 'fixture'
for target in ['example.org:443', 'api.anthropic.com:80']:
    with socket.create_connection(('127.0.0.1',18080)) as s:
        s.sendall(('CONNECT ' + target + ' HTTP/1.1\\r\\n\\r\\n').encode())
        assert b'403' in s.recv(4096)
print('denied')
'''), hosts=["api.anthropic.com"], credentials={"SYNTHETIC_API_KEY": "fixture"}, timeout=5)
            self.assertEqual(result["exit_code"], 0, result)
            self.assertEqual(result["output"].strip(), "denied")

    def test_timeout_and_bounded_output(self):
        with tempfile.TemporaryDirectory() as temp:
            result = sandbox.run(Path(temp), python("import time; time.sleep(10)"), timeout=0.2)
            self.assertIn("timeout", result["error"])
            result = sandbox.run(Path(temp), python("print('x' * 10000)"), max_output=100)
            self.assertEqual(len(result["output"]), 100)
            self.assertIn("output limit", result["error"])


@unittest.skipUnless(shutil.which("bwrap") and shutil.which("elixir"), "bwrap and Elixir required")
class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.workspace = self.root / "project"
        self.workspace.mkdir()
        repair.restore(self.workspace, {repair.SOURCE: b"newer unrelated source",
                                       repair.CONTRACT: b"newer unrelated contract",
                                       repair.TEST: ORIGINAL.encode()})
        self.before = repair.snapshot(self.workspace)
        self.bundle = self.root / "bundle.json"
        repair.write_json(self.bundle, {"id": "synthetic", "timestamp": "2026-01-01",
                         "reason": "unexpected result", "stacktrace": "", "input": {"n": 7},
                         "source": SOURCE, "contract": CONTRACT,
                         "source_hash": repair.digest(SOURCE.encode()),
                         "contract_hash": repair.digest(CONTRACT.encode()), "signature": "opaque"})

    def invoke(self, mode="fix", reviewer=None, candidate=FIXED):
        args = argparse.Namespace(workspace=self.workspace, bundle=self.bundle,
                                  output=self.root / "output", scope="narrow",
                                  command_json=agent(mode, candidate), reviewer_command_json=reviewer,
                                  provider_host=["api.anthropic.com"], credential_env=[],
                                  timeout=30, max_output=200000)
        result = repair.repair(args)
        self.assertEqual(repair.snapshot(self.workspace), self.before)
        return result

    def test_end_to_end_fix_snapshot_hash_probe_and_skipped_review(self):
        result = self.invoke()
        self.assertEqual(result["kind"], "fix", result)
        self.assertTrue(result["tests"]["passed"])
        self.assertTrue(result["tests"]["reproduction_failed"])
        self.assertEqual(result["probe_result"], "21")
        self.assertEqual(result["review"]["status"], "skipped")
        self.assertEqual(result["candidate_hash"], repair.digest((self.root / "output/candidate.beam").read_bytes()))
        self.assertEqual(result["base_source_hash"], repair.digest(SOURCE.encode()))

    def test_question_bypasses_tests(self):
        result = self.invoke("question")
        self.assertEqual(result["kind"], "question", result)
        self.assertFalse(result["tests"]["reproduction_failed"])
        self.assertFalse((self.root / "output/reproduction-test.log").exists())

    def test_question_can_be_discovered_after_reproduction(self):
        result = self.invoke("late-question")
        self.assertEqual(result["kind"], "question", result)
        self.assertTrue(result["tests"]["reproduction_failed"])
        self.assertFalse((self.root / "output/candidate.beam").exists())

    def test_agent_can_run_mix_without_its_build_artifacts_becoming_evidence(self):
        result = self.invoke("run-tests")
        self.assertEqual(result["kind"], "fix", result)
        self.assertTrue(result["tests"]["passed"])

    def test_existing_output_is_never_overwritten(self):
        self.invoke("question")
        evidence = (self.root / "output/proposal.json").read_bytes()
        with self.assertRaises(FileExistsError):
            self.invoke("question")
        self.assertEqual((self.root / "output/proposal.json").read_bytes(), evidence)

    def test_broad_sanitation_and_snapshot(self):
        repair.restore(self.workspace, {"mix.exs": repair.MIX.encode(),
                       "README.md": b"operator-only", "docs/design.md": b"operator-only",
                       "scripts/operator.py": b"operator-only", "lib/context.ex": b"# context"})
        args = argparse.Namespace(workspace=self.workspace, bundle=self.bundle,
                                  output=self.root / "output", scope="broad",
                                  command_json=python('''
import json
from pathlib import Path
assert not Path('README.md').exists()
assert not Path('docs').exists()
assert not Path('scripts').exists()
assert Path('lib/context.ex').exists()
assert 'defmodule ShippingEstimate' in Path('lib/shipping_estimate.ex').read_text()
Path('response.json').write_text(json.dumps({'kind':'question','question':'Which policy?', 'options':['A','B']}))
'''), reviewer_command_json=None, provider_host=["api.anthropic.com"],
                                  credential_env=[], timeout=30, max_output=200000)
        result = repair.repair(args)
        self.assertEqual(result["kind"], "question", result)

    def test_rejects_source_edit_before_reproduction(self):
        result = self.invoke("early")
        self.assertEqual(result["kind"], "failed")
        self.assertIn(repair.SOURCE, result["error"])
        self.assertTrue((self.root / "output/reproduce-response.json").exists())

    def test_rejects_changed_reproduction_in_fix_stage(self):
        result = self.invoke("test-change")
        self.assertEqual(result["kind"], "failed")
        self.assertIn(repair.REPRO, result["error"])

    def test_rejects_syntax_error_as_reproduction(self):
        result = self.invoke("syntax")
        self.assertEqual(result["kind"], "failed")
        self.assertIn("actual ExUnit", result["error"])

    def test_reviewer_cannot_see_builder_response(self):
        reviewer = python('''
import json
from pathlib import Path
assert not Path('response.json').exists()
assert not Path('reproduce-agent.log').exists()
assert not Path('fix-response.json').exists()
assert Path('test/reproduction_test.exs').exists()
Path('review.json').write_text(json.dumps({'verdict':'question','details':'Contract needs clarification.'}))
''')
        result = self.invoke(reviewer=reviewer)
        self.assertEqual(result["kind"], "fix", result)
        self.assertEqual(result["review"]["verdict"], "question")
        self.assertEqual(json.loads((self.root / "output/fix-response.json").read_text())["kind"], "fix")

    def test_invalid_reviewer_fails_closed(self):
        result = self.invoke(reviewer=python("from pathlib import Path; Path('review.json').write_text('{}')"))
        self.assertEqual(result["kind"], "failed", result)
        self.assertEqual(result["review"]["status"], "failed")

    def test_rejects_additional_module(self):
        result = self.invoke(candidate=FIXED + "\ndefmodule Extra do\nend\n")
        self.assertEqual(result["kind"], "failed", result)
        self.assertIn("BEAM", result["error"])

    def test_rejects_on_load(self):
        candidate = FIXED.replace("  def estimate", "  @on_load :init\n  def init, do: :ok\n  def estimate")
        result = self.invoke(candidate=candidate)
        self.assertEqual(result["kind"], "failed", result)
        self.assertIn("BEAM", result["error"])

    def test_compile_fifo_cannot_block_host_after_sandbox_exits(self):
        candidate = '''
unless File.exists?("mix.exs") do
  System.cmd("mkfifo", ["candidate.beam"])
  System.halt(0)
end
''' + FIXED
        result = self.invoke(candidate=candidate)
        self.assertEqual(result["kind"], "failed", result)
        self.assertIn("regular file", result["error"])

    def test_host_runs_full_project_without_widening_agent_context(self):
        repair.restore(self.workspace, {"mix.exs": repair.MIX.encode(),
            "test/test_helper.exs": b"ExUnit.start()\n",
            "test/integration_test.exs": b'''defmodule IntegrationTest do
  use ExUnit.Case
  test "separate integration gate", do: assert false
end
'''})
        self.before = repair.snapshot(self.workspace)
        result = self.invoke()
        self.assertEqual(result["kind"], "failed", result)
        self.assertIn("full-project", result["error"])

    def test_live_controller_runner_approval_and_hot_load(self):
        project = Path(__file__).resolve().parent.parent
        synthetic = SOURCE.replace('input["n"]', 'if(input["n"] == 7, do: raise("undefined"), else: input["n"])')
        repair.restore(self.workspace, {repair.SOURCE: synthetic.encode(),
                                       repair.CONTRACT: CONTRACT.encode()})
        (self.workspace / "scripts").mkdir()
        for name in ("repair.py", "sandbox.py"):
            shutil.copyfile(project / "scripts" / name, self.workspace / "scripts" / name)
        repair.write_json(self.workspace / "command.json", agent())
        script = '''
root = hd(System.argv())
[{ShippingEstimate, beam}] = Code.compile_file(Path.join(root, "lib/shipping_estimate.ex"))
command = Path.join(root, "command.json") |> File.read!() |> JSON.decode!()
Application.put_env(:regenerator, :engine, [root: root, initial_beam: beam,
  auto_repair: true, agent_command: command])
{:ok, _} = Application.ensure_all_started(:regenerator)
Logger.configure(level: :critical)
app = Process.whereis(Regenerator.Supervisor)
alias Regenerator.Engine
for _ <- 1..3, do: ({:error, :unavailable} = Engine.quote(%{"n" => 7}))
[{id, _}] = Map.to_list(Engine.cards())
wait = fn wait, expected, attempts ->
  case Engine.cards()[id].status do
    ^expected -> :ok
    :repair_failed -> raise inspect(Engine.cards()[id].proposal)
    _ when attempts > 0 -> Process.sleep(50); wait.(wait, expected, attempts - 1)
    other -> raise "unexpected state #{other}"
  end
end
wait.(wait, :proposed, 600)
{:error, :unavailable} = Engine.quote(%{"n" => 7})
card = Engine.cards()[id]
text = Regenerator.CLI.card(id, card)
true = String.contains?(text, "Independent review: skipped")
{:ok, :verifying} = Engine.decide(id, :approve, "test-operator")
wait.(wait, :loaded, 100)
21 = Engine.quote(%{"n" => 7})
^app = Process.whereis(Regenerator.Supervisor)
IO.puts("LIVE_WORKFLOW_OK")
'''
        result = subprocess.run(["mix", "run", "--no-start", "-e", script, "--", str(self.workspace)],
                                cwd=project, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("LIVE_WORKFLOW_OK", result.stdout)


if __name__ == "__main__":
    unittest.main()
