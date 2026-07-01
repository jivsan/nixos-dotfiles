#!/usr/bin/env python3
"""Receive pfSense firewall syslog, geolocate blocked INBOUND sources, write to InfluxDB.

pfSense streams its filterlog over syslog (UDP). We parse block/in events, look up the
source IP in GeoLite2-City, aggregate per city over a flush window, and write to InfluxDB
measurement `fw_geo` (tags country/city, fields latitude/longitude/count) for a Grafana
Geomap panel. Nothing is stored on pfSense.
"""
import ipaddress
import socket
import threading
import time
import urllib.request

import geoip2.database

MMDB = "/var/lib/GeoIP/GeoLite2-City.mmdb"
INFLUX_URL = "http://127.0.0.1:8086/write?db=pfsense"
LISTEN = ("0.0.0.0", 5514)
FLUSH_SECONDS = 30

reader = geoip2.database.Reader(MMDB)
buf = {}
buf_lock = threading.Lock()


def is_public(ip_str):
    try:
        return ipaddress.ip_address(ip_str).is_global
    except ValueError:
        return False


def parse_src(msg):
    """Source IP of a blocked inbound filterlog line, else None.

    filterlog CSV: 0=rule 1=subrule 2=anchor 3=tracker 4=iface 5=reason
    6=action 7=direction 8=ipversion ... ipv4 src=18, ipv6 src=15.
    """
    i = msg.find("filterlog")
    if i < 0:
        return None
    j = msg.find(": ", i)
    if j < 0:
        return None
    f = msg[j + 2:].strip().split(",")
    if len(f) < 9 or f[6] != "block" or f[7] != "in":
        return None
    if f[8] == "4" and len(f) > 18:
        return f[18]
    if f[8] == "6" and len(f) > 15:
        return f[15]
    return None


def escape_tag(v):
    return v.replace("\\", "").replace(" ", "\\ ").replace(",", "").replace("=", "")


def flusher():
    while True:
        time.sleep(FLUSH_SECONDS)
        with buf_lock:
            items = list(buf.items())
            buf.clear()
        if not items:
            continue
        lines = [
            f"fw_geo,country={cc},city={escape_tag(city)} "
            f"count={cnt}i,latitude={lat},longitude={lon}"
            for (cc, city, lat, lon), cnt in items
        ]
        try:
            urllib.request.urlopen(INFLUX_URL, data="\n".join(lines).encode(), timeout=10)
        except Exception as e:  # noqa: BLE001
            print("influx write failed:", e, flush=True)


def main():
    threading.Thread(target=flusher, daemon=True).start()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(LISTEN)
    print("pfsense-geoip listening on %s:%d" % LISTEN, flush=True)
    while True:
        data, _ = sock.recvfrom(8192)
        src = parse_src(data.decode("utf-8", "ignore"))
        if not src or not is_public(src):
            continue
        try:
            r = reader.city(src)
        except Exception:  # noqa: BLE001
            continue
        lat, lon = r.location.latitude, r.location.longitude
        if lat is None or lon is None:
            continue
        key = (r.country.iso_code or "XX", r.city.name or (r.country.iso_code or "XX"),
               round(lat, 4), round(lon, 4))
        with buf_lock:
            buf[key] = buf.get(key, 0) + 1


if __name__ == "__main__":
    main()
