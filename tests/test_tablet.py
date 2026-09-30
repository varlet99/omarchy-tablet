from types import SimpleNamespace
import copy
import json
import os
from pathlib import Path
import select
import tempfile
import unittest
from unittest.mock import patch

from install import install, restore
from tablet import Backend, physical_keyboard_present, tablet_mode


def device(name, path="/devices/pci/usb1/input1", handlers="kbd event1"):
    return f'N: Name="{name}"\nS: Sysfs={path}\nH: Handlers={handlers}\n'


class DetectionTests(unittest.TestCase):
    def test_cover_attach_detach_with_virtual_devices_remaining(self):
        virtual = device("Murmure virtual keyboard", "/devices/virtual/input/input2")
        buttons = device("Surface Pro 3/4 Buttons")
        base = virtual + "\n" + buttons
        self.assertFalse(physical_keyboard_present(base))
        self.assertTrue(physical_keyboard_present(base + "\n" + device("Microsoft Surface Type Cover Keyboard")))

    def test_usb_keyboard_and_touchpad_are_distinct(self):
        self.assertTrue(physical_keyboard_present(device("USB Keyboard")))
        self.assertFalse(physical_keyboard_present(device("Type Cover Touchpad", handlers="mouse0 event2")))

    def test_key_capabilities_detect_a_keyboard_without_keyboard_in_name(self):
        mask = sum(1 << code for code in (28, 30, 44, 57))
        self.assertTrue(physical_keyboard_present(device("Logitech K380") + f"B: KEY={mask:x}\n"))
        self.assertFalse(physical_keyboard_present(device("Fake Keyboard Consumer") + "B: KEY=100\n"))

    def test_modes(self):
        self.assertFalse(tablet_mode("auto", True))
        self.assertTrue(tablet_mode("auto", False))
        self.assertTrue(tablet_mode("tablet", True))
        self.assertFalse(tablet_mode("desktop", False))


