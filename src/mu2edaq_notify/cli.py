"""``mu2edaq-notify`` -- publish an event from the shell.

Also a diagnostic for the server: ``mu2edaq-notify ping`` checks health.
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.request

from .events import SEVERITIES
from .publisher import ENV_TOKEN, ENV_URL, NotifyPublisher


def main(argv=None):
    p = argparse.ArgumentParser(
        prog="mu2edaq-notify",
        description="Publish an event to the Mu2e DAQ notification server.")
    p.add_argument("--server", help="server URL (default: $%s or discovery)"
                   % ENV_URL)
    p.add_argument("--token", help="API bearer token (default: $%s)"
                   % ENV_TOKEN)
    p.add_argument("--no-discover", action="store_true",
                   help="do not use mu2edaq-discovery to find the server")

    sub = p.add_subparsers(dest="command")

    send = sub.add_parser("send", help="publish one event")
    send.add_argument("--severity", choices=SEVERITIES, default="warning")
    send.add_argument("--source", default="cli")
    send.add_argument("--meta", action="append", default=[],
                      metavar="KEY=VALUE", help="attach metadata (repeatable)")
    send.add_argument("title")
    send.add_argument("message", nargs="?", default="")

    sub.add_parser("ping", help="check the server /api/health endpoint")

    args = p.parse_args(argv)
    if not args.command:
        p.print_help()
        return 2

    pub = NotifyPublisher(server_url=args.server, token=args.token,
                          discover=not args.no_discover)

    if args.command == "ping":
        if not pub.server_url:
            print("no server configured or discovered", file=sys.stderr)
            return 1
        url = pub.server_url.rstrip("/") + "/api/health"
        try:
            with urllib.request.urlopen(url, timeout=5) as resp:
                print(json.dumps(json.load(resp), indent=2))
                return 0
        except Exception as exc:
            print("health check failed: %s" % exc, file=sys.stderr)
            return 1

    meta = {}
    for item in args.meta:
        key, _, value = item.partition("=")
        meta[key] = value
    ok = pub.publish(args.severity, args.title, args.message,
                     source=args.source, meta=meta)
    if not ok:
        print("event was not accepted by the server", file=sys.stderr)
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
