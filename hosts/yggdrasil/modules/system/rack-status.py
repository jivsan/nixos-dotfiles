"""rack-status: ping the boxes in the rack and the internet, tell home assistant over mqtt.

one binary_sensor.rack_status_<name> per box, on = it answers ping. the rack leds read them.
a box goes off after `down_after` rounds in a row without an answer, and on again at the first answer.
right after a start there's no older state to keep, so a box that misses the first round is off at once.
"online" only goes out once the first round is done, so home assistant never shows states from before
a restart as if they were new.
if this script stops (or yggdrasil does) the broker sends "offline" and every entity goes unavailable.
if it hangs and stops sending, home assistant drops each state after every * (down_after + 1) s anyway.

config: the json file in $RACK_STATUS_CONFIG (rack-status.nix writes it)
password: $CREDENTIALS_DIRECTORY/mqtt-password (systemd's LoadCredential)
"""

import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime

import paho.mqtt.client as mqtt
from paho.mqtt.enums import CallbackAPIVersion

ALIVE = re.compile(r"^(\S+) is alive(?: \(([\d.]+) ms\))?")
# what fping prints when the kernel won't send a ping. under systemd that's the IPAddressAllow list
SEND_DENIED = "error while sending ping: Operation not permitted"


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def now_iso():
    return datetime.now().astimezone().isoformat(timespec="seconds")


class Target:
    def __init__(self, t):
        self.name = t["name"]
        self.addresses = t["addresses"]
        self.enabled = t["enabled"]
        self.up = None            # None until its first round is done
        self.misses = 0
        self.rtt = None
        self.answered = []
        self.last_change = None
        self.attrs_due = True
        self.attrs_sent = 0.0


