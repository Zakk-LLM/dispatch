#!/usr/bin/env python3
"""Offline public-entry recovery, path and integration scenarios."""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import signal
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent


class DispatchBehavior(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.tmp = Path(self.temp.name)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.env = os.environ | {
            "PATH": f"{self.bin}:{os.environ['PATH']}", "AGENT_START_STAGGER": "0",
            "AGENT_ORCHESTRATION_ENV": str(self.tmp / "config"),
            "AGENT_RECOVERY_ATTEMPTS": "3", "AGENT_RECOVERY_BACKOFF": "0",
            "OMP_REGISTRY_DIR": str(self.tmp / "registry"),
            "CODEX_REGISTRY_DIR": str(self.tmp / "registry"),
            "OPENCODE_REGISTRY_DIR": str(self.tmp / "registry"),
            "AGENT_SLOTS_DIR": str(self.tmp / "slots"),
            "AGENT_FALLBACK_PAIRS": "primary=mirror mirror=primary",
            "CALLS": str(self.tmp / "calls"), "SCENARIO": str(self.tmp / "scenario"),
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
        }
        (self.tmp / "config").write_text("")
        stub = '''#!/usr/bin/env python3
import json,os,pathlib,sys,time
engine=pathlib.Path(sys.argv[0]).name
args=sys.argv[1:]
calls=pathlib.Path(os.environ['CALLS'])
rows=calls.read_text().splitlines() if calls.exists() else []
scenario=json.loads(pathlib.Path(os.environ['SCENARIO']).read_text())
step=scenario[min(len(rows),len(scenario)-1)]
prompt=sys.stdin.read() if engine=='codex' else args[-1]
with calls.open('a') as f: f.write(json.dumps({'args':args,'cwd':os.getcwd(),'prompt':prompt})+'\\n')
artifact=prompt.split('Run artifacts: ',1)[1].splitlines()[0]
pathlib.Path(artifact,'engine.log').write_text('evidence')
if step.get('session',True):
 print(json.dumps({'type':'session','id':'session-one'} if engine=='omp' else
                  {'type':'thread.started','thread_id':'session-one'} if engine=='codex' else
                  {'type':'step_start','sessionID':'session-one'}),flush=True)
for number in range(step.get('tools',0)):
 print(json.dumps({'type':'tool_execution_end','toolCallId':str(number),'toolName':'read','isError':False} if engine=='omp' else
                  {'type':'item.completed','item':{'id':str(number),'type':'command_execution','exit_code':0,'status':'completed'}} if engine=='codex' else
                  {'type':'tool_use','part':{'callID':str(number),'tool':'read','state':{'status':'completed'}}}),flush=True)
usage=step.get('usage',0)
if engine=='omp': print(json.dumps({'type':'message_end','message':{'role':'assistant','usage':{'input':usage,'output':usage*2,'cost':{'total':usage/10}},'content':[]}}),flush=True)
elif engine=='codex': print(json.dumps({'type':'turn.completed','usage':{'input_tokens':usage,'output_tokens':usage*2}}),flush=True)
else: print(json.dumps({'type':'step_finish','part':{'tokens':{'input':usage,'output':usage*2},'cost':usage/10}}),flush=True)
if step.get('flush'):
 import signal
 def flush(sig,frame):
  time.sleep(1.5)
  pathlib.Path(args[args.index('-o')+1]).write_text('flushed after interrupt\\n')
  sys.exit(0)
 signal.signal(signal.SIGINT,flush)
if step.get('ignore_interrupt'):
 import signal
 signal.signal(signal.SIGINT,signal.SIG_IGN)
 pathlib.Path(os.environ['CALLS']+'.pid').write_text(str(os.getpid()))
if step.get('error'):
 print(step['error'],file=sys.stderr,flush=True)
else:
 if engine=='omp': print(json.dumps({'type':'message_end','message':{'role':'assistant','content':[{'type':'text','text':'finished'}]}}),flush=True)
 elif engine=='opencode': print(json.dumps({'type':'text','sessionID':'session-one','part':{'text':'finished'}}),flush=True)
 else: pathlib.Path(args[args.index('-o')+1]).write_text('finished\\n')
time.sleep(step.get('delay',0))
sys.exit(step.get('code',0))
'''
        for engine in ("omp", "codex", "opencode"):
            path = self.bin / engine
            path.write_text(stub)
            path.chmod(0o755)

    def invoke(self, args, **kwargs):
        return subprocess.run([str(arg) for arg in args], cwd=self.tmp, env=self.env,
                              text=True, capture_output=True, timeout=20, **kwargs)

    def agent(self, engine, scenario, timeout=8, extra=()):
        (self.tmp / "calls").unlink(missing_ok=True)
        (self.tmp / "scenario").write_text(json.dumps(scenario))
        workspace = self.tmp / "workspace"
        workspace.mkdir(exist_ok=True)
        (self.tmp / "prompt.md").write_text("task context")
        result = self.invoke([ROOT / "scripts/agent.sh", "--engine", engine,
                              "--run-dir", "run", "--label", "worker", "--cwd", "workspace",
                              "--prompt-file", "prompt.md", "--model", "primary",
                              "--admission", "off", "--timeout", timeout, *extra])
        calls = [json.loads(line) for line in (self.tmp / "calls").read_text().splitlines()]
        out = self.tmp / "run/agents/worker"
        meta = json.loads((out / "meta.json").read_text())
        return result, calls, meta, out

    def test_relative_paths_all_adapters(self):
        for engine in ("omp", "codex", "opencode"):
            with self.subTest(engine=engine):
                result, calls, meta, out = self.agent(engine, [{}])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(calls[0]["cwd"], str(self.tmp / "workspace"))
                self.assertIn("task context", calls[0]["prompt"])
                self.assertIn(str(out / "artifacts"), calls[0]["prompt"])
                self.assertEqual(Path(meta["result_file"]).read_text().strip(), "finished")
                self.assertEqual((out / "artifacts/engine.log").read_text(), "evidence")
                self.assertFalse((self.tmp / "workspace/engine.log").exists())

    def test_recovery_classification_and_session(self):
        cases = [("Selected model is at capacity", "primary", 2),
                 ("rate limit exceeded (429)", "primary", 2),
                 ("You have exceeded your usage limit", "mirror", 2),
                 ("insufficient_quota", "mirror", 2),
                 ("401 unauthorized; quota unavailable", "primary", 1),
                 ("invalid model", "primary", 1)]
        for engine in ("omp", "codex", "opencode"):
            for error, model, count in cases:
                with self.subTest(engine=engine, error=error):
                    result, calls, meta, out = self.agent(engine, [{"error": error, "code": 1}, {}])
                    self.assertEqual(len(calls), count)
                    self.assertEqual(result.returncode, 0 if count == 2 else 1, result.stderr)
                    self.assertEqual(meta["model"], model)
                    if count == 2:
                        self.assertIn("session-one", calls[1]["args"])
                        self.assertEqual(calls[0]["cwd"], calls[1]["cwd"])
                        self.assertTrue(calls[1]['prompt'].startswith('Your previous attempt stopped because of '))
                        self.assertIn('Continue from where you stopped;', calls[1]['prompt'])
                        self.assertNotIn('task context', calls[1]['prompt'])
                        self.assertIn(error, (out / "stderr.attempt-1.log").read_text())
                        self.assertTrue((out / "events.attempt-1.jsonl").exists())

    def test_bounded_resume_deadline_and_opt_out(self):
        for engine in ("omp", "codex", "opencode"):
            with self.subTest(engine=engine):
                result, calls, meta, out = self.agent(engine, [{"error": "at capacity", "code": 1}])
                self.assertEqual((result.returncode, len(calls)), (1, 3))
                deadlines = {row["deadline"] for row in meta["recovery_attempts"]}
                self.assertEqual(len(deadlines), 1)
                self.assertEqual(deadlines.pop(), json.loads((out / "started.json").read_text())["deadline"])
                result, calls, _, _ = self.agent(engine, [{"error": "quota exhausted", "code": 1}])
                self.assertEqual((result.returncode, len(calls)), (1, 2))  # no mirror cycle
                result, calls, _, _ = self.agent(engine, [{"error": "at capacity", "code": 1}], extra=["--no-recovery"])
                self.assertEqual((result.returncode, len(calls)), (1, 1))
                started = time.monotonic()
                result, calls, meta, _ = self.agent(engine, [{"error": "at capacity", "code": 1, "delay": 0.6}, {"delay": 3}], timeout=2)
                self.assertEqual(result.returncode, 124, result.stderr)
                self.assertTrue(meta["timed_out"])
                self.assertLess(time.monotonic() - started, 3.5)
                result, calls, _, _ = self.agent(engine, [{"error": "at capacity", "code": 1, "session": False}])
                self.assertEqual((result.returncode, len(calls)), (1, 1))
                self.env["AGENT_RECOVERY_BACKOFF"] = "5"
                result, calls, meta, _ = self.agent(engine, [{"error": "at capacity", "code": 1}], timeout=1)
                self.assertEqual((result.returncode, len(calls)), (124, 1))
                self.assertTrue(meta["timed_out"])
                self.env["AGENT_RECOVERY_BACKOFF"] = "0"

    def test_recovery_keeps_tool_budget(self):
        for engine in ("omp", "codex", "opencode"):
            with self.subTest(engine=engine):
                result, calls, meta, _ = self.agent(engine,
                    [{"error": "at capacity", "code": 1, "tools": 2}, {"tools": 2}],
                    extra=["--max-tools", "3"])
                self.assertEqual(result.returncode, 66, result.stderr)
                self.assertTrue(meta["over_budget"])
                self.assertEqual(meta["tool_calls"], 4)

    def test_recovery_usage_all_attempts(self):
        for engine in ('omp', 'codex', 'opencode'):
            with self.subTest(engine=engine):
                result, calls, meta, _ = self.agent(engine,
                    [{'error':'at capacity','code':1,'usage':3}, {'usage':5}])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(meta['usage']['input_tokens'], 8)
                self.assertEqual(meta['usage']['output_tokens'], 16)
                if engine != 'codex':
                    self.assertAlmostEqual(meta['usage']['cost'], .8)

    def test_usage_before_first_attempt(self):
        out = self.tmp / 'empty-run'
        out.mkdir()
        code = 'import pathlib, sys; sys.path.insert(0, sys.argv[1]); import recovery; print(recovery.aggregate_usage(pathlib.Path(sys.argv[2]), "omp"))'
        result = subprocess.run(['python3', '-c', code, str(ROOT / 'scripts'), str(out)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_context_errors_are_terminal(self):
        for engine in ('omp','codex','opencode'):
            for error in ('token limit exceeded', 'maximum context length; usage limit exceeded'):
                with self.subTest(engine=engine,error=error):
                    result, calls, _, _ = self.agent(engine, [{'error':error,'code':1}, {}])
                    self.assertEqual((result.returncode,len(calls)), (1,1))

    def test_fork_preserved_until_new_session(self):
        result, calls, _, _ = self.agent('opencode',
            [{'error':'at capacity','code':1,'session':False},
             {'error':'at capacity','code':1}, {}], extra=['--resume','parent','--fork'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('--fork', calls[1]['args'])
        self.assertEqual(calls[1]['args'][calls[1]['args'].index('-s')+1], 'parent')
        self.assertNotIn('--fork', calls[2]['args'])
        self.assertEqual(calls[2]['args'][calls[2]['args'].index('-s')+1], 'session-one')

    def test_codex_interrupt_flush_grace(self):
        result, _, meta, out = self.agent('codex', [{'flush':True,'delay':20}], timeout=2)
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertTrue(meta['timed_out'])
        self.assertEqual((out/'last.txt').read_text(), 'flushed after interrupt\n')

    def test_budget_hard_kill_reaps_engine_group(self):
        for engine in ('omp','codex','opencode'):
            with self.subTest(engine=engine):
                result, _, meta, _ = self.agent(engine,
                    [{'tools':2,'ignore_interrupt':True,'delay':20}], timeout=15,
                    extra=['--max-tools','1'])
                self.assertEqual(result.returncode, 66, result.stderr)
                pid = int((self.tmp/'calls.pid').read_text())
                stat = Path(f'/proc/{pid}/stat')
                alive = stat.exists() and stat.read_text().rsplit(')',1)[1].split()[0] != 'Z'
                if alive:
                    os.killpg(pid, signal.SIGKILL)
                self.assertFalse(alive, 'engine survived watcher hard kill')

    def git(self, repo, *args):
        result = self.invoke(["git", "-C", repo, *args])
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def fixture(self, suffix=''):
        repo, run = self.tmp / ('repo'+suffix), self.tmp / ('run'+suffix)
        repo.mkdir()
        self.git(repo, "init", "-b", "main")
        self.git(repo, "config", "user.name", "Test")
        self.git(repo, "config", "user.email", "test@example.invalid")
        self.git(repo, "config", "commit.gpgsign", "false")
        (repo / "tracked").write_text("before\n")
        self.git(repo, "add", "tracked")
        self.git(repo, "commit", "-m", "base")
        base = self.git(repo, "rev-parse", "HEAD")
        wt = run / "worktrees/worker"
        wt.parent.mkdir(parents=True)
        self.git(repo, "worktree", "add", "-b", "codex/worker", str(wt))
        out = run / "agents/worker"
        out.mkdir(parents=True)
        (out / "meta.json").write_text(json.dumps({"label": "worker", "cwd": str(wt),
            "worktree_branch": "codex/worker", "base_sha": base}))
        (wt / "tracked").write_text("after\n")
        (wt / "junk.log").write_text("scratch\n")
        return repo, run, wt, base

    def merge(self, repo, run, *extra):
        return self.invoke([ROOT / "scripts/merge.sh", "--run-dir", run, "--repo", repo,
                            "--into", "main", "--check", "test \"$(cat tracked)\" = after", *extra])

    def test_untracked_junk_and_previously_staged_files(self):
        repo, run, wt, base = self.fixture()
        (wt / "new").write_text("selected\n")
        (wt / "previous").write_text("staged\n")
        self.git(wt, "add", "previous")
        result = self.merge(repo, run, "--include", "worker:new", "--artifact-check", "test -z \"$(git diff --cached --name-only -- junk.log)\"")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git(repo, "ls-tree", "--name-only", "HEAD").splitlines(), ["new", "previous", "tracked"])
        self.assertTrue((wt / "junk.log").exists())
        self.assertIn("previous", result.stderr + result.stdout)

    def test_staging_failure_stops(self):
        repo, run, wt, base = self.fixture()
        result = self.merge(repo, run, "--include", "worker:missing")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git(repo, "rev-parse", "HEAD"), base)
        self.assertEqual(self.git(wt, "rev-parse", "HEAD"), base)
        self.assertEqual((wt / "tracked").read_text(), "after\n")

    def test_literal_includes_and_untracked_opt_out(self):
        repo, run, wt, base = self.fixture()
        result = self.merge(repo, run)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('junk.log', result.stderr)
        self.assertEqual(self.git(wt,'rev-parse','HEAD'), base)
        for name in ('[abc].txt','a.txt','*.log',':(glob)*'):
            (wt/name).write_text(name)
        result = self.merge(repo,run,'--include','worker:[abc].txt',
                            '--include','worker:*.log','--include','worker::(glob)*')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(self.git(repo,'ls-tree','--name-only','HEAD').splitlines(),
                         ['*.log',':(glob)*','[abc].txt','tracked'])
        (wt/'tracked').write_text('after\n')
        result = self.merge(repo,run,'--ignore-untracked')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertTrue((wt/'junk.log').exists())

    def test_worktree_cleanup_stable_anchor_and_failures(self):
        for action in ('--remove-all','--remove-merged'):
            with self.subTest(action=action):
                repo, run, wt, base = self.fixture(action)
                (wt/'junk.log').unlink()
                self.git(wt,'restore','tracked')
                second = run/'worktrees/second'
                self.git(repo,'worktree','add','-b','codex/second',str(second))
                command = [ROOT/'scripts/worktrees.sh',run,action]
                if action == '--remove-merged': command.append('main')
                (second/'dirty').write_text('keep')
                result = self.invoke(command)
                self.assertNotEqual(result.returncode,0,result.stderr)
                (second/'dirty').unlink()
                result = self.invoke(command)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertFalse(wt.exists())
                self.assertFalse(second.exists())
                self.assertEqual(self.git(repo,'branch','--list','codex/*'), '')
    def test_publish_remote_head(self):
        repo, run, wt, base = self.fixture()
        remote = self.tmp / "remote.git"
        self.git(repo, "init", "--bare", str(remote))
        self.git(repo, "remote", "add", "local", str(remote))
        result = self.merge(repo, run, '--ignore-untracked', "--push", "local")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git(remote, "rev-parse", "refs/heads/main"), self.git(repo, "rev-parse", "HEAD"))

    def test_wrong_branch_interrupted_state_and_duplicate_owner(self):
        repo, run, wt, base = self.fixture()
        self.git(wt, "switch", "-c", "wrong")
        self.assertNotEqual(self.merge(repo, run).returncode, 0)
        self.assertEqual(self.git(repo, "rev-parse", "HEAD"), base)
        self.git(wt, "switch", "codex/worker")
        marker = Path(self.git(wt, "rev-parse", "--path-format=absolute", "--git-path", "rebase-merge"))
        marker.mkdir()
        self.assertNotEqual(self.merge(repo, run).returncode, 0)
        marker.rmdir()
        common = Path(self.git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir"))
        with (common / "dispatch.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertNotEqual(self.merge(repo, run).returncode, 0)
            result = self.invoke([ROOT / "scripts/worktrees.sh", run, "--rebase", "main"])
            self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git(wt, "rev-parse", "HEAD"), base)

    def test_artifact_policy_failure_and_once_only_gate(self):
        repo, run, wt, base = self.fixture()
        result = self.merge(repo, run, "--include", "worker:junk.log", "--artifact-check", "exit 1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git(wt, "rev-parse", "HEAD"), base)
        self.git(wt, "reset", "--", "junk.log")
        second = run / "worktrees/second"
        self.git(repo, "worktree", "add", "-b", "codex/second", str(second))
        (second / "second").write_text("second output\n")
        out = run / "agents/second"
        out.mkdir()
        (out / "meta.json").write_text(json.dumps({"label": "second", "cwd": str(second),
            "worktree_branch": "codex/second", "base_sha": base}))
        result = self.merge(repo, run, '--ignore-untracked', "--include", "second:second", "--final-check",
                            "test -f second && printf 'gate\\n' >> gate-count")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((repo / "gate-count").read_text(), "gate\n")

    def test_scarce_resource_checks_are_not_run(self):
        repo, run, wt, base = self.fixture()
        (run / "agents/worker/prompt.md").write_text("Write: tracked junk.log\n")
        for flag, command in (("--check", "echo waiting for shared lock; exit 77"),
                              ("--not-run", "e2e: shared lock unavailable")):
            result = self.invoke([ROOT / "scripts/verify.sh", run, "worker", "--check", "true", flag, command])
            self.assertEqual(result.returncode, 1, result.stderr)
            report = json.loads((run / "agents/worker/verify.json").read_text())
            self.assertEqual(report["verdict"], "not-verified")
            self.assertEqual(report["checks"][-1]["status"], "not run")

    def test_waiters_quiet_completion_and_finalisation_grace(self):
        run = self.tmp/'waiting'
        agent = run/'agents/worker'
        agent.mkdir(parents=True)
        live = subprocess.Popen(['sleep','30'])
        self.addCleanup(lambda: live.poll() is None and live.terminate())
        now = time.time()
        started = {'engine':'omp','pid':live.pid,'started_at':now-1200,
                   'deadline':now+20,'timeout_s':1220}
        (agent/'started.json').write_text(json.dumps(started))
        events = agent/'events.jsonl'
        events.write_text('{"type":"tool_execution_start","toolName":"bash"}\n')
        os.utime(events,(now-1200,now-1200))
        watch = [ROOT/'scripts/watch.sh',run,'--timeout','0']
        result = self.invoke(watch)
        self.assertIn('QUIET',result.stdout)
        self.assertIn('EXPIRING',result.stdout)
        self.assertNotIn('STALLED',result.stdout)
        self.assertEqual(self.invoke(watch).returncode,1)
        # wait.sh must emit the notice without returning before the actual completion.
        waiter = subprocess.Popen([str(ROOT/'scripts/wait.sh'),str(run),
            '--timeout','4','--interval','.05'],env=self.env,text=True,
            stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        self.addCleanup(lambda: waiter.poll() is None and waiter.kill())
        time.sleep(.2)
        self.assertIsNone(waiter.poll())
        live.terminate(); live.wait()
        self.assertEqual(self.invoke(watch).returncode,1)
        (agent/'meta.json').write_text('{"exit_code":0}')
        stdout, stderr = waiter.communicate(timeout=4)
        self.assertEqual(waiter.returncode,0,stderr)
        self.assertEqual(stdout.count('QUIET'),1)
        self.assertIn('worker OK',stdout)
        self.assertNotIn('STALLED',stdout)
        self.assertIn('OK',self.invoke(watch).stdout)

    def test_waiters_dead_after_grace(self):
        run = self.tmp/'dead'
        agent = run/'agents/worker'
        agent.mkdir(parents=True)
        (agent/'started.json').write_text(json.dumps({'engine':'omp','pid':99999999,
            'started_at':time.time()-20,'deadline':time.time()+5,'timeout_s':25}))
        result = self.invoke([ROOT/'scripts/wait.sh',run,'--interval','.05','--timeout','7'])
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('STALLED process gone',result.stdout)
        watch = [ROOT/'scripts/watch.sh',run,'--timeout','7','--interval','1']
        result = self.invoke(watch)
        self.assertIn('EXPIRING',result.stdout)
        self.assertNotIn('STALLED',result.stdout)
        result = self.invoke(watch)
        self.assertIn('STALLED process gone',result.stdout)
        self.assertEqual(self.invoke([*watch[:-4],'--timeout','0']).returncode,2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
