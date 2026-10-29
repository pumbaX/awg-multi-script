"""API lock failures never dispatch mutations; all state lives in sandbox.py."""
import fcntl
import json
from pathlib import Path
import subprocess
import sys
import unittest

from sandbox import ENV, PRELUDE, TMP, ROOT


class LockTests(unittest.TestCase):
    def setUp(self):
        self.state = Path(ROOT) / "var/lib/awg2"
        self.state.mkdir(parents=True, exist_ok=True)
        self.lock = self.state / "api.lock"
        if self.lock.is_file():
            self.lock.unlink()
        self.marker = Path(TMP) / "dispatched"
        self.marker.unlink(missing_ok=True)

    def run_api(self, command="client del alice", prelude="", dispatch=""):
        # Use the actual api_main, dispatcher and JSON envelope, stubbing only
        # host preparation and command bodies. No VPN operation can run here.
        code = PRELUDE + r'''
need_cmds() { :; }
helpers_refresh() { :; }
expire_watchdog() { :; }
antiscan_watchdog() { :; }
update_channel_init() { :; }
_api_client() { echo mutated > "$MARKER"; printf '{"changed":true}' > "$API_DATA"; }
_api_clients() { printf '[]' > "$API_DATA"; }
''' + prelude + "\n" + dispatch + "\napi_main " + command
        proc = subprocess.run(["bash", "-c", code], env=dict(ENV, MARKER=str(self.marker)),
                              capture_output=True, text=True, timeout=20)
        self.assertEqual(len(proc.stdout.splitlines()), 1, proc.stdout + proc.stderr)
        return proc, json.loads(proc.stdout)

    def assert_denied(self, proc, result, rc, message):
        self.assertEqual(proc.returncode, rc, result)
        self.assertFalse(result["ok"], result)
        self.assertEqual(result["rc"], rc, result)
        self.assertIn(message, result["error"])
        self.assertFalse(self.marker.exists())

    def test_directory_lock_path_and_readonly(self):
        self.lock.mkdir()
        try:
            proc, result = self.run_api()
            self.assert_denied(proc, result, 73, "файл блокировки")
            proc, result = self.run_api("clients list")
            self.assertEqual(proc.returncode, 0, result)
            self.assertTrue(result["ok"])
            self.assertEqual(result["data"], [])
        finally:
            self.lock.rmdir()

    def test_unopenable_file(self):
        # A symlink to a directory is deterministic even when tests run as root.
        self.lock.symlink_to(self.state, target_is_directory=True)
        try:
            proc, result = self.run_api()
            self.assert_denied(proc, result, 73, "файл блокировки")
        finally:
            self.lock.unlink()

    def test_parent_directory_failure(self):
        blocker = Path(TMP) / "not-a-directory"
        blocker.write_text("file")
        proc, result = self.run_api(prelude=f'STATE_DIR="{blocker}/child"')
        self.assert_denied(proc, result, 73, "каталог блокировки")

    def test_timeout_and_operation_after_release(self):
        with self.lock.open("a") as holder:
            fcntl.flock(holder, fcntl.LOCK_EX)
            proc, result = self.run_api(prelude="API_LOCK_WAIT=0.1")
            self.assert_denied(proc, result, 75, "другая операция")
        proc, result = self.run_api()
        self.assertEqual(proc.returncode, 0, result)
        self.assertTrue(result["ok"])
        self.assertTrue(self.marker.exists())
        # The API process has exited: descriptor and flock are released.
        with self.lock.open("a") as holder:
            fcntl.flock(holder, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_lock_is_held_throughout_dispatch(self):
        dispatch = r'''
_api_client() {
  flock -n "$API_LOCK" true && { err "lock not held"; return 99; }
  echo mutated > "$MARKER"
  printf '{"changed":true}' > "$API_DATA"
}
'''
        proc, result = self.run_api(dispatch=dispatch)
        self.assertEqual(proc.returncode, 0, result)
        self.assertTrue(self.marker.exists())

    def test_failed_flock_closes_descriptor(self):
        proc, result = self.run_api(prelude=r'''
flock() { return 1; }
''', dispatch=r'''
eval "$(declare -f _api_lock | sed '1s/_api_lock/_api_lock_original/')"
_api_lock() {
  local rc=0
  _api_lock_original "$@" || rc=$?
  if ( : >&8 ) 2>/dev/null; then err "failed lock left fd 8 open"; return 99; fi
  return "$rc"
}
''')
        self.assert_denied(proc, result, 75, "другая операция")


if __name__ == "__main__":
    unittest.main(argv=sys.argv[:1])
