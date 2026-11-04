"""Read a mitmproxy flow dump into plain connection records."""

from mitmproxy.io import FlowReader


def _endpoint(value):
    if not value:
        return None
    return [value[0], int(value[1])]


def read_flows(path):
    """Return one record per flow.

    client_peer is the application socket. client_sock is the real
    destination, which is how a transparent mitmproxy capture records it.
    """
    rows = []
    with open(path, "rb") as handle:
        for index, flow in enumerate(FlowReader(handle).stream()):
            kind = type(flow).__name__
            record = {
                "index": index,
                "type": kind,
                "ts": getattr(flow, "timestamp_start", None),
            }
            client = getattr(flow, "client_conn", None)
            server = getattr(flow, "server_conn", None)
            if client is not None:
                record["client_peer"] = _endpoint(getattr(client, "peername", None))
                record["client_sock"] = _endpoint(getattr(client, "sockname", None))
            if server is not None:
                record["sni"] = getattr(server, "sni", None)
            if kind == "HTTPFlow" and flow.request:
                request = flow.request
                response = flow.response
                record.update(
                    {
                        "host": request.pretty_host,
                        "method": request.method,
                        "path": request.path[:300],
                        "scheme": request.scheme,
                        "status": response.status_code if response else None,
                    }
                )
            elif kind == "DNSFlow" and flow.request:
                questions = flow.request.questions or []
                if questions:
                    record["host"] = str(questions[0].name).rstrip(".")
                    record["qtype"] = str(questions[0].type)
            elif record.get("sni"):
                record["host"] = record["sni"]
            rows.append(record)
    return rows
