#!/usr/bin/env python3
"""Small session backend: hardware presence, preferences and the Wayland OSK.

No text, keystrokes, window contents or credentials are read or stored.
The QML service owns this process through stdin/stdout JSON messages.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import select
import shlex
import shutil
import signal
import socket
import subprocess
import struct
import sys
import time
from keyboard_theme import KeyboardTheme, STYLES

DEFAULT_FAVORITES = ["chromium", "org.gnome.Nautilus", "com.github.xournalpp.xournalpp",
                     "libreoffice-writer", "YouTube", "org.gnome.Calculator", "murmure", "localsend"]
MODES = {"auto", "tablet", "desktop"}
ORIENTATION_MAP = {"normal": 0, "bottom-up": 2, "right-up": 3, "left-up": 1}


def valid_command(value):
    return (isinstance(value, list) and bool(value)
            and all(isinstance(v, str) and v and "\0" not in v for v in value))


def wallpaper():
    path = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "omarchy/current/background"
    return path.resolve().as_uri() if path.exists() else ""


def physical_keyboard_present(devices):
    """Use Linux input topology, not virtual-keyboard counts from Hyprland."""
    for block in devices.split("\n\n"):
        name = re.search(r'^N: Name="(.*)"$', block, re.M)
        path = re.search(r"^S: Sysfs=(.*)$", block, re.M)
        handlers = re.search(r"^H: Handlers=(.*)$", block, re.M)
        if not (name and path and handlers):
            continue
        if "kbd" not in handlers[1].split() or "/virtual/" in path[1]:
            continue
        label = name[1].lower()
        if any(word in label for word in ("virtual", "video bus", "buttons", "power button", "speaker", "consumer control", "system control")):
            continue
        keys = re.search(r"^B: KEY=(.*)$", block, re.M)
        if keys:
            bits = 0
            for word in keys[1].split():
                bits = (bits << (struct.calcsize("L") * 8)) | int(word, 16)
            if all(bits & (1 << code) for code in (28, 30, 44, 57)):
                return True
            continue
        if "keyboard" in label or "type cover" in label:
            return True
    return False


def tablet_mode(mode, attached):
    return mode == "tablet" or (mode == "auto" and not attached)


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    temp.replace(path)


def run(*args, check=True):
    result = subprocess.run(args, capture_output=True, text=True, timeout=12)
    if check and result.returncode:
        raise RuntimeError((result.stderr or result.stdout).strip()[:300])
    return result


class Backend:
    def __init__(self, state_dir=None):
        self.state_dir = Path(state_dir or Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "omarchy-tablet")
        self.preferences_path = self.state_dir / "preferences.json"
        self.preferences = {"mode": "auto", "favorites": DEFAULT_FAVORITES.copy(), "layout": "single",
                            "dictationCommand": ["murmure", "--transcription"], "keyboardStyle": "omarchy", "keyboardActivation": "auto",
                            "autoRotate": True, "rotationLocked": False}
        if self.preferences_path.exists():
            try:
                saved = json.loads(self.preferences_path.read_text())
            except (ValueError, OSError):
                saved = {}
            if not isinstance(saved, dict):
                saved = {}
            if isinstance(saved.get("layout"), str) and saved["layout"] in {"single", "tiling"}:
                self.preferences["layout"] = saved["layout"]
            if valid_command(saved.get("dictationCommand")):
                self.preferences["dictationCommand"] = saved["dictationCommand"]
            if isinstance(saved.get("mode"), str) and saved["mode"] in MODES:
                self.preferences["mode"] = saved["mode"]
            if isinstance(saved.get("keyboardStyle"), str) and saved["keyboardStyle"] in STYLES:
                self.preferences["keyboardStyle"] = saved["keyboardStyle"]
            if isinstance(saved.get("keyboardActivation"), str) and saved["keyboardActivation"] in {"auto", "manual"}:
                self.preferences["keyboardActivation"] = saved["keyboardActivation"]
            if isinstance(saved.get("favorites"), list):
                self.preferences["favorites"] = [s for s in saved["favorites"] if isinstance(s, str)]
            if isinstance(saved.get("autoRotate"), bool):
                self.preferences["autoRotate"] = saved["autoRotate"]
            if isinstance(saved.get("rotationLocked"), bool):
                self.preferences["rotationLocked"] = saved["rotationLocked"]
        self.runtime = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")) / "omarchy-tablet"
        self.runtime.mkdir(mode=0o700, exist_ok=True)
        self.keyboard_theme = KeyboardTheme(self.runtime)
        self.keyboard_css_applied = None
        self.lease = self.runtime / "keyboard-lease.json"
        self.manual_keyboard = False
        self.keep_keyboard_open = False
        self.keep_keyboard_until = 0
        self.keyboard_started = False
        self.error = ""
        self.last_mode = None
        self.retry_after = 0
        self.running = True
        self.sensor_available = False
        self.sensor_orientation = "normal"
        self.current_transform = 0
        self.internal_monitor = None
        self._sensor_thread = None
        self._sensor_loop = None
        from layout import SingleApp
        self.layout = SingleApp(self.runtime / "window-lease.json")
        self.dictation_process = None
        self.animations = True
        self.next_style_check = 0
        self.next_keyboard_check = 0
        self.layout_dirty = True
        self.layout_force = False
        self._touch_initialized = False
        self.last_focus_event = None
        self.dismiss_keyboard_on_focus = False
        self._wake_r, self._wake_w = os.pipe()
        os.set_blocking(self._wake_r, False)
        os.set_blocking(self._wake_w, False)

    def wakeup(self):
        try:
            os.write(self._wake_w, b"\x01")
        except OSError:
            pass

    def __del__(self):
        try:
            if hasattr(self, "_wake_r"):
                os.close(self._wake_r)
            if hasattr(self, "_wake_w"):
                os.close(self._wake_w)
        except OSError:
            pass

    def active(self, unit):
        return run("systemctl", "--user", "is-active", "--quiet", unit, check=False).returncode == 0

    def restore_keyboard(self):
        if not self.lease.exists():
            return
        lease = json.loads(self.lease.read_text())
        run("systemctl", "--user", "stop", "omarchy-tablet-keyboard.service", check=False)
        if "oskEnabled" in lease:
            run("gsettings", "set", "org.gnome.desktop.a11y.applications", "screen-keyboard-enabled", lease["oskEnabled"])
        if lease.get("fcitx"):
            run("systemctl", "--user", "start", "omarchy-fcitx5.service")
        self.lease.unlink(missing_ok=True)
        self.keyboard_started = False

    def start_keyboard(self):
        # Only yield the known Omarchy input-method service, never kill arbitrary IMEs.
        if self.active("omarchy-tablet-keyboard.service"):
            self.keyboard_started = True
            return
        css = self.keyboard_theme.prepare(self.preferences["keyboardStyle"])
        fcitx = self.active("omarchy-fcitx5.service")
        osk_enabled = run("gsettings", "get", "org.gnome.desktop.a11y.applications", "screen-keyboard-enabled").stdout.strip()
        if osk_enabled not in {"true", "false"}:
            raise RuntimeError("Cannot read the on-screen keyboard accessibility setting")
        atomic_json(self.lease, {"fcitx": fcitx, "oskEnabled": osk_enabled})
        try:
            run("gsettings", "set", "org.gnome.desktop.a11y.applications", "screen-keyboard-enabled", "true")
            if fcitx:
                run("systemctl", "--user", "stop", "omarchy-fcitx5.service")
            run("systemd-run", "--user", "--collect", "--unit=omarchy-tablet-keyboard",
                "--property=PartOf=graphical-session.target", "--", "/usr/bin/env",
                *self.keyboard_theme.environment(), shutil.which("squeekboard"))
            self.keyboard_css_applied = css
            self.keyboard_started = True
        except Exception:
            self.restore_keyboard()
            raise

    def visible(self):
        result = run("busctl", "--user", "get-property", "sm.puri.OSK0", "/sm/puri/OSK0",
                     "sm.puri.OSK0", "Visible", check=False)
        return result.returncode == 0 and result.stdout.strip() == "b true"

    def show_keyboard(self, visible):
        run("busctl", "--user", "call", "sm.puri.OSK0", "/sm/puri/OSK0",
            "sm.puri.OSK0", "SetVisible", "b", "true" if visible else "false")

    def automatic_keyboard(self, tablet=None):
        if tablet is None:
            tablet = self.state()["tablet"]
        return tablet and self.preferences["keyboardActivation"] == "auto"

    def hide_keyboard(self):
        self.manual_keyboard = False
        self.keep_keyboard_open = False
        if self.keyboard_started:
            try:
                self.show_keyboard(False)
            finally:
                # Automatic mode keeps the input method listening for the next
                # text-input activation; manual mode stays stopped until a tap.
                if not self.automatic_keyboard():
                    self.restore_keyboard()

    def get_internal_monitor(self):
        if self.internal_monitor:
            return self.internal_monitor
        res = run("hyprctl", "-j", "monitors", check=False)
        if res.returncode == 0:
            try:
                mons = json.loads(res.stdout)
                for m in mons:
                    name = m.get("name", "")
                    if re.match(r"^(eDP|DSI|LVDS)", name):
                        self.internal_monitor = name
                        self.current_transform = m.get("transform", 0)
                        return name
                if mons:
                    self.internal_monitor = mons[0]["name"]
                    self.current_transform = mons[0].get("transform", 0)
                    return self.internal_monitor
            except (ValueError, KeyError, TypeError):
                pass
        self.internal_monitor = "eDP-1"
        return "eDP-1"

    def get_touch_devices(self):
        res = run("hyprctl", "-j", "devices", check=False)
        if res.returncode == 0:
            try:
                data = json.loads(res.stdout)
                touch = [d["name"] for d in data.get("touch", []) if isinstance(d, dict) and "name" in d]
                tablets = [d["name"] for d in data.get("tablets", []) if isinstance(d, dict) and "name" in d]
                return touch, tablets
            except (ValueError, KeyError, TypeError):
                pass
        return [], []

    def rotate(self, transform):
        if not isinstance(transform, int) or transform not in {0, 1, 2, 3}:
            return False
        monitor = self.get_internal_monitor()
        if not monitor:
            return False
        if self.current_transform == transform and self._touch_initialized:
            return True

        scale = 1.6
        res = run("hyprctl", "-j", "monitors", check=False)
        if res.returncode == 0:
            try:
                mons = json.loads(res.stdout)
                for m in mons:
                    if m.get("name") == monitor and "scale" in m:
                        scale = m["scale"]
                        break
            except (ValueError, KeyError, TypeError):
                pass

        res = run("hyprctl", "eval", f'hl.monitor({{output="{monitor}", mode="preferred", position="auto", scale={scale}, transform={transform}}})', check=False)
        if res.returncode != 0:
            return False

        # Apply touchdevice and tablet rotation matching the monitor transform
        run("hyprctl", "eval", f'hl.config({{ input = {{ touchdevice = {{ transform = {transform}, output = "{monitor}" }}, tablet = {{ transform = {transform}, output = "{monitor}" }} }} }})', check=False)
        touch_devs, tablet_devs = self.get_touch_devices()
        for dev in touch_devs + tablet_devs:
            dev_escaped = dev.replace('"', '\\"')
            run("hyprctl", "eval", f'hl.device({{ name = "{dev_escaped}", transform = {transform}, output = "{monitor}" }})', check=False)

        self._touch_initialized = True
        self.current_transform = transform
        self.layout_dirty = True
        self.layout_force = True
        self.wakeup()
        return True

    def on_sensor_orientation(self, orient):
        self.sensor_orientation = orient
        if not self.preferences.get("autoRotate", True):
            return
        if self.preferences.get("rotationLocked", False):
            return
        transform = ORIENTATION_MAP.get(orient)
        if transform is not None:
            self.rotate(transform)

    def start_sensor(self):
        try:
            from gi.repository import Gio, GLib
        except ImportError:
            self.sensor_available = False
            return

        def run_sensor():
            while self.running:
                try:
                    proxy = Gio.DBusProxy.new_for_bus_sync(
                        Gio.BusType.SYSTEM, Gio.DBusProxyFlags.NONE, None,
                        "net.hadess.SensorProxy", "/net/hadess/SensorProxy", "net.hadess.SensorProxy", None)
                    proxy.call_sync("ClaimAccelerometer", None, Gio.DBusCallFlags.NONE, 3000, None)
                    self.sensor_available = True
                    self.sensor_proxy = proxy
                    self.layout_dirty = True

                    def on_props_changed(proxy, changed_props, invalidated_props):
                        try:
                            props = changed_props.unpack() if changed_props else {}
                            if "AccelerometerOrientation" in props:
                                self.on_sensor_orientation(props["AccelerometerOrientation"])
                                return
                            c = proxy.get_cached_property("AccelerometerOrientation")
                            if c:
                                self.on_sensor_orientation(c.unpack())
                        except Exception:
                            pass

                    proxy.connect("g-properties-changed", on_props_changed)
                    curr = proxy.get_cached_property("AccelerometerOrientation")
                    if curr:
                        self.on_sensor_orientation(curr.unpack())

                    loop = GLib.MainLoop()
                    self._sensor_loop = loop
                    loop.run()
                except Exception:
                    self.sensor_available = False
                    time.sleep(2)

        import threading
        t = threading.Thread(target=run_sensor, daemon=True)
        self._sensor_thread = t
        t.start()

    def _effective_layout(self, tablet):
        """Layout follows the mode: tablets use Single app, desktop uses tiling.

        No manual Single-app/Tiling switch; switching Desktop ⇄ Tablet swaps it.
        """
        return "single" if tablet else "tiling"

    def state(self):
        attached = physical_keyboard_present(Path("/proc/bus/input/devices").read_text())
        tablet = tablet_mode(self.preferences["mode"], attached)
        state = dict(self.preferences, attached=attached, tablet=tablet)
        state["layout"] = self._effective_layout(tablet)
        state.update(
            keyboardAvailable=bool(shutil.which("squeekboard")),
            keyboardRunning=self.keyboard_started, error=self.error,
            dictationCommandText=shlex.join(self.preferences["dictationCommand"]),
            dictationAvailable=bool(shutil.which(self.preferences["dictationCommand"][0])),
            animations=self.animations,
            wallpaper=wallpaper(),
            autoRotate=self.preferences.get("autoRotate", True),
            rotationLocked=self.preferences.get("rotationLocked", False),
            currentTransform=self.current_transform,
            sensorAvailable=self.sensor_available,
        )
        return state

    def command(self, data):
        if not isinstance(data, dict):
            raise ValueError("Expected a command object")
        action, value = data.get("action"), data.get("value")
        if action == "mode":
            if value == "toggle":
                value = "desktop" if self.state()["tablet"] else "tablet"
            if not isinstance(value, str) or value not in MODES:
                raise ValueError("Unknown mode")
            self.preferences["mode"] = value
            self.manual_keyboard = False
            self.keep_keyboard_open = False
        elif action == "layout":
            if not isinstance(value, str) or value not in {"single", "tiling"}:
                raise ValueError("Unknown layout")
            # Kept for older IPC clients: layout follows the selected mode.
            self.preferences["mode"] = "tablet" if value == "single" else "desktop"
            self.preferences["layout"] = value
        elif action == "keyboardActivation":
            if not isinstance(value, str) or value not in {"auto", "manual"}:
                raise ValueError("Unknown keyboard activation")
            self.preferences["keyboardActivation"] = value
            self.hide_keyboard()
        elif action == "keyboardStyle":
            if not isinstance(value, str) or value not in STYLES:
                raise ValueError("Unknown keyboard style")
            self.preferences["keyboardStyle"] = value
        elif action == "dictationCommand":
            argv = shlex.split(value) if isinstance(value, str) else value
            if not valid_command(argv):
                raise ValueError("Enter a command and optional arguments")
            self.preferences["dictationCommand"] = argv
        elif action == "dictation":
            if self.dictation_process and self.dictation_process.poll() is None:
                return
            # Dictation may retain an explicitly opened keyboard, but must not
            # reopen one the user dismissed.
            if self.keyboard_started and (self.manual_keyboard or self.visible()):
                self.keep_keyboard_open = True
                # Cover the speech app's startup focus transition, then give
                # visibility back to Wayland text-input (including auto-hide).
                self.keep_keyboard_until = time.monotonic() + 2
            argv = list(self.preferences["dictationCommand"])
            if Path(argv[0]).name == "murmure" and "--hidden" not in argv:
                argv.append("--hidden")
            self.dictation_process = subprocess.Popen(argv,
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        elif action == "favorite":
            if not isinstance(value, str) or not value or len(value) > 256:
                raise ValueError("Invalid application ID")
            favorites = self.preferences["favorites"]
            favorites.remove(value) if value in favorites else favorites.append(value)
        elif action == "hideKeyboard":
            self.hide_keyboard()
        elif action == "keyboard":
            if not shutil.which("squeekboard"):
                raise RuntimeError("Keyboard unavailable: install squeekboard.")
            if self.keyboard_started and self.visible():
                self.hide_keyboard()
            else:
                self.manual_keyboard = True
                self.start_keyboard()
                # D-Bus registration happens just after process startup.
                for attempt in range(20):
                    try:
                        self.show_keyboard(True)
                        break
                    except RuntimeError:
                        if attempt == 19:
                            raise
                        time.sleep(0.1)
        elif action == "autoRotate":
            val = bool(value)
            self.preferences["autoRotate"] = val
            if val and not self.preferences.get("rotationLocked", False):
                t = ORIENTATION_MAP.get(self.sensor_orientation)
                if t is not None:
                    self.rotate(t)
        elif action == "rotationLock":
            val = not self.preferences.get("rotationLocked", False) if value == "toggle" else bool(value)
            self.preferences["rotationLocked"] = val
            if not val and self.preferences.get("autoRotate", True):
                t = ORIENTATION_MAP.get(self.sensor_orientation)
                if t is not None:
                    self.rotate(t)
        elif action == "orientation":
            if isinstance(value, int) and value in {0, 1, 2, 3}:
                self.rotate(value)
            elif isinstance(value, str) and value.isdigit() and int(value) in {0, 1, 2, 3}:
                self.rotate(int(value))
        else:
            raise ValueError("Unknown command")
        if action in {"mode", "layout", "dictationCommand", "favorite", "keyboardStyle", "keyboardActivation", "autoRotate", "rotationLock", "orientation"}:
            atomic_json(self.preferences_path, self.preferences)
        if action in {"mode", "layout"}:
            self.layout_dirty = True
        self.error = ""

    def reconcile(self):
        state = self.state()
        if self.last_mode is not None and state["tablet"] != self.last_mode:
            self.manual_keyboard = False
            self.keep_keyboard_open = False
            self.layout_dirty = True
        self.last_mode = state["tablet"]
        wanted = state["keyboardAvailable"] and (self.manual_keyboard or self.automatic_keyboard(state["tablet"]))
        if wanted and not self.keyboard_started and time.monotonic() >= self.retry_after:
            try:
                self.start_keyboard()
            except (OSError, RuntimeError, subprocess.SubprocessError) as exc:
                self.error = str(exc)
                self.retry_after = time.monotonic() + 30
        elif not wanted and self.keyboard_started:
            self.restore_keyboard()
        if self.keyboard_started and time.monotonic() >= self.next_keyboard_check:
            self.next_keyboard_check = time.monotonic() + 5
            if not self.active("omarchy-tablet-keyboard.service"):
                self.restore_keyboard()
                self.error = "Keyboard stopped. Check journalctl --user -u omarchy-tablet-keyboard."
                self.retry_after = time.monotonic() + 30
        if self.dismiss_keyboard_on_focus:
            if self.keyboard_started and self.automatic_keyboard(state["tablet"]) and not self.keep_keyboard_open:
                # A new window may inherit the previous client's OSK visibility.
                # Dismiss it once; subsequent field activations remain automatic.
                self.show_keyboard(False)
                self.manual_keyboard = False
            self.dismiss_keyboard_on_focus = False
        if self.keep_keyboard_open and time.monotonic() >= self.keep_keyboard_until:
            self.keep_keyboard_open = False
        if self.keyboard_started and self.keep_keyboard_open and not self.visible():
            self.show_keyboard(True)
        if self.keyboard_started:
            css = self.keyboard_theme.prepare(self.preferences["keyboardStyle"])
            # Reload only while hidden: never interrupt an in-progress touch or
            # composing sequence. Keep the input-method recovery lease intact.
            if css != self.keyboard_css_applied and not self.visible():
                run("systemctl", "--user", "restart", "omarchy-tablet-keyboard.service")
                self.keyboard_css_applied = css
        if self.layout_dirty:
            # Keep dirty on failure: a failed dispatch must be retried.
            force = getattr(self, "layout_force", False)
            self.layout_force = False
            if force:
                self.layout.reconcile(self._effective_layout(state["tablet"]) == "single", force=True)
            else:
                self.layout.reconcile(self._effective_layout(state["tablet"]) == "single")
            self.layout_dirty = False
        if time.monotonic() >= self.next_style_check:
            self.next_style_check = time.monotonic() + 30
            result = run("hyprctl", "-j", "getoption", "animations:enabled", check=False)
            if result.returncode == 0:
                self.animations = bool(json.loads(result.stdout).get("int", 1))
        if self.dictation_process and self.dictation_process.poll() is not None:
            if self.dictation_process.returncode:
                self.error = "Dictation command failed. Check your dictation application."
            self.dictation_process = None
        return self.state()

    def stop(self, *_):
        self.running = False
        if self._sensor_loop:
            self._sensor_loop.quit()
        self.wakeup()

    def layout_event(self, line):
        """Ignore title churn: Hyprland repeats activewindowv2 for the same ID."""
        name, _, data = line.partition(b">>")
        if name == b"activewindowv2":
            if data == self.last_focus_event:
                return False
            self.last_focus_event = data
            self.dismiss_keyboard_on_focus = True
            return True
        if name == b"configreloaded":
            self.next_style_check = 0
        return name in {b"openwindow", b"closewindow", b"movewindow", b"movewindowv2",
                        b"changefloatingmode", b"fullscreen", b"workspace", b"workspacev2",
                        b"focusedmon", b"monitoradded", b"monitorremoved", b"configreloaded",
                        b"togglegroup", b"pin"}

    def daemon(self):
        lock = (self.runtime / "backend.lock").open("w")
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        signal.signal(signal.SIGTERM, self.stop)
        signal.signal(signal.SIGINT, self.stop)
        previous = ""
        buffer = b""
        events = None
        event_buffer = b""
        next_connect = 0
        next_maintenance = 0
        layout_due = 0
        try:
            self.layout.restore()
            self.restore_keyboard()  # recover after a previous shell crash
            self.rotate(self.current_transform)
            self.start_sensor()
            while self.running:
                now = time.monotonic()
                if events is None and now >= next_connect:
                    next_connect = now + 5
                    candidate = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    try:
                        candidate.connect(str(self.runtime.parent / "hypr" /
                            os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "") / ".socket2.sock"))
                        candidate.setblocking(False)
                        events = candidate
                        event_buffer = b""
                        self.last_focus_event = None
                        self.layout_dirty = True
                    except OSError:
                        candidate.close()
                if now >= next_maintenance or (self.layout_dirty and now >= layout_due):
                    try:
                        # Slow fallback keeps hardware detection and recovery alive
                        # even if the compositor event socket is unavailable.
                        if events is None:
                            self.layout_dirty = True
                        state = json.dumps(self.reconcile(), ensure_ascii=False)
                        if state != previous:
                            print(state, flush=True)
                            previous = state
                    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as exc:
                        self.error = str(exc)
                        print(json.dumps(self.state(), ensure_ascii=False), flush=True)
                        previous = ""
                        layout_due = time.monotonic() + 2
                    next_maintenance = time.monotonic() + (0.5 if self.keep_keyboard_open else 2)
                timeout = max(0, next_maintenance - time.monotonic())
                if self.layout_dirty:
                    timeout = min(timeout, max(0, layout_due - time.monotonic()))
                readable, _, _ = select.select([sys.stdin, self._wake_r] + ([events] if events else []), [], [], timeout)
                if self._wake_r in readable:
                    try:
                        os.read(self._wake_r, 4096)
                    except OSError:
                        pass
                if events and events in readable:
                    try:
                        chunk = events.recv(65536)
                    except OSError:
                        chunk = b""
                    if not chunk:
                        events.close()
                        events = None
                    else:
                        event_buffer += chunk
                        while b"\n" in event_buffer:
                            line, event_buffer = event_buffer.split(b"\n", 1)
                            if self.layout_event(line):
                                if not self.layout_dirty:
                                    layout_due = time.monotonic() + .04
                                self.layout_dirty = True
                if sys.stdin in readable:
                    chunk = os.read(sys.stdin.fileno(), 65536)
                    if not chunk:
                        break
                    buffer += chunk
                    if len(buffer) > 1024 * 1024:
                        buffer = b""
                        self.error = "Command too large"
                    while b"\n" in buffer:
                        line, buffer = buffer.split(b"\n", 1)
                        try:
                            self.command(json.loads(line))
                        except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as exc:
                            self.error = str(exc)
                    next_maintenance = 0
                    layout_due = 0
        finally:
            if events:
                events.close()
            try:
                self.layout.restore()
            finally:
                self.restore_keyboard()
                lock.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["daemon", "status"])
    args = parser.parse_args()
    if args.action == "daemon":
        Backend().daemon()
    else:
        print(json.dumps(Backend().state(), ensure_ascii=False, indent=2))
