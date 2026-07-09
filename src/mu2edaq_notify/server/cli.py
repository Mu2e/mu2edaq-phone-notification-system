"""``mu2edaq-notify-server`` -- run the notification server."""
from __future__ import annotations

import argparse
import logging
import os
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
    p.add_argument("--tls", dest="tls", action="store_true", default=None,
                   help="serve HTTPS using server.tls settings")
    p.add_argument("--no-tls", dest="tls", action="store_false",
                   help="serve plain HTTP")
    p.add_argument("--tls-cert", metavar="FILE",
                   help="TLS certificate chain file")
    p.add_argument("--tls-key", metavar="FILE", help="TLS private key file")
    p.add_argument("--tls-adhoc", action="store_true",
                   help="serve HTTPS with a temporary self-signed cert "
                   "(development only)")
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
    if args.tls is not None:
        overrides.append((("server", "tls", "enabled"), args.tls))
    if args.tls_cert:
        overrides.append((("server", "tls", "cert_file"), args.tls_cert))
    if args.tls_key:
        overrides.append((("server", "tls", "key_file"), args.tls_key))
    if args.tls_adhoc:
        overrides.append((("server", "tls", "enabled"), True))
        overrides.append((("server", "tls", "adhoc"), True))
    if args.db_url:
        overrides.append((("database", "url"), args.db_url))
    if args.api_tokens:
        overrides.append((("auth", "api_tokens"), args.api_tokens))
    if args.zmq is not None:
        overrides.append((("zmq", "enabled"), args.zmq))
    if args.discovery is not None:
        overrides.append((("discovery", "enabled"), args.discovery))
    return load_config(config_file=args.config, overrides=overrides)


def ssl_context_from_config(cfg):
    tls = cfg["server"].get("tls", {})
    if not tls.get("enabled"):
        return None
    if tls.get("adhoc"):
        return "adhoc"

    cert_file = tls.get("cert_file") or ""
    key_file = tls.get("key_file") or ""
    if not cert_file or not key_file:
        raise ValueError("server.tls.enabled requires cert_file/key_file "
                         "or adhoc: true")
    for path in (cert_file, key_file):
        if not os.path.exists(path):
            raise ValueError("TLS file does not exist: %s" % path)
    return (cert_file, key_file)


def server_scheme(cfg):
    return "https" if cfg["server"].get("tls", {}).get("enabled") else "http"


def discovery_meta(cfg):
    """Extra ANNOUNCE metadata: the public fallback URL, when configured.

    The ANNOUNCE itself advertises this server's own local host/port/
    scheme (so on-network publishers connect directly); the fallback
    URL -- typically the public reverse-proxy address -- rides along in
    ``meta`` for publishers to use only when the local address is
    unreachable.
    """
    fallback = cfg["discovery"].get("fallback_url") or ""
    return {"fallback_url": fallback} if fallback else None


def start_discovery(cfg):
    """Announce via mu2edaq-discovery if installed and enabled."""
    if not cfg["discovery"].get("enabled"):
        return None
    try:
        from mu2edaq_discovery import Responder
    except ImportError:
        log.info("mu2edaq-discovery not installed; not announcing")
        return None
    discovery = cfg["discovery"]
    responder = Responder(name=discovery.get("name", "notify"),
                          app=discovery.get("app", "notify"),
                          host=discovery.get("host") or None,
                          port=int(discovery.get("port")
                                   or cfg["server"]["port"]),
                          scheme=discovery.get("scheme")
                          or server_scheme(cfg),
                          meta=discovery_meta(cfg))
    responder.start()
    log.info("discovery responder started (app=%s, host=%s, port=%s, "
             "fallback_url=%s)",
             discovery.get("app"), discovery.get("host") or "<local>",
             discovery.get("port") or cfg["server"]["port"],
             discovery.get("fallback_url") or "<none>")
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
    ssl_context = ssl_context_from_config(cfg)
    scheme = server_scheme(cfg)
    log.info("mu2edaq-notify-server %s on %s://%s:%s "
             "(db=%s, apns=%s)",
             __version__, scheme, cfg["server"]["host"],
             cfg["server"]["port"],
             cfg["database"]["url"],
             "enabled" if cfg["apns"].get("enabled") else "log-only")
    try:
        app.run(host=cfg["server"]["host"], port=int(cfg["server"]["port"]),
                debug=args.debug, threaded=True, use_reloader=False,
                ssl_context=ssl_context)
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
