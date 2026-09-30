import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from layout import SingleApp, eligible


def client(address="0xab", **changes):
    return dict(dict(address=address, stableId=address, pid=1, initialClass="test", mapped=True,
                     hidden=False, floating=False, pinned=False, monitor=0, workspace={"id": 1},
                     fullscreen=0, fullscreenClient=0, grouped=[]), **changes)


class LayoutTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "lease.json"
        self.layout = SingleApp(self.path)
        self.active = client()
        self.clients = [self.active]
        self.calls = []
        self.patch = patch("layout.run", side_effect=self.run_command)
        self.patch.start()
        self.addCleanup(self.patch.stop)

    def run_command(self, *args):
        self.calls.append(args)
        values = {"monitors": [{"id": 0, "name": "eDP-1"}], "clients": self.clients, "activewindow": self.active}
        if args[1] == "-j":
            return SimpleNamespace(stdout=json.dumps(values[args[2]]))
        return SimpleNamespace(stdout="ok")

    def test_single_app_and_restore_preserves_client_state(self):
        self.active["fullscreenClient"] = 1
        self.layout.reconcile(True)
        self.assertIn("internal=1, client=1", self.calls[-1][-1])
        self.assertTrue(self.path.exists())
        self.layout.reconcile(False)
        self.assertIn("internal=0, client=1", self.calls[-1][-1])
        self.assertFalse(self.layout.windows)

    def test_dialog_external_pinned_special_and_group_not_modified(self):
        for updates in ({"floating": True}, {"monitor": 1}, {"pinned": True},
                        {"workspace": {"id": -2}}, {"grouped": ["0xaa"]}, {"fullscreen": 2}):
            self.active = client(**updates)
            self.clients = [self.active]
            self.layout.reconcile(True)
        self.assertFalse(any(c[1] == "eval" for c in self.calls))

    def test_recover_reload_and_ignore_reused_address(self):
        self.layout.reconcile(True)
        self.layout = SingleApp(self.path)
        self.layout.restore(self.clients)
        self.assertIn("internal=0", self.calls[-1][-1])
        self.layout.reconcile(True)
        self.active["stableId"] = "replacement"
        before = len(self.calls)
        self.layout.restore(self.clients)
        self.assertEqual(before, len(self.calls))
        self.assertFalse(self.layout.windows)

    def test_window_moved_to_external_is_restored(self):
        self.layout.reconcile(True)
        self.active["monitor"] = 1
        self.layout.reconcile(True)
        self.assertFalse(self.layout.windows)
        self.assertTrue(any("internal=0" in str(c) for c in self.calls))

    def test_failed_dispatch_keeps_write_ahead_journal(self):
        with patch.object(self.layout, "set_state", side_effect=RuntimeError("failed")):
            with self.assertRaises(RuntimeError):
                self.layout.reconcile(True)
        self.assertIn("0xab", json.loads(self.path.read_text())["windows"])

    def test_restore_original_maximized_after_normal_states(self):
        self.clients.append(client("0xcd", fullscreen=1))
        self.layout.reconcile(True)
        self.layout.restore(self.clients)
        self.assertIn('address:0xcd', self.calls[-1][-1])
        self.assertIn('internal=1', self.calls[-1][-1])

    def test_excluded_siblings_are_not_journaled_or_restored(self):
        for changes in ({"floating": True}, {"pinned": True}, {"grouped": ["0xee"]}):
            with self.subTest(changes=changes):
                self.clients = [self.active, client("0xcd", fullscreen=1, **changes)]
                self.layout.reconcile(True)
                self.assertNotIn("0xcd", self.layout.windows)
                self.layout.restore(self.clients)
        self.assertFalse(any('address:0xcd' in str(call) for call in self.calls))

    def test_preexisting_fullscreen_sibling_is_not_managed_when_focused(self):
        sibling = client("0xcd", fullscreen=2)
        self.clients.append(sibling)
        self.layout.reconcile(True)
        self.active = sibling
        before = len([c for c in self.calls if c[1] == "eval"])
        self.layout.reconcile(True)
        self.assertEqual(before, len([c for c in self.calls if c[1] == "eval"]))

    def test_wrong_session_never_replays_addresses(self):
        self.layout.reconcile(True)
        with patch.dict("os.environ", {"HYPRLAND_INSTANCE_SIGNATURE": "new-session"}):
            other = SingleApp(self.path)
        self.assertFalse(other.windows)

    def test_failed_dispatch_retries_same_focused_window(self):
        with patch.object(self.layout, "set_state", side_effect=[RuntimeError("busy"), None]) as dispatch:
            with self.assertRaises(RuntimeError):
                self.layout.reconcile(True)
            self.layout.reconcile(True)
            self.assertEqual(dispatch.call_count, 2)

    def test_closed_window_lease_removed_with_no_active_window(self):
        self.layout.reconcile(True)
        self.active, self.clients = {}, []
        self.layout.reconcile(True)
        self.assertFalse(self.layout.windows)

    def test_managed_window_can_request_real_fullscreen(self):
        self.layout.reconcile(True)
        self.active["fullscreen"] = 2
        before = len([c for c in self.calls if c[1] == "eval"])
        self.layout.reconcile(True)
        self.assertEqual(before, len([c for c in self.calls if c[1] == "eval"]))

    def test_same_window_becoming_floating_is_restored(self):
        self.layout.reconcile(True)
        self.active["floating"] = True
        self.layout.reconcile(True)
        self.assertFalse(self.layout.windows)

    def test_new_window_inheriting_managed_maximization_restores_to_tiling(self):
        self.layout.reconcile(True)
        newcomer = client("0xcd", fullscreen=1, fullscreenClient=1)
        self.clients.append(newcomer)
        self.active = newcomer
        self.layout.reconcile(True)
        self.assertEqual(self.layout.windows["0xcd"]["internal"], 0)
        self.assertEqual(self.layout.windows["0xcd"]["client"], 0)
        self.layout.reconcile(False)
        self.assertFalse(self.layout.windows)

    def test_existing_maximized_window_is_not_mistaken_for_inheritance(self):
        old = client("0xcd", fullscreen=1, workspace={"id": 2})
        self.clients.append(old)
        self.layout.reconcile(True)
        old["workspace"] = {"id": 1}
        self.active = old
        self.layout.reconcile(True)
        self.assertNotIn("0xcd", self.layout.windows)

    def test_reused_address_is_journaled_with_new_identity(self):
        self.layout.reconcile(True)
        self.active["stableId"] = "new-window"
        self.layout.reconcile(True)
        self.assertEqual(self.layout.windows["0xab"]["identity"][0], "new-window")

    def test_mapped_window_seen_before_focus_still_inherits_correctly(self):
        self.layout.reconcile(True)
        newcomer = client("0xcd", fullscreen=1, fullscreenClient=1)
        self.clients.append(newcomer)
        self.layout.reconcile(True)  # openwindow, still focused on the old app
        newcomer.update(fullscreen=1, fullscreenClient=1)
        self.active = newcomer
        self.layout.reconcile(True)
        self.assertEqual(self.layout.windows["0xcd"]["internal"], 0)

    def test_reconcile_force_refreshes_maximized_window(self):
        self.layout.reconcile(True)
        self.active["fullscreen"] = 1
        self.calls.clear()
        # Normal reconcile does nothing if already fullscreen
        self.layout.reconcile(True, force=False)
        self.assertEqual(len([c for c in self.calls if c[1] == "eval"]), 0)
        # Forced reconcile unsets and resets to force geometry recalculation
        self.layout.reconcile(True, force=True)
        eval_calls = [c[-1] for c in self.calls if c[1] == "eval"]
        self.assertEqual(len(eval_calls), 2)
        self.assertIn("internal=0", eval_calls[0])
        self.assertIn("internal=1", eval_calls[1])

    def test_dispatch_address_validation(self):
        with self.assertRaises(ValueError):
            self.layout.set_state('bad"address', 0, 0)


if __name__ == "__main__":
    unittest.main()
