"""``mu2edaq-notify-server`` -- run the notification server."""
from __future__ import annotations

import argparse
import logging
import threading
import time

from .. import __version__
from .app import create_app
from .config import load_config
from .dispatch import Dispatcher
from .sse import SseHub
from .storage import Storage
from .zmq_listener import ZmqListener

log = logging.getLogger(__name__)


def build_parser():
    p = argparse.ArgumentParser(
        prog="mu2edaq-notify-server",
        description="Mu2e DAQ notification server: receives events, filters "
                    "them, and pushes to iPhones, Slack, and Discord.")
    p.add_argument("--config", help="YAML config file "
                   "(default: $MU2EDAQ_NOTIFY_CONFIG)")
    p.add_argument("--host", help="bind address")
    p.add_argument("--port", type=int, help="bind port")
    p.add_argument("--db-url", help="SQLAlchemy database URL")
    p.add_argument("--base-url", help="external base URL for QR codes")
    p.add_argument("--api-token", action="append", dest="api_tokens",
                   metavar="TOKEN", help="add a publisher API token "
                   "(repeatable)")
    p.add_argument("--zmq", dest="zmq", action="store_true", default=None,
                   help="enable the ZeroMQ compatibility listener")
    p.add_argument("--no-zmq", dest="zmq", action="store_false",
                   help="disable the ZeroMQ listener")
    p.add_argument("--no-discovery", dest="discovery", action="store_false",
                   default=None, help="do not announce via mu2edaq-discovery")
    p.add_argument("--debug", action="store_true",
                   help="Flask debug mode (development only)")
    p.add_argument("--version", action="version",
                   version="%(prog)s " + __version__)
    return p


def config_from_args(args):
    overrides = []
    if args.host:
        overrides.append((("server", "host"), args.host))
    if args.port:
        overrides.append((("server", "port"), args.port))
    if args.base_url:
        overrides.append((("server", "base_url"), args.base_url))
    if args.db_url:
        overrides.append((("database", "url"), args.db_url))
    if args.api_tokens:
        overrides.append((("auth", "api_tokens"), args.api_tokens))
    if args.zmq is not None:
        overrides.append((("zmq", "enabled"), args.zmq))
    if args.discovery is not None:
        overrides.append((("discovery", "enabled"), args.discovery))
    return load_config(config_file=args.config, overrides=overrides)


def start_discovery(cfg):
    """Announce via mu2edaq-discovery if installed and enabled."""
    if not cfg["discovery"].get("enabled"):
        return None
    try:
        from mu2edaq_discovery import Responder
    except ImportError:
        log.info("mu2edaq-discovery not installed; not announcing")
        return None
    responder = Responder(name=cfg["discovery"].get("name", "notify"),
                          app=cfg["discovery"].get("app", "notify"),
                          port=int(cfg["server"]["port"]), scheme="http")
    responder.start()
    log.info("discovery responder started (app=%s)",
             cfg["discovery"].get("app"))
    return responder


def start_retention(storage, cfg):
    days = int(cfg["database"].get("retention_days", 0))
    if not days:
        return

    def prune_loop():
        while True:
            try:
                pruned = storage.prune_events(days)
                if pruned:
                    log.info("pruned %d events older than %d days",
                             pruned, days)
            except Exception:
                log.exception("retention prune failed")
            time.sleep(3600)

    threading.Thread(target=prune_loop, daemon=True,
                     name="notify-retention").start()


def main(argv=None):
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)-8s %(name)s: %(message)s")
    args = build_parser().parse_args(argv)
    cfg = config_from_args(args)

    storage = Storage(cfg["database"]["url"])
    storage.seed(cfg.get("seed", {}))

    sse_hub = SseHub()
    dispatcher = Dispatcher(storage, cfg, sse_hub=sse_hub)
    dispatcher.start()

    app = create_app(cfg, storage, dispatcher=dispatcher, sse_hub=sse_hub)

    zmq_listener = None
    if cfg["zmq"].get("enabled"):
        def zmq_ingest(event):
            stored = storage.add_event(event)
            dispatcher.submit(stored)
        zmq_listener = ZmqListener(cfg["zmq"], zmq_ingest)
        zmq_listener.start()

    responder = start_discovery(cfg)
    start_retention(storage, cfg)

    if not cfg["auth"]["api_tokens"]:
        log.warning("no auth.api_tokens configured -- the event API is "
                    "open; add tokens before exposing this server")
    log.info("mu2edaq-notify-server %s on %s:%s (db=%s, apns=%s)",
             __version__, cfg["server"]["host"], cfg["server"]["port"],
             cfg["database"]["url"],
             "enabled" if cfg["apns"].get("enabled") else "log-only")
    try:
        app.run(host=cfg["server"]["host"], port=int(cfg["server"]["port"]),
                debug=args.debug, threaded=True, use_reloader=False)
    finally:
        if zmq_listener:
            zmq_listener.stop()
        if responder is not None:
            try:
                responder.stop()
            except Exception:
                pass
        dispatcher.stop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
