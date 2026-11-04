"""Match a mitmproxy capture to an ETL and report who opened each connection.

The frame above the Windows network DLLs is the caller. The process's own
binaries are first-party. A WebView, a hook DLL, or another vendor's module
is third-party.
"""

import argparse
import ipaddress
import re
import sys
from collections import Counter, defaultdict

from read_etl import read_etl
from read_flows import read_flows

OS_SKIP = {
    "ntdll.dll", "kernelbase.dll", "kernel32.dll", "ws2_32.dll", "mswsock.dll",
    "wininet.dll", "winhttp.dll", "webio.dll", "dnsapi.dll", "nsi.dll",
    "winnsi.dll", "iphlpapi.dll", "fwpuclnt.dll", "rasadhlp.dll",
    "dhcpcsvc.dll", "dhcpcsvc6.dll", "nlaapi.dll", "crypt32.dll",
    "bcrypt.dll", "ncrypt.dll", "schannel.dll", "secur32.dll", "sspicli.dll",
    "cryptbase.dll", "bcryptprimitives.dll", "rpcrt4.dll", "combase.dll",
    "ucrtbase.dll", "sechost.dll", "advapi32.dll", "msvcrt.dll",
    "wintrust.dll", "cryptsp.dll", "rsaenh.dll", "user32.dll",
    "gdi32.dll", "gdi32full.dll", "msvcp_win.dll", "imm32.dll",
    "kernel.appcore.dll", "clbcatq.dll", "ole32.dll", "oleaut32.dll",
    "shlwapi.dll", "shell32.dll", "cfgmgr32.dll", "devobj.dll",
    "ntasn1.dll", "msasn1.dll", "cryptngc.dll", "dpapi.dll",
    "gpapi.dll", "wldp.dll",
}
# Present because this trace recorded the stacks, not because it sent the traffic.
TRACER = {"windowsperformancerecordercontrol.dll", "wpr.exe"}
# Bitdefender's Winsock hook. The frame behind it is the real caller.
HOOKS = {"bdhkm64.dll"}

GENERIC_DIRS = {
    "windows", "system32", "syswow64", "program files", "program files (x86)",
    "users", "appdata", "local", "roaming", "locallow", "application",
    "microsoft", "windowsapps", "device", "programdata", "packages",
    "localstate", "localcache", "agent", "desktop", "client", "service",
    "services", "security", "update", "host", "setup", "helper", "runtime",
    "redist", "common", "files", "data", "cache", "temp", "root",
}
HOST_ALIASES = {
    "chrome": ("google", "gvt1", "gvt2", "gstatic", "googleapis", "ggpht"),
    "google": ("google", "gvt1", "gvt2", "gstatic", "googleapis"),
    "msedge": ("msedge", "bing.com", "skype.com", "microsoft", "footprintdns"),
    "searchhost": ("bing.com", "msedge", "skype.com", "microsoft", "footprintdns"),
    "edge": ("msedge", "bing.com", "skype.com", "microsoft"),
    "whatsapp": ("whatsapp",),
    "cursor": ("cursor.sh", "cursor.com"),
    "bitdefender": ("bitdefender",),
    "grammarly": ("grammarly",),
}
WINDOWS_HOSTS = (
    "microsoft.com", "microsoftonline", "live.com", "bing.com", "msedge.net",
    "skype.com", "windows.com", "windows.net", "msn.com", "footprintdns",
)
OWNER_EVENTS = (1033, 1300, 1002, 1017, 1031)
STACK_EVENTS = {1002: 0, 1033: 1, 1300: 2, 1017: 3, 1031: 4}


def basename(path):
    return (path or "").replace("/", "\\").rsplit("\\", 1)[-1].lower()


