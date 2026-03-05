#!/usr/bin/env python3

import json
import os
import re
import subprocess
import sys
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET


def die(msg):
    print(f"[ERROR] {msg}", file=sys.stderr)
    sys.exit(1)


def get_env(name, default=None, required=False):
    val = os.getenv(name, default)
    if required and not val:
        die(f"Missing required env var: {name}")
    return val


def run(cmd):
    try:
        out = subprocess.check_output(cmd, stderr=subprocess.STDOUT)
    except subprocess.CalledProcessError as exc:
        die(f"Command failed: {' '.join(cmd)}\n{exc.output.decode(errors='ignore')}")
    return out.decode()


def get_instance_ips():
    raw = run(["terraform", "output", "-json", "instance_public_ips"])
    try:
        ips = json.loads(raw)
    except json.JSONDecodeError:
        die("Failed to parse terraform output for instance_public_ips")
    if not isinstance(ips, list) or not ips:
        die("No instance_public_ips found in terraform output")
    return ips


def read_team_colors(path):
    if not os.path.exists(path):
        die(f"team colors file not found: {path}")
    colors = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            if not s:
                continue
            colors.append(s)
    if not colors:
        die("team colors file is empty")
    return colors


HEX_TO_NAME = {
    "#1E90FF": "blue",
    "#FF8C00": "orange",
    "#2E8B57": "green",
    "#DC143C": "red",
    "#8A2BE2": "purple",
    "#00CED1": "cyan",
    "#FFD700": "gold",
    "#A52A2A": "brown",
    "#00FF7F": "springgreen",
    "#FF1493": "deeppink",
}


def resolve_team_names(colors):
    override = os.getenv("TEAM_NAMES", "").strip()
    if override:
        names = [x.strip() for x in override.split(",") if x.strip()]
        return names
    names = []
    for idx, c in enumerate(colors):
        name = HEX_TO_NAME.get(c.upper()) or HEX_TO_NAME.get(c)
        if not name:
            slug = re.sub(r"-{2,}", "-", re.sub(r"[^a-z0-9-]", "-", c.strip().lower())).strip("-")
            name = slug if slug else f"team{idx+1:02d}"
        names.append(name)
    return names


def api_request(base_url, params):
    qs = urllib.parse.urlencode(params)
    url = f"{base_url}?{qs}"
    with urllib.request.urlopen(url, timeout=30) as resp:
        return resp.read().decode()


def parse_api_response(xml_text):
    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError:
        die("Failed to parse Namecheap API XML response")

    status = root.attrib.get("Status")
    if status != "OK":
        errs = []
        for err in root.findall(".//Errors/Error"):
            errs.append(err.text or "Unknown error")
        die("Namecheap API error: " + "; ".join(errs) if errs else "Namecheap API error")
    return root


def main():
    api_user = get_env("NAMECHEAP_API_USER", required=True)
    api_key = get_env("NAMECHEAP_API_KEY", required=True)
    username = get_env("NAMECHEAP_USERNAME", default=api_user)
    client_ip = get_env("NAMECHEAP_CLIENT_IP")
    domain = get_env("DOMAIN", default="caiphdatathon.live")
    ttl = get_env("TTL", default="60")
    dry_run = get_env("DRY_RUN", default="false").lower() == "true"

    if "." not in domain:
        die(f"Invalid DOMAIN: {domain}")
    sld, tld = domain.rsplit(".", 1)

    sandbox = get_env("NAMECHEAP_SANDBOX", default="false").lower() == "true"
    base_url = "https://api.sandbox.namecheap.com/xml.response" if sandbox else "https://api.namecheap.com/xml.response"

    if not client_ip:
        try:
            with urllib.request.urlopen("https://checkip.amazonaws.com", timeout=10) as resp:
                client_ip = resp.read().decode().strip()
        except Exception:
            die("Failed to detect public IP. Set NAMECHEAP_CLIENT_IP explicitly.")

    colors = read_team_colors(get_env("TEAM_COLORS_FILE", default="team-colors.txt"))
    names = resolve_team_names(colors)
    ips = get_instance_ips()

    if len(names) != len(ips):
        allow_mismatch = get_env("ALLOW_COUNT_MISMATCH", default="false").lower() == "true"
        if not allow_mismatch:
            die(f"Team count ({len(names)}) does not match instance IPs ({len(ips)}). Set ALLOW_COUNT_MISMATCH=true to proceed with the minimum.")

    count = min(len(names), len(ips))
    team_hosts = names[:count]
    team_ips = ips[:count]

    common = {
        "ApiUser": api_user,
        "ApiKey": api_key,
        "UserName": username,
        "ClientIp": client_ip,
        "SLD": sld,
        "TLD": tld,
    }

    get_params = dict(common)
    get_params["Command"] = "namecheap.domains.dns.getHosts"
    xml = api_request(base_url, get_params)
    root = parse_api_response(xml)

    hosts = []
    for host in root.findall(".//DomainDNSGetHostsResult/host"):
        hosts.append({
            "Name": host.attrib.get("Name", ""),
            "Type": host.attrib.get("Type", ""),
            "Address": host.attrib.get("Address", ""),
            "TTL": host.attrib.get("TTL", ttl),
        })

    filtered = [h for h in hosts if h.get("Name") not in team_hosts]
    for name, ip in zip(team_hosts, team_ips):
        filtered.append({"Name": name, "Type": "A", "Address": ip, "TTL": ttl})

    if not filtered:
        die("No DNS records to set. Aborting.")

    set_params = dict(common)
    set_params["Command"] = "namecheap.domains.dns.setHosts"
    for idx, h in enumerate(filtered, start=1):
        set_params[f"HostName{idx}"] = h["Name"]
        set_params[f"RecordType{idx}"] = h["Type"]
        set_params[f"Address{idx}"] = h["Address"]
        set_params[f"TTL{idx}"] = h["TTL"]

    if dry_run:
        print("[DRY_RUN] Would set hosts:")
        for h in filtered:
            print(f"  {h['Name']} {h['Type']} {h['Address']} TTL={h['TTL']}")
        return

    xml_set = api_request(base_url, set_params)
    parse_api_response(xml_set)
    print(f"[OK] Updated {count} team DNS records for {domain}")


if __name__ == "__main__":
    main()