class RackStatus:
    def __init__(self, cfg, password):
        self.cfg = cfg
        self.targets = [Target(t) for t in cfg["targets"]]
        self.lock = threading.Lock()
        base = cfg["topic"]
        self.avail = f"{base}/availability"
        self.ha_status = f"{cfg['discovery_prefix']}/status"
        m = cfg["mqtt"]
        self.client = mqtt.Client(CallbackAPIVersion.VERSION2, client_id=m["client_id"])
        self.client.username_pw_set(m["username"], password)
        if m.get("ca_file"):
            # tls: the broker has to show this certificate (or one signed by it), made out to m["host"]
            self.client.tls_set(ca_certs=m["ca_file"])
        self.client.will_set(self.avail, "offline", qos=1, retain=True)
        self.client.reconnect_delay_set(min_delay=1, max_delay=60)
        self.client.on_connect = self.on_connect
        self.client.on_connect_fail = self.on_connect_fail
        self.client.on_disconnect = self.on_disconnect
        self.client.on_message = self.on_message
        self.stop = threading.Event()
        self.ready = False        # true once the first round is done. "online" waits for it
        self.connected = False    # only for the logs: a refused login isn't a lost connection
        self.connect_error = None # the last "can't reach the broker" reason, so it's logged once
        self.fping_errors = []

    # topics

    def state_topic(self, t):
        return f"{self.cfg['topic']}/{t.name}/state"

    def attrs_topic(self, t):
        return f"{self.cfg['topic']}/{t.name}/attributes"

    def config_topic(self, t):
        # rack_status is the node id: all of them under one prefix, so an acl can allow just that
        return f"{self.cfg['discovery_prefix']}/binary_sensor/rack_status/{t.name}/config"

    def discovery(self, t):
        src = self.cfg["source"]
        return {
            "name": t.name,
            "unique_id": f"rack_status_{t.name}",
            # home assistant 2025.10+ takes the entity id from this (object_id is gone in 2026.4)
            "default_entity_id": f"binary_sensor.rack_status_{t.name}",
            "device_class": "connectivity",
            "state_topic": self.state_topic(t),
            "payload_on": "ON",
            "payload_off": "OFF",
            # the state goes out every round. if rounds stop but the connection stays, this still
            # makes it unavailable after a few missed rounds
            "expire_after": self.cfg["every"] * (self.cfg["down_after"] + 1),
            "json_attributes_topic": self.attrs_topic(t),
            "availability_topic": self.avail,
            "payload_available": "online",
            "payload_not_available": "offline",
            "qos": 1,
            "device": {
                "identifiers": [f"rack_status_{src}"],
                "name": "Rack status",
                "manufacturer": "my homelab",
                "model": f"ping from {src}",
            },
            "origin": {"name": "rack-status"},
        }

    def attributes(self, t):
        a = {"address": ", ".join(t.addresses), "rtt_ms": t.rtt, "last_change": t.last_change}
        if len(t.addresses) > 1:
            a["answered"] = t.answered
        return a

    # what to send. built under the lock, sent outside it

    def target_messages(self, t, everything):
        if t.up is None:
            return []
        msgs = [(self.state_topic(t), "ON" if t.up else "OFF")]
        now = time.monotonic()
        if everything or t.attrs_due or now - t.attrs_sent >= self.cfg["attributes_every"]:
            msgs.append((self.attrs_topic(t), json.dumps(self.attributes(t))))
            t.attrs_due = False
            t.attrs_sent = now
        return msgs

    def all_messages(self):
        msgs = []
        with self.lock:
            for t in self.targets:
                if t.enabled:
                    msgs.append((self.config_topic(t), json.dumps(self.discovery(t))))
                    msgs += self.target_messages(t, everything=True)
                else:
                    # an empty retained config removes the entity, if it was there before
                    msgs += [(self.config_topic(t), ""), (self.state_topic(t), ""), (self.attrs_topic(t), "")]
            ready = self.ready
        return msgs, ready

    def send(self, msgs):
        if not self.client.is_connected():
            return   # on_connect sends everything again
        for topic, payload in msgs:
            self.client.publish(topic, payload, qos=1, retain=True)

    def go_online(self):
        if self.client.is_connected():
            self.client.publish(self.avail, "online", qos=1, retain=True)

    def send_everything(self):
        msgs, ready = self.all_messages()
        self.send(msgs)
        if ready:
            self.go_online()   # otherwise the first round does it

    # mqtt callbacks (paho's network thread)

    def on_connect(self, client, userdata, flags, reason_code, properties):
        if reason_code.is_failure:
            log(f"mqtt: the broker said no: {reason_code} (trying again)")
            return
        log("mqtt: connected")
        self.connected = True
        self.connect_error = None
        client.subscribe(self.ha_status, qos=1)
        self.send_everything()

    def on_connect_fail(self, client, userdata):
        # paho calls this from inside its except block, so the reason is still at hand
        why = str(sys.exc_info()[1] or "no reason given")
        if why != self.connect_error:
            log(f"mqtt: can't reach the broker: {why} (trying again)")
            self.connect_error = why

    def on_disconnect(self, client, userdata, flags, reason_code, properties):
        if self.connected and not self.stop.is_set():
            log(f"mqtt: lost the broker: {reason_code} (reconnecting)")
        self.connected = False

    def on_message(self, client, userdata, msg):
        if msg.topic == self.ha_status and msg.payload == b"online":
            log("home assistant came back, sending discovery again")
            self.send_everything()

    # pinging

    def ping(self, addresses):
        cmd = [self.cfg["fping"], "-4", "-e",
               "-r", str(self.cfg["retries"]), "-t", str(self.cfg["timeout_ms"]), *addresses]
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=self.cfg["every"])
        if self.stop.is_set():
            return None   # stopping: systemd stops fping too, so this round says nothing
        # fping is quiet on stderr for a box that's just down, so whatever is there gets logged (once)
        errors = sorted(set(p.stderr.splitlines()))
        if errors != self.fping_errors:
            for line in errors:
                log(f"fping: {line}")
            self.fping_errors = errors
        if any(SEND_DENIED in line for line in errors):
            # the pings never left yggdrasil, so "no answer" says nothing about the boxes
            raise RuntimeError("fping isn't allowed to send pings (the IPAddressAllow list in rack-status.nix?)")
        # 0 = all answered, 1 = some didn't, 2 = a name didn't resolve. 3 and 4 = fping itself broke,
        # below 0 = something killed it
        if p.returncode < 0 or p.returncode > 2:
            raise RuntimeError(f"fping exit {p.returncode}: {p.stderr.strip()}")
        alive = {}
        for line in p.stdout.splitlines():
            m = ALIVE.match(line)
            if m:
                alive[m.group(1)] = float(m.group(2)) if m.group(2) else None
        return alive

    def one_round(self):
        enabled = [t for t in self.targets if t.enabled]
        addresses = sorted({a for t in enabled for a in t.addresses})
        alive = self.ping(addresses)
        if alive is None:
            return
        down_after = self.cfg["down_after"]
        msgs = []
        with self.lock:
            for t in enabled:
                got = [a for a in t.addresses if a in alive]
                if got:
                    rtts = [alive[a] for a in got if alive[a] is not None]
                    t.rtt = min(rtts) if rtts else None
                    t.answered = got
                    t.misses = 0
                    self.set_state(t, True)
                else:
                    t.rtt = None
                    t.answered = []
                    t.misses += 1
                    if t.up is None or t.misses >= down_after:
                        self.set_state(t, False)
                    else:
                        log(f"{t.name}: no answer ({t.misses}/{down_after})")
                msgs += self.target_messages(t, everything=False)
            first = not self.ready
            self.ready = True
        self.send(msgs)
        if first:
            self.go_online()   # every state is fresh now

    def set_state(self, t, up):
        if t.up == up:
            return
        if t.up is None:
            log(f"{t.name}: {'up' if up else 'down'}")
        else:
            log(f"{t.name}: {'up again' if up else f'down ({t.misses} rounds without an answer)'}")
        t.up = up
        t.last_change = now_iso()
        t.attrs_due = True

    def shutdown(self):
        self.stop.set()
        if self.client.is_connected():
            try:
                self.client.publish(self.avail, "offline", qos=1, retain=True).wait_for_publish(timeout=5)
            except (RuntimeError, ValueError) as e:
                log(f"mqtt: couldn't send offline: {e}")
            self.client.disconnect()
        self.client.loop_stop()


def main():
    with open(os.environ["RACK_STATUS_CONFIG"]) as f:
        cfg = json.load(f)
    with open(os.path.join(os.environ["CREDENTIALS_DIRECTORY"], "mqtt-password")) as f:
        password = f.read().strip()

    rs = RackStatus(cfg, password)
    signal.signal(signal.SIGTERM, lambda *_: rs.stop.set())
    signal.signal(signal.SIGINT, lambda *_: rs.stop.set())

    names = ", ".join(t.name for t in rs.targets if t.enabled)
    m = cfg["mqtt"]
    tls = ", tls" if m.get("ca_file") else ""
    log(f"pinging {names} every {cfg['every']} s, broker {m['host']}:{m['port']}{tls}")
    rs.client.connect_async(m["host"], m["port"], keepalive=30)
    rs.client.loop_start()
    status = 0
    try:
        next_round = time.monotonic()
        while not rs.stop.is_set():
            rs.one_round()
            next_round = max(next_round + cfg["every"], time.monotonic())
            rs.stop.wait(next_round - time.monotonic())
    except (RuntimeError, subprocess.SubprocessError, OSError) as e:
        log(f"giving up: {e}")   # systemd starts it again 10 s later
        status = 1
    finally:
        rs.shutdown()
        log("stopped")
    sys.exit(status)


if __name__ == "__main__":
    main()