def product_of(path):
    text = (path or "").lower().replace("/", "\\")
    name = basename(text)
    if any(token in text for token in ("mitmproxy", "mitmdump", "mitmweb")):
        return "mitmproxy"
    if "bitdefender" in text or name in HOOKS or name in (
        "bdservicehost.exe", "bdvpnservice.exe", "productagentservice.exe"
    ):
        return "Bitdefender"
    if "cursor" in text:
        return "Cursor"
    if "whatsapp" in text:
        return "WhatsApp"
    if "msedgewebview2" in text or "edgewebview" in text:
        return "WebView2"
    if "\\microsoft\\edge\\" in text or name == "msedge.exe":
        return "Microsoft Edge"
    if "chrome" in text:
        return "Google Chrome"
    if "\\windowsapps\\" in text:
        package = text.split("\\windowsapps\\")[-1].split("\\")[0]
        return package.split("_")[0]
    if "\\windows\\" in text:
        return "Windows"
    parts = [part for part in text.split("\\") if part]
    return parts[-2] if len(parts) >= 2 else (name or "unknown")


def path_tokens(path):
    tokens = []
    for part in re.split(r"[\\/]+", (path or "").lower()):
        part = re.sub(r"\.(exe|dll)$", "", part)
        part = re.sub(r"_[0-9].*$", "", part)
        for word in re.split(r"[^a-z0-9]+", part):
            if word in GENERIC_DIRS or len(word) < 4 or word.startswith("harddiskvolume"):
                continue
            tokens.append(word)
    return tokens


def is_local_host(host):
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        return host.lower() in ("localhost",)
    return address.is_private or address.is_loopback or address.is_link_local


def destination_kind(exe, process, host, webview_host, command=""):
    if is_local_host(host):
        return "local network"
    host_l = (host or "").lower()
    tokens = path_tokens(exe) + path_tokens(command) + path_tokens(webview_host or "")
    if process and process.lower() not in ("svchost.exe", "idle"):
        tokens.append(re.sub(r"\.exe$", "", process.lower()))
    for token in tokens:
        if token and token in host_l:
            return "own service"
        for alias in HOST_ALIASES.get(token, ()):
            if alias in host_l:
                return "own service"
    if product_of(exe) == "Windows" and any(item in host_l for item in WINDOWS_HOSTS):
        return "own service"
    return "other service"


def proc_at(processes, pid, when):
    hits = [item for item in processes if item["pid"] == pid]
    if not hits:
        return None
    if when:
        alive = [
            item for item in hits
            if item["t0"] <= when and (item["t1"] is None or when <= item["t1"])
        ]
        if alive:
            hits = alive
    hits.sort(key=lambda item: item["t0"])
    return hits[-1]


def full_exe(images, pid, name, when):
    name_l = (name or "").lower()
    matches = [item for item in images.get(pid, []) if basename(item["file"]) == name_l]
    if when:
        alive = [
            item for item in matches
            if item["t0"] <= when and (item["t1"] is None or when <= item["t1"])
        ]
        if alive:
            matches = alive
    if matches:
        return matches[-1]["file"]
    return name


def resolve_stack(images, pid, addresses, when):
    modules = images.get(pid, [])
    found = []
    for address in addresses:
        hit = None
        for module in modules:
            if not (module["base"] <= address < module["end"]):
                continue
            in_time = module["t0"] <= when and (module["t1"] is None or when <= module["t1"])
            if in_time:
                hit = module["file"]
                break
            if hit is None:
                hit = module["file"]
        if hit:
            found.append(hit)
    return found


def caller_frames(resolved):
    """Paths above the Windows network DLLs, leaf first. Full path is kept so
    a system DLL such as upnp.dll still classifies as Windows."""
    frames = []
    seen = set()
    for path in resolved:
        name = basename(path)
        if name in OS_SKIP or name in TRACER or path.lower().endswith(".sys"):
            continue
        if name in seen:
            continue
        seen.add(name)
        frames.append(path)
        if len(frames) >= 4:
            break
    return frames


def service_name(command):
    match = re.search(r"-s\s+(\S+)", command or "")
    return match.group(1) if match else ""


def webview_host(command):
    match = re.search(r"--webview-exe-name=([^\s\"]+)", command or "")
    return match.group(1) if match else ""


