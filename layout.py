"""Reversible Single app layout, using address-targeted Hyprland Lua dispatches."""
import json
import os
import re
from tablet import atomic_json, run


def identity(client):
    return [client.get("stableId"), client.get("pid"), client.get("initialClass")]


def eligible(client, monitor):
    # Floating surfaces include dialogs, popovers and utilities. Never retile them.
    return (client.get("mapped", False) and not client.get("hidden", False)
            and not client.get("floating", False) and not client.get("pinned", False)
            and client.get("monitor") == monitor
            and client.get("workspace", {}).get("id", -1) > 0
            and not client.get("grouped"))


class SingleApp:
    def __init__(self, path):
        self.path = path
        self.session = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
        try:
            saved = json.loads(path.read_text()) if path.exists() else {}
        except (ValueError, OSError):
            saved = {}
        if not isinstance(saved, dict):
            saved = {}
        self.windows = saved.get("windows", {}) if saved.get("session") == self.session else {}
        if not isinstance(self.windows, dict):
            self.windows = {}

        self._known_clients = None

    def save(self):
        atomic_json(self.path, {"session": self.session, "windows": self.windows})

    def set_state(self, address, internal, client):
        if not re.fullmatch(r"0x[0-9a-fA-F]+", address):
            raise ValueError("Invalid window address")
        code = ('hl.dispatch(hl.dsp.window.fullscreen_state({'
                f'window="address:{address}", internal={int(internal)}, client={int(client)}, '
                'action="set", layout_aware=false}))')
        result = run("hyprctl", "eval", code)
        if result.stdout.strip() not in ("", "ok"):
            raise RuntimeError(result.stdout.strip()[:300])

    def restore(self, clients=None, addresses=None):
        if not self.windows:
            return
        clients = clients if clients is not None else json.loads(run("hyprctl", "-j", "clients").stdout)
        live = {c["address"]: c for c in clients}
        for address in sorted(self.windows, key=lambda a: self.windows[a]["internal"]):
            if addresses is not None and address not in addresses:
                continue
            saved = self.windows[address]
            current = live.get(address)
            if current and identity(current) == saved["identity"]:
                self.set_state(address, saved["internal"], saved["client"])
            del self.windows[address]
            self.save()

    def _reconcile_full(self, internal):
        """Restore windows that left the managed display and discard closed ones."""
        clients = json.loads(run("hyprctl", "-j", "clients").stdout)
        live = {c["address"]: c for c in clients}
        stale = [a for a in self.windows if a not in live
                 or identity(live[a]) != self.windows[a]["identity"]
                 or not eligible(live[a], internal["id"])]
        self.restore(clients, stale)
        return clients

    def reconcile(self, enabled, force=False):
        if not enabled:
            self._known_clients = None
            self.restore()
            if force:
                try:
                    active = json.loads(run("hyprctl", "-j", "activewindow").stdout)
                    if active.get("fullscreen") == 1 and active.get("address"):
                        addr = active["address"]
                        cl = active.get("fullscreenClient", 0)
                        self.set_state(addr, 0, cl)
                        self.set_state(addr, 1, cl)
                except Exception:
                    pass
            return

        # The daemon invokes this on compositor events, not every polling tick.
        # Always inspect clients: the same active address can move to an external
        # monitor, become floating, or survive while another leased window closes.
        active = json.loads(run("hyprctl", "-j", "activewindow").stdout)
        monitors = json.loads(run("hyprctl", "-j", "monitors").stdout)
        internal = next((m for m in monitors if re.match(r"^(eDP|DSI|LVDS)", m["name"])), None)
        # No internal display: leave external monitors alone.
        if not internal:
            self.restore()
            return

        clients = self._reconcile_full(internal)
        if self._known_clients is None:
            self._known_clients = {c["address"] for c in clients}
        # Non-active newly mapped windows can appear in clients before their
        # focus event. Do not classify them as pre-existing during that gap.
        new_active = active.get("address") not in self._known_clients
        if active.get("address"):
            self._known_clients.add(active["address"])
        if not eligible(active, internal["id"]):
            return
        address = active["address"]
        # Omarchy's on_focus_under_fullscreen transfers maximization to newly
        # opened windows before openwindow is delivered. Adopt only NEW windows
        # on a workspace with a managed sibling; pre-existing maximized windows
        # and true application fullscreen remain untouched.
        inherited = (new_active
                     and active.get("fullscreen", 0) == 1
                     and any(c["address"] in self.windows
                             and self.windows[c["address"]]["internal"] == 0
                             and c.get("workspace") == active.get("workspace")
                             and c.get("monitor") == internal["id"] for c in clients))
        if address not in self.windows and active.get("fullscreen", 0) != 0 and not inherited:
            return
        if address in self.windows and active.get("fullscreen", 0) == 2:
            return  # respect an application's explicit fullscreen request
        if address in self.windows and self.windows[address]["internal"] != 0:
            return  # a captured sibling state, not a window we should manage
        # A compositor can unmaximize another window on this workspace when
        # maximizing this one. Journal those pre-existing states as well.
        for other in clients:
            if (other["address"] != address and other["address"] in self._known_clients
                    and eligible(other, internal["id"])
                    and other.get("workspace") == active.get("workspace") and other.get("monitor") == internal["id"]
                    and other.get("fullscreen", 0) != 0 and other["address"] not in self.windows):
                self.windows[other["address"]] = {"identity": identity(other),
                    "internal": other["fullscreen"], "client": other.get("fullscreenClient", 0)}
                self.save()
        if address not in self.windows:
            self.windows[address] = {"identity": identity(active), "internal": 0 if inherited else active.get("fullscreen", 0),
                                     "client": 0 if inherited else active.get("fullscreenClient", 0)}
            self.save()  # write-ahead recovery on reload, crash or detach
        if active.get("fullscreen") != 1:
            self.set_state(address, 1, self.windows[address]["client"])
        elif force:
            cl = self.windows[address]["client"]
            self.set_state(address, 0, cl)
            self.set_state(address, 1, cl)
