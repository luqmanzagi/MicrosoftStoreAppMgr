"""Read a network-stack ETL into processes, modules, and TCP connections."""

import datetime
import html
import os
import re
import subprocess
import sys
import tempfile
from collections import defaultdict

FILETIME_EPOCH = datetime.datetime(1601, 1, 1, tzinfo=datetime.timezone.utc)

DATA_RE = re.compile(r'<Data Name="([^"]+)">([^<]*)</Data>')
TIME_RE = re.compile(r'SystemTime="([^"]+)"')
ADDR_RE = re.compile(r"<Address>(0x[0-9A-Fa-f]+)</Address>")
MATCH_RE = re.compile(r"<MatchId>(0x[0-9A-Fa-f]+)</MatchId>")
EVENTID_RE = re.compile(r"<EventID>(\d+)</EventID>")
OPCODE_RE = re.compile(r"<Opcode>([^<]*)</Opcode>")
EXEC_PID_RE = re.compile(r'ProcessID="(\d+)"')


def filetime_to_datetime(value):
    return FILETIME_EPOCH + datetime.timedelta(microseconds=int(value) / 10)


def parse_num(value):
    value = (value or "").strip()
    if not value:
        return None
    return int(value, 16) if value.lower().startswith("0x") else int(value)


def split_addr(value):
    value = value.strip()
    if value.startswith("["):
        host, port = value[1:].split("]:")
        return host, int(port)
    host, port = value.rsplit(":", 1)
    return host, int(port)


def _stamp(chunk):
    match = TIME_RE.search(chunk)
    if not match:
        return ""
    # Clock portion only. The offset tracerpt writes is not usable,
    # and ordering is all the module lifetime checks need.
    return match.group(1)[:26]


def _fields(chunk):
    return {key: html.unescape(value.strip()) for key, value in DATA_RE.findall(chunk)}


def _convert_etl(etl_path, xml_path):
    print("Converting ETL with tracerpt...", file=sys.stderr, flush=True)
    completed = subprocess.run(
        ["tracerpt", "-l", etl_path, "-o", xml_path, "-of", "XML", "-y"],
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout or "").strip()
        raise RuntimeError(f"tracerpt failed ({completed.returncode}): {detail}")


def read_etl(etl_path):
    """Convert etl_path and return start, end, processes, images, connections."""
    xml_handle = tempfile.NamedTemporaryFile(
        prefix="network-stack-", suffix=".xml", delete=False
    )
    xml_path = xml_handle.name
    xml_handle.close()
    try:
        _convert_etl(etl_path, xml_path)
        return _parse_xml(xml_path)
    finally:
        try:
            os.remove(xml_path)
        except OSError:
            pass


def _parse_xml(xml_path):
    processes = []
    images = defaultdict(list)
    connections = []
    pending = {}
    etl_start = None
    etl_end = None
    seen = 0

    buf = []
    with open(xml_path, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if not buf:
                if "<Event " in line:
                    buf = [line]
                continue
            buf.append(line)
            if "</Event>" not in line:
                continue
            chunk = "".join(buf)
            buf = []
            seen += 1
            if seen % 100000 == 0:
                print(f"  {seen} events, {len(connections)} connections", file=sys.stderr, flush=True)

            if etl_start is None and "StartTime" in chunk and "BufferSize" in chunk:
                fields = _fields(chunk)
                if "StartTime" in fields and "EndTime" in fields:
                    etl_start = filetime_to_datetime(fields["StartTime"])
                    etl_end = filetime_to_datetime(fields["EndTime"])
                    print(
                        f"ETL window {etl_start.isoformat()} to {etl_end.isoformat()}",
                        file=sys.stderr,
                        flush=True,
                    )

            is_user_stack = "Microsoft-Windows-Kernel-EventTracing" in chunk
            is_process = "ImageFileName" in chunk and "UniqueProcessKey" in chunk
            is_image = "ImageBase" in chunk and "ImageSize" in chunk and "FileName" in chunk
            is_tcp = "Microsoft-Windows-TCPIP" in chunk and "RemoteAddress" in chunk
            if not (is_user_stack or is_process or is_image or is_tcp):
                continue

            stamp = _stamp(chunk)
            if is_user_stack:
                match = MATCH_RE.search(chunk)
                if not match:
                    continue
                record = pending.get(match.group(1))
                if record is not None and "ustack" not in record:
                    exec_pid = EXEC_PID_RE.search(chunk)
                    record["ustack"] = [int(item, 16) for item in ADDR_RE.findall(chunk)]
                    record["ustack_pid"] = int(exec_pid.group(1)) if exec_pid else None
                continue

            fields = _fields(chunk)
            opcode_match = OPCODE_RE.search(chunk)
            opcode = opcode_match.group(1).strip() if opcode_match else ""

            if is_process:
                pid = parse_num(fields.get("ProcessId", ""))
                if pid is None:
                    continue
                if opcode in ("End", "DCEnd", "Terminate"):
                    for record in reversed(processes):
                        if record["pid"] == pid and record["t1"] is None:
                            record["t1"] = stamp
                            break
                else:
                    processes.append(
                        {
                            "pid": pid,
                            "name": fields.get("ImageFileName", ""),
                            "parent": parse_num(fields.get("ParentId", "") or "0"),
                            "cmd": fields.get("CommandLine", ""),
                            "t0": stamp,
                            "t1": None,
                        }
                    )
                continue

            if is_image:
                pid = parse_num(fields.get("ProcessId", ""))
                base = parse_num(fields.get("ImageBase", ""))
                size = parse_num(fields.get("ImageSize", ""))
                if pid is None or base is None or size is None:
                    continue
                if opcode in ("UnLoad", "Unload", "DCEnd"):
                    for record in reversed(images[pid]):
                        if record["base"] == base and record["t1"] is None:
                            record["t1"] = stamp
                            break
                else:
                    images[pid].append(
                        {
                            "base": base,
                            "end": base + size,
                            "file": fields.get("FileName", ""),
                            "t0": stamp,
                            "t1": None,
                        }
                    )
                continue

            remote = fields.get("RemoteAddress")
            local = fields.get("LocalAddress")
            if not remote or not local:
                continue
            local_ip, local_port = split_addr(local)
            remote_ip, remote_port = split_addr(remote)
            event_match = EVENTID_RE.search(chunk)
            event_id = int(event_match.group(1)) if event_match else None
            field_pid = parse_num(fields.get("Pid") or fields.get("ProcessId") or "0") or 0
            exec_match = EXEC_PID_RE.search(chunk)
            exec_pid = int(exec_match.group(1)) if exec_match else 0
            # 1002 has no Pid field. 1031 reports ProcessId 0. On both, the
            # executing process is the caller. Rundown event 1300 is logged
            # by the trace session, so only its Pid field owns the socket.
            if event_id in (1002, 1031):
                pid = exec_pid or field_pid
            else:
                pid = field_pid
            record = {
                "eid": event_id,
                "pid": pid,
                "lip": local_ip,
                "lp": local_port,
                "rip": remote_ip,
                "rp": remote_port,
                "t": stamp,
            }
            connections.append(record)
            match = MATCH_RE.search(chunk)
            if match:
                pending[match.group(1)] = record

    print(
        f"Parsed {seen} events, {len(processes)} process records, {len(connections)} TCP rows",
        file=sys.stderr,
        flush=True,
    )
    return {
        "start": etl_start,
        "end": etl_end,
        "processes": processes,
        "images": images,
        "connections": connections,
    }