def choose_connection(candidates):
    """Pick the socket owner and the connect stack for one 4-tuple."""
    owners = [
        item for item in candidates
        if item["pid"] and item["pid"] > 4 and item["eid"] in OWNER_EVENTS
    ]
    pid = None
    for event_id in OWNER_EVENTS:
        for item in owners:
            if item["eid"] == event_id:
                pid = item["pid"]
                break
        if pid:
            break
    if pid is None:
        nonzero = [item for item in candidates if item["pid"] and item["pid"] > 4]
        pid = nonzero[0]["pid"] if nonzero else candidates[0]["pid"]

    stacked = [item for item in candidates if item.get("ustack") and item["eid"] in STACK_EVENTS]
    stacked.sort(key=lambda item: STACK_EVENTS.get(item["eid"], 9))
    source = stacked[0] if stacked else None
    return {
        "pid": pid,
        "eid": source["eid"] if source else (owners[0]["eid"] if owners else candidates[0]["eid"]),
        "ustack": source.get("ustack") if source else None,
        "ustack_pid": source.get("ustack_pid") if source else None,
        "t": source["t"] if source else candidates[0]["t"],
    }


def classify(process_name, exe, command, frames):
    host_app = webview_host(command)
    process_product = product_of(exe or process_name)
    hook = None
    caller_path = frames[0] if frames else None
    if caller_path and basename(caller_path) in HOOKS:
        hook = basename(caller_path)
        caller_path = frames[1] if len(frames) > 1 else None
    caller_name = basename(caller_path) if caller_path else process_name
    caller_product = product_of(caller_path) if caller_path else process_product

    if host_app or process_product == "WebView2" or (process_name or "").lower() == "msedgewebview2.exe":
        caller_kind = "webview"
    elif hook and caller_path is None:
        caller_kind = "hook only"
    elif caller_path and caller_product not in (process_product, "unknown"):
        caller_kind = "other module"
    else:
        caller_kind = "own binary"
    return {
        "caller_kind": caller_kind,
        "caller": caller_name,
        "hook": hook,
        "webview_host": host_app,
        "product": host_app or process_product,
    }


def correlate(flows, etl):
    by_tuple = defaultdict(list)
    for connection in etl["connections"]:
        by_tuple[(connection["lip"], connection["lp"], connection["rip"], connection["rp"])].append(connection)

    start = etl["start"].timestamp() if etl["start"] else None
    end = etl["end"].timestamp() if etl["end"] else None
    matched = []
    unmatched = []
    for flow in flows:
        timestamp = flow.get("ts")
        if start is not None and (timestamp is None or timestamp < start or timestamp > end):
            continue
        peer = flow.get("client_peer")
        sock = flow.get("client_sock")
        host = flow.get("host") or flow.get("sni") or flow["type"]
        if not peer or not sock:
            unmatched.append(host)
            continue
        candidates = by_tuple.get((peer[0], peer[1], sock[0], sock[1]))
        if not candidates:
            candidates = by_tuple.get((sock[0], sock[1], peer[0], peer[1]))
        if not candidates:
            unmatched.append(host)
            continue
        chosen = choose_connection(candidates)
        stack_pid = chosen["ustack_pid"] if chosen.get("ustack_pid") and chosen["ustack_pid"] > 4 else chosen["pid"]
        process = proc_at(etl["processes"], chosen["pid"], chosen["t"])
        process_name = process["name"] if process else str(chosen["pid"])
        command = process["cmd"] if process else ""
        exe = full_exe(etl["images"], chosen["pid"], process_name, chosen["t"])
        resolved = resolve_stack(etl["images"], stack_pid, chosen.get("ustack") or [], chosen["t"])
        frames = caller_frames(resolved)
        info = classify(process_name, exe, command, frames)
        parent = proc_at(etl["processes"], process["parent"], chosen["t"]) if process else None
        matched.append(
            {
                **info,
                "process": process_name,
                "parent": parent["name"] if parent else "",
                "service": service_name(command),
                "host": host,
                "method": flow.get("method") or "",
                "path": (flow.get("path") or "").split("?")[0][:140],
                "qtype": flow.get("qtype") or "",
                "destination_kind": destination_kind(
                    exe, process_name, host, info["webview_host"], command
                ),
            }
        )
    return matched, unmatched