class PersistenceTests(unittest.TestCase):
    def test_update_and_restore_preserve_unrelated_settings(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            config_dir = root / "config"
            state_dir = root / "state"
            config_file = config_dir / "omarchy/shell.json"
            config_file.parent.mkdir(parents=True)
            original = {"version": 1, "idle": {"lock": 300}, "plugins": [{"id": "other.plugin"}], "bar": {"position": "right", "layout": {"left": [{"id": "omarchy.menu"}]}}}
            config_file.write_text(json.dumps(original))
            source = Path(__file__).resolve().parents[1]
            install(config_dir, state_dir, source, activate=False)
            install(config_dir, state_dir, source, activate=False)
            changed = json.loads(config_file.read_text())
            changed["idle"]["lock"] = 600
            config_file.write_text(json.dumps(changed))
            restore(config_dir, state_dir, activate=False)
            result = json.loads(config_file.read_text())
            self.assertEqual(result["bar"], original["bar"])
            self.assertEqual(result["idle"]["lock"], 600)
            self.assertEqual(result["plugins"], original["plugins"])

    def test_restore_does_not_replace_a_newly_selected_bar(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            f = root / "omarchy/shell.json"
            f.parent.mkdir()
            config = {"version": 1, "bar": {"id": "another.bar"}, "plugins": []}
            f.write_text(json.dumps(config))
            restore(root, root, activate=False)
            self.assertEqual(json.loads(f.read_text()), config)

    def test_invalid_mode_does_not_write_preferences(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict("os.environ", {"XDG_RUNTIME_DIR": folder}):
            backend = Backend(Path(folder) / "state")
            with self.assertRaises(ValueError):
                backend.command({"action": "mode", "value": "invalid"})
            self.assertFalse(backend.preferences_path.exists())

    def test_favorites_with_spaces_round_trip(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict("os.environ", {"XDG_RUNTIME_DIR": folder}):
            backend = Backend(Path(folder) / "state")
            backend.command({"action": "favorite", "value": "Google Photos"})
            again = Backend(Path(folder) / "state")
            self.assertIn("Google Photos", again.preferences["favorites"])
            again.command({"action": "favorite", "value": "Google Photos"})
            self.assertNotIn("Google Photos", again.preferences["favorites"])

    def test_auto_rotate_and_rotation_lock_preferences(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict("os.environ", {"XDG_RUNTIME_DIR": folder}):
            backend = Backend(Path(folder) / "state")
            self.assertTrue(backend.preferences["autoRotate"])
            self.assertFalse(backend.preferences["rotationLocked"])
            backend.command({"action": "autoRotate", "value": False})
            backend.command({"action": "rotationLock", "value": True})
            self.assertFalse(backend.preferences["autoRotate"])
            self.assertTrue(backend.preferences["rotationLocked"])
            again = Backend(Path(folder) / "state")
            self.assertFalse(again.preferences["autoRotate"])
            self.assertTrue(again.preferences["rotationLocked"])
            state = again.state()
            self.assertFalse(state["autoRotate"])
            self.assertTrue(state["rotationLocked"])
            again.command({"action": "rotationLock", "value": "toggle"})
            self.assertFalse(again.preferences["rotationLocked"])

    def test_rotate_configures_monitor_and_touch_devices(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict("os.environ", {"XDG_RUNTIME_DIR": folder}):
            backend = Backend(Path(folder) / "state")
            calls = []
            def fake_run(*args, **kwargs):
                calls.append(args)
                if len(args) >= 3 and args[1] == "-j" and args[2] == "monitors":
                    return SimpleNamespace(stdout=json.dumps([{"name": "eDP-1", "scale": 1.6, "transform": 0}]), returncode=0)
                if len(args) >= 3 and args[1] == "-j" and args[2] == "devices":
                    return SimpleNamespace(stdout=json.dumps({"touch": [{"name": "elan-touch"}], "tablets": [{"name": "elan-stylus"}]}), returncode=0)
                return SimpleNamespace(stdout="ok", returncode=0)

            with patch("tablet.run", side_effect=fake_run):
                success = backend.rotate(1)
                self.assertTrue(success)
                self.assertEqual(backend.current_transform, 1)
                self.assertTrue(backend.layout_dirty)
                self.assertTrue(backend.layout_force)
                eval_commands = [c[2] for c in calls if len(c) >= 3 and c[0] == "hyprctl" and c[1] == "eval"]
                self.assertTrue(any("hl.monitor" in cmd and "transform=1" in cmd and 'output="eDP-1"' in cmd for cmd in eval_commands))
                self.assertTrue(any("hl.config" in cmd and "touchdevice" in cmd and "transform = 1" in cmd for cmd in eval_commands))
                self.assertTrue(any("hl.device" in cmd and 'name = "elan-touch"' in cmd and "transform = 1" in cmd for cmd in eval_commands))
                self.assertTrue(any("hl.device" in cmd and 'name = "elan-stylus"' in cmd and "transform = 1" in cmd for cmd in eval_commands))

    def test_wakeup_pipe(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict("os.environ", {"XDG_RUNTIME_DIR": folder}):
            backend = Backend(Path(folder) / "state")
            backend.wakeup()
            r, _, _ = select.select([backend._wake_r], [], [], 0.1)
            self.assertIn(backend._wake_r, r)
            os.read(backend._wake_r, 10)

    def test_failed_keyboard_start_restores_input_method(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict("os.environ", {"XDG_RUNTIME_DIR": folder}):
            backend = Backend(Path(folder) / "state")
            calls = []
            def fake_run(*args, **kwargs):
                calls.append(args)
                if args[0] == "systemd-run":
                    raise RuntimeError("No keyboard")
                return SimpleNamespace(stdout="false", returncode=0)
            with patch.object(backend, "active", side_effect=[False, True]), patch("tablet.run", side_effect=fake_run), patch("shutil.which", return_value="/usr/bin/squeekboard"):
                with self.assertRaises(RuntimeError):
                    backend.start_keyboard()
            self.assertIn(("systemctl", "--user", "start", "omarchy-fcitx5.service"), calls)
            self.assertIn(("gsettings", "set", "org.gnome.desktop.a11y.applications", "screen-keyboard-enabled", "false"), calls)
            self.assertFalse(backend.lease.exists())

class ExtendedTests(unittest.TestCase):
    def backend(self, folder):
        return Backend(Path(folder) / "state")

    def test_layout_and_custom_dictation_survive_reload(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict("os.environ", {"XDG_RUNTIME_DIR": folder}):
            backend = self.backend(folder)
            backend.command({"action": "layout", "value": "tiling"})
            backend.command({"action": "dictationCommand", "value": 'voice --language "fr CA"'})
            again = self.backend(folder)
            self.assertEqual(again.preferences["layout"], "tiling")
            self.assertEqual(again.preferences["dictationCommand"], ["voice", "--language", "fr CA"])
            with patch("tablet.subprocess.Popen") as popen, patch.object(again, "start_keyboard"):
                again.command({"action": "dictation"})
                self.assertEqual(popen.call_args.args[0], ["voice", "--language", "fr CA"])
                self.assertNotIn("shell", popen.call_args.kwargs)

    def test_invalid_command_and_corrupt_preferences(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict("os.environ", {"XDG_RUNTIME_DIR": folder}):
            backend = self.backend(folder)
            for command in ([], {"action": "layout", "value": "bad"}, {"action": "dictationCommand", "value": ""}):
                with self.assertRaises(ValueError):
                    backend.command(command)
            backend.preferences_path.parent.mkdir(parents=True)
            backend.preferences_path.write_text("not-json")
            self.assertEqual(self.backend(folder).preferences["mode"], "auto")

    def test_restore_retains_widget_edits_and_reinstall_takes_new_baseline(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            cfg = root / "config/omarchy/shell.json"
            cfg.parent.mkdir(parents=True)
            cfg.write_text(json.dumps({"version": 1, "bar": {"id": "original", "position": "bottom", "layout": {"left": []}}}))
            source = Path(__file__).resolve().parents[1]
            install(root / "config", root / "state", source, False)
            changed = json.loads(cfg.read_text())
            changed["bar"]["layout"]["left"].append({"id": "omarchy.clock"})
            cfg.write_text(json.dumps(changed))
            restore(root / "config", root / "state", False)
            result = json.loads(cfg.read_text())
            self.assertEqual(result["bar"]["id"], "original")
            self.assertEqual(result["bar"]["layout"]["left"], [{"id": "omarchy.clock"}])
            result["bar"]["position"] = "left"
            cfg.write_text(json.dumps(result))
            install(root / "config", root / "state", source, False)
            restore(root / "config", root / "state", False)
            self.assertEqual(json.loads(cfg.read_text())["bar"]["position"], "left")

    def test_install_changes_entry_urls_when_source_changes(self):
        import shutil
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            cfg = root / "config/omarchy/shell.json"
            cfg.parent.mkdir(parents=True)
            cfg.write_text('{"version": 1, "bar": {}}')
            source = root / "source"
            source.mkdir()
            repo = Path(__file__).resolve().parents[1]
            for f in [*repo.glob("*.qml"), *repo.glob("*.py"), repo / "manifest.json"]:
                shutil.copy2(f, source / f.name)
            manifest = root / "config/omarchy/plugins/surface.tablet/manifest.json"
            install(root / "config", root / "state", source, False)
            before = json.loads(manifest.read_text())["entryPoints"]["bar"]
            with (source / "Bar.qml").open("a") as f:
                f.write("\n// new revision\n")
            install(root / "config", root / "state", source, False)
            after = json.loads(manifest.read_text())["entryPoints"]["bar"]
            self.assertNotEqual(before, after)
            self.assertTrue((manifest.parent / after).exists())


class BackendRegressionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        env = patch.dict("os.environ", {"XDG_RUNTIME_DIR": self.temp.name})
        env.start()
        self.addCleanup(env.stop)
        self.backend = Backend(Path(self.temp.name) / "state")

    def test_valid_json_with_wrong_shape_is_ignored(self):
        self.backend.preferences_path.parent.mkdir(parents=True)
        for content in ("[]", "null", "42", '"wrong"'):
            self.backend.preferences_path.write_text(content)
            self.assertEqual(Backend(self.backend.state_dir).preferences["mode"], "auto")

    def test_legacy_layout_command_changes_mode_consistently(self):
        self.backend.command({"action": "layout", "value": "single"})
        self.assertEqual(self.backend.preferences["mode"], "tablet")
        self.backend.command({"action": "layout", "value": "tiling"})
        self.assertEqual(self.backend.preferences["mode"], "desktop")

    def test_title_churn_does_not_reconcile_unchanged_focus(self):
        b = self.backend
        self.assertTrue(b.layout_event(b"activewindowv2>>abcd"))
        for _ in range(100):
            self.assertFalse(b.layout_event(b"activewindowv2>>abcd"))
            self.assertFalse(b.layout_event(b"windowtitlev2>>abcd,changing title"))
        self.assertTrue(b.layout_event(b"activewindowv2>>dcba"))
        self.assertTrue(b.layout_event(b"movewindowv2>>dcba,2,2"))
        self.assertTrue(b.layout_event(b"activewindowv2>>"))

    def test_idle_reconcile_does_not_query_windows(self):
        b = self.backend
        state = {"tablet": False, "keyboardAvailable": False}
        b.next_style_check = float("inf")
        with patch.object(b, "state", return_value=state), patch.object(b.layout, "reconcile") as layout:
            b.reconcile()
            for _ in range(10):
                b.reconcile()
            layout.assert_called_once_with(False)
            b.layout_dirty = True
            b.reconcile()
            self.assertEqual(layout.call_count, 2)

    def test_layout_failure_keeps_dirty_flag(self):
        b = self.backend
        with patch.object(b, "state", return_value={"tablet": False, "keyboardAvailable": False}), \
             patch.object(b.layout, "reconcile", side_effect=RuntimeError("busy")):
            with self.assertRaises(RuntimeError):
                b.reconcile()
            self.assertTrue(b.layout_dirty)

    def test_dictation_keeps_keyboard_and_explicit_hide_releases_it(self):
        b = self.backend
        b.preferences["keyboardActivation"] = "manual"
        b.manual_keyboard = True
        b.keyboard_started = True
        b.layout_dirty = False
        b.next_keyboard_check = b.next_style_check = float("inf")
        with patch("tablet.shutil.which", return_value="/usr/bin/squeekboard"), \
             patch("tablet.subprocess.Popen") as popen, patch.object(b, "start_keyboard"), \
             patch.object(b, "state", return_value={"tablet": True, "keyboardAvailable": True}), \
             patch.object(b, "visible", return_value=False), patch.object(b, "show_keyboard") as show, \
             patch.object(b, "restore_keyboard", side_effect=lambda: setattr(b, "keyboard_started", False)) as stop:
            b.command({"action": "dictation"})
            self.assertTrue(b.keep_keyboard_open)
            self.assertEqual(popen.call_args.args[0], ["murmure", "--transcription", "--hidden"])
            b.keyboard_css_applied = b.keyboard_theme.prepare(b.preferences["keyboardStyle"])
            b.reconcile()
            show.assert_called_with(True)
            b.command({"action": "hideKeyboard"})
            self.assertFalse(b.keep_keyboard_open)
            self.assertFalse(b.manual_keyboard)
            stop.assert_called_once()
            show.assert_called_with(False)
            show.reset_mock()
            b.reconcile()
            show.assert_not_called()

    def test_tablet_focus_events_do_not_start_a_hidden_keyboard(self):
        b = self.backend
        b.preferences["keyboardActivation"] = "manual"
        b.next_style_check = float("inf")
        with patch.object(b, "state", return_value={"tablet": True, "keyboardAvailable": True}), \
             patch.object(b.layout, "reconcile"), patch.object(b, "start_keyboard") as start:
            for event in (b"activewindowv2>>first", b"activewindowv2>>second", b"activewindowv2>>first"):
                b.layout_dirty = b.layout_event(event)
                b.reconcile()
            start.assert_not_called()

    def test_dictation_does_not_reopen_dismissed_keyboard(self):
        b = self.backend
        with patch("tablet.subprocess.Popen"), patch.object(b, "start_keyboard") as start:
            b.command({"action": "hideKeyboard"})
            b.command({"action": "dictation"})
            start.assert_not_called()
            self.assertFalse(b.manual_keyboard)
            self.assertFalse(b.keep_keyboard_open)

    def test_automatic_activation_keeps_service_listening_after_hide(self):
        b = self.backend
        b.next_keyboard_check = b.next_style_check = float("inf")
        b.layout_dirty = False
        with patch.object(b, "state", return_value={"tablet": True, "keyboardAvailable": True}), \
             patch.object(b, "start_keyboard", side_effect=lambda: setattr(b, "keyboard_started", True)) as start, \
             patch.object(b, "visible", return_value=False), patch.object(b, "show_keyboard") as show, \
             patch.object(b, "restore_keyboard") as stop:
            b.keyboard_css_applied = b.keyboard_theme.prepare("omarchy")
            b.reconcile()
            start.assert_called_once()
            b.command({"action": "hideKeyboard"})
            show.assert_called_with(False)
            stop.assert_not_called()
            b.reconcile()
            self.assertEqual(start.call_count, 1)
            b.command({"action": "keyboardActivation", "value": "manual"})
            stop.assert_called_once()
            self.assertEqual(Backend(b.state_dir).preferences["keyboardActivation"], "manual")

    def test_automatic_keyboard_dismisses_stale_visibility_on_new_window(self):
        b = self.backend
        b.keyboard_started = True
        b.layout_dirty = False
        b.next_keyboard_check = b.next_style_check = float("inf")
        b.keyboard_css_applied = b.keyboard_theme.prepare("omarchy")
        with patch.object(b, "state", return_value={"tablet": True, "keyboardAvailable": True}), \
             patch.object(b, "visible", return_value=True), patch.object(b, "show_keyboard") as show:
            b.layout_event(b"activewindowv2>>new")
            b.reconcile()
            show.assert_called_once_with(False)
            b.layout_event(b"activewindowv2>>new")
            b.reconcile()
            self.assertEqual(show.call_count, 1)

    def test_dictation_visibility_guard_expires(self):
        b = self.backend
        b.keep_keyboard_open = True
        b.keep_keyboard_until = 0
        b.next_style_check = float("inf")
        b.layout_dirty = False
        with patch.object(b, "state", return_value={"tablet": False, "keyboardAvailable": False}):
            b.reconcile()
        self.assertFalse(b.keep_keyboard_open)

    def test_dictation_does_not_rewrite_preferences(self):
        with patch("tablet.subprocess.Popen"), patch.object(self.backend, "start_keyboard"):
            self.backend.command({"action": "dictation"})
        self.assertFalse(self.backend.preferences_path.exists())


if __name__ == "__main__":
    unittest.main()