def _label(row):
    who = row["process"]
    if row["service"]:
        who += f" -s {row['service']}"
    if row["webview_host"]:
        who = f"{row['webview_host']} via {row['process']}"
    return who


def _section(row):
    if row["caller_kind"] == "webview":
        return "Third-party: WebView"
    if row["caller_kind"] in ("hook only", "other module"):
        return "Third-party: another vendor's module"
    if row["destination_kind"] == "other service":
        return "Own binary calling another vendor"
    if row["destination_kind"] == "local network":
        return "First-party: local network"
    return "First-party: own service"


def render_report(flow_path, etl_path, etl, matched, unmatched):
    lines = []
    if etl["start"] and etl["end"]:
        start_local = etl["start"].astimezone().strftime("%Y-%m-%d %H:%M:%S")
        end_local = etl["end"].astimezone().strftime("%Y-%m-%d %H:%M:%S")
        lines.append(f"ETL window (local): {start_local} to {end_local}")
        lines.append(f"ETL window (UTC):   {etl['start'].strftime('%Y-%m-%d %H:%M:%S')} to {etl['end'].strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append(f"Flow file: {flow_path}")
    lines.append(f"ETL file:  {etl_path}")
    lines.append(f"Matched connections in the overlap: {len(matched)}")
    lines.append(f"Flows in the overlap with no TCP match: {len(unmatched)}")
    lines.append("")
    lines.append("First-party means the process's own binary made the call.")
    lines.append("Third-party means a WebView, a hook DLL, or another vendor's module made it.")
    lines.append("A hook named on a first-party line intercepted that call; the module after the hook is the caller.")

    grouped = defaultdict(lambda: {"n": 0, "paths": Counter(), "hooks": Counter()})
    for row in matched:
        key = (
            _section(row),
            _label(row),
            row["caller"],
            row["host"],
            row["destination_kind"],
        )
        bucket = grouped[key]
        bucket["n"] += 1
        if row["hook"]:
            bucket["hooks"][row["hook"]] += 1
        target = row["path"] or (f"DNS {row['qtype']}" if row["qtype"] else row["host"])
        shown = f"{row['method']} {target}".strip()
        bucket["paths"][shown] += 1

    order = [
        "First-party: own service",
        "First-party: local network",
        "Own binary calling another vendor",
        "Third-party: WebView",
        "Third-party: another vendor's module",
    ]
    for section in order:
        items = [(key, value) for key, value in grouped.items() if key[0] == section]
        if not items:
            continue
        lines.append("")
        lines.append(section)
        for key, value in sorted(items, key=lambda item: -item[1]["n"]):
            _, who, caller, host, destination = key
            hook = ""
            if value["hooks"]:
                hook = " hook " + ", ".join(name for name, _ in value["hooks"].most_common())
            lines.append(
                f"  {value['n']:4d}  {who}  caller {caller}{hook}  -> {host}  ({destination})"
            )
            for path, count in value["paths"].most_common(4):
                lines.append(f"         {count:4d}  {path}")

    if unmatched:
        lines.append("")
        lines.append("In the overlap, but no matching TCP connection in the ETL")
        for host, count in Counter(unmatched).most_common(20):
            lines.append(f"  {count:4d}  {host}")
    return "\n".join(lines) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Compare a mitmproxy flow dump with a network-stack ETL on their overlapping time."
    )
    parser.add_argument("--flow", required=True, help="mitmproxy flow file (.mitm or a saved flow dump)")
    parser.add_argument("--etl", required=True, help="network-stack .etl file")
    parser.add_argument("--report", help="also write the report to this path")
    args = parser.parse_args(argv)

    print(f"Reading flows {args.flow}", file=sys.stderr, flush=True)
    flows = read_flows(args.flow)
    print(f"  {len(flows)} flows", file=sys.stderr, flush=True)
    etl = read_etl(args.etl)
    matched, unmatched = correlate(flows, etl)
    report = render_report(args.flow, args.etl, etl, matched, unmatched)
    sys.stdout.write(report)
    if args.report:
        with open(args.report, "w", encoding="utf-8") as handle:
            handle.write(report)
        print(f"Wrote {args.report}", file=sys.stderr, flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
