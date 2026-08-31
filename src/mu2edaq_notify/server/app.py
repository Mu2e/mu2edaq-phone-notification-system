"""Flask application: JSON API + web interface."""
from __future__ import annotations

import io
import json
import logging
import os
import re
from pathlib import Path

import segno
from flask import (Blueprint, Flask, Response, abort, current_app, jsonify,
                   redirect, render_template, request, send_file, session,
                   url_for)

from .. import __version__
from ..events import SEVERITIES, normalize_event
from . import auth
from .sse import SseHub

log = logging.getLogger(__name__)

api = Blueprint("api", __name__, url_prefix="/api")
web = Blueprint("web", __name__)


def _web_dir():
    override = os.environ.get("MU2EDAQ_NOTIFY_WEB_DIR")
    if override:
        return Path(override)
    return Path(__file__).resolve().parents[3] / "web"


def create_app(cfg, storage, dispatcher=None, sse_hub=None):
    web_dir = _web_dir()
    app = Flask("mu2edaq_notify",
                template_folder=str(web_dir / "templates"),
                static_folder=str(web_dir / "static"))
    app.secret_key = cfg["server"]["secret_key"]
    app.config["NOTIFY_CFG"] = cfg
    app.config["NOTIFY_STORAGE"] = storage
    app.config["NOTIFY_DISPATCHER"] = dispatcher
    app.config["NOTIFY_SSE"] = sse_hub or SseHub()
    app.config["NOTIFY_OAUTH"] = auth.init_oidc(app, cfg)

    app.register_blueprint(api)
    app.register_blueprint(web)

    @app.context_processor
    def _template_globals():
        return {
            "SEVERITIES": SEVERITIES,
            "CATEGORIES": cfg.get("categories") or [],
            "version": __version__,
            "oidc_enabled": cfg["auth"]["oidc"].get("enabled", False),
            "current_user": session.get("user"),
        }

    @app.errorhandler(401)
    @app.errorhandler(403)
    @app.errorhandler(404)
    def _json_errors(err):
        if request.path.startswith("/api/"):
            return jsonify(error=err.description), err.code
        return render_template("error.html", error=err), err.code

    return app


# Public URL resolution ------------------------------------------------------
#
# The URL a phone must talk to is a property of how the request arrived, not of
# this process: the same server is reached at notify.andrewnorman.org through
# the AWS tunnel, at mu2edaq-pager.fnal.gov through the OKD route, and at
# kaon.andrewnorman.org:8095 directly. An enrollment QR code carrying a
# hardcoded hostname is wrong in two of those three cases, so the base URL is
# derived from the request by default and `server.base_url` is the fallback.
#
# The host therefore comes from the network, which makes it untrusted input:
# it is validated against the hostname grammar before use (it ends up inside
# the QR payload and the autoconfig JSON), and `server.trusted_hosts` can
# restrict it to a known set.

_HOSTNAME_RE = re.compile(
    r"^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
    r"(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$")
_IPV6_RE = re.compile(r"^\[[0-9A-Fa-f:.]{2,45}\]$")
_WARNED_HOSTS = set()


def split_host_port(host):
    """Split an authority into (host, port). Handles [::1]:8095."""
    host = (host or "").strip()
    if host.startswith("["):
        end = host.find("]")
        if end == -1:
            return host, ""
        rest = host[end + 1:]
        port = rest[1:] if rest.startswith(":") else ""
        return host[:end + 1], port
    if host.count(":") == 1:
        name, _, port = host.partition(":")
        return name, port
    return host, ""


def valid_public_host(host):
    """True for an authority safe to put in a URL we hand to a phone."""
    name, port = split_host_port(host)
    if not name:
        return False
    if port and not (port.isdigit() and 0 < int(port) < 65536):
        return False
    if name.startswith("["):
        return bool(_IPV6_RE.match(name))
    return bool(_HOSTNAME_RE.match(name))


def host_matches(host, pattern):
    """Exact match, or a leading-wildcard suffix match (*.fnal.gov)."""
    name, _ = split_host_port(host)
    name = name.lower().rstrip(".")
    pattern = (pattern or "").lower().strip().rstrip(".")
    if not pattern:
        return False
    if pattern.startswith("*."):
        return name.endswith(pattern[1:]) and len(name) > len(pattern) - 1
    return name == pattern or split_host_port(pattern)[0] == name


def host_is_trusted(host, patterns):
    """An empty pattern list trusts whatever the request arrived on."""
    if not patterns:
        return True
    return any(host_matches(host, pattern) for pattern in patterns)


def _first(header):
    """Leftmost element of a comma-separated forwarded header.

    Leftmost is the client-facing value: each proxy appends, so the first entry
    is the hostname or scheme the phone actually used.
    """
    return (header or "").split(",")[0].strip()


def public_base_url(server_cfg, host="", scheme="https", forwarded_host="",
                    forwarded_proto="", url_root=""):
    """Resolve the externally reachable base URL for this request.

    Pure: takes the request's pieces rather than reading the request, so the
    precedence rules are directly testable.
    """
    configured = (server_cfg.get("base_url") or "").rstrip("/")
    fallback = configured or (url_root or "").rstrip("/")

    if not server_cfg.get("dynamic_base_url", True):
        return fallback

    candidate = _first(forwarded_host) or host
    if not valid_public_host(candidate):
        if candidate and candidate not in _WARNED_HOSTS:
            _WARNED_HOSTS.add(candidate)
            log.warning("ignoring malformed request host %r; using %s",
                        candidate, fallback or "(none)")
        return fallback

    proto = _first(forwarded_proto).lower()
    if proto not in ("http", "https"):
        proto = (scheme or "https").lower()

    name, port = split_host_port(candidate)
    if (proto == "https" and port == "443") or (proto == "http" and port == "80"):
        port = ""
    authority = "%s:%s" % (name, port) if port else name

    trusted = server_cfg.get("trusted_hosts") or []
    if not host_is_trusted(candidate, trusted):
        if configured:
            if candidate not in _WARNED_HOSTS:
                _WARNED_HOSTS.add(candidate)
                log.warning("request host %s is not in server.trusted_hosts; "
                            "using the configured base_url %s",
                            candidate, configured)
            return configured
        if candidate not in _WARNED_HOSTS:
            _WARNED_HOSTS.add(candidate)
            log.warning("request host %s is not in server.trusted_hosts and "
                        "server.base_url is unset; using the request host "
                        "anyway", candidate)

    return "%s://%s" % (proto, authority)


def enrollment_payload(base_url, token):
    """The JSON a phone reads out of the enrollment QR code."""
    return json.dumps({"type": "mu2edaq-notify-config",
                       "server_url": base_url,
                       "enrollment_token": token},
                      separators=(",", ":"))


def _base_url():
    return public_base_url(
        current_app.config["NOTIFY_CFG"]["server"],
        host=request.host,
        scheme=request.scheme,
        forwarded_host=request.headers.get("X-Forwarded-Host", ""),
        forwarded_proto=request.headers.get("X-Forwarded-Proto", ""),
        url_root=request.url_root)


def _storage():
    return current_app.config["NOTIFY_STORAGE"]


def _ingest(event):
    """Store a normalized event and hand it to the dispatcher."""
    stored = _storage().add_event(event)
    dispatcher = current_app.config["NOTIFY_DISPATCHER"]
    if dispatcher:
        dispatcher.submit(stored)
    else:
        current_app.config["NOTIFY_SSE"].publish("event", stored)
    return stored


def _read_access_ok():
    """History reads: any valid API/device token, a web session, or an
    entirely auth-less deployment (no tokens, no OIDC)."""
    cfg = current_app.config["NOTIFY_CFG"]
    token = auth.bearer_token()
    if token:
        if token in (cfg["auth"]["api_tokens"] or []):
            return True
        if _storage().device_by_token(token):
            return True
        return False
    if session.get("user"):
        return True
    return not cfg["auth"]["oidc"].get("enabled")


# --------------------------------------------------------------------------
# JSON API
# --------------------------------------------------------------------------

@api.route("/health")
def health():
    cfg = current_app.config["NOTIFY_CFG"]
    return jsonify(status="ok", version=__version__,
                   apns_enabled=cfg["apns"].get("enabled", False),
                   zmq_enabled=cfg["zmq"].get("enabled", False),
                   events=_storage().event_counts())


@api.route("/categories")
def list_categories():
    """The operator-configured canonical category list (``categories:``
    in notify-server.yaml). Events may carry any category string; this
    is only the suggested set used to populate pickers."""
    cfg = current_app.config["NOTIFY_CFG"]
    return jsonify(categories=cfg.get("categories") or [])


@api.route("/events", methods=["POST"])
@auth.require_api_token
def post_event():
    try:
        event = normalize_event(request.get_json(force=True, silent=False))
    except Exception as exc:
        abort(400, description="bad event payload: %s" % exc)
    stored = _ingest(event)
    return jsonify(stored), 201


@api.route("/events")
def list_events():
    if not _read_access_ok():
        abort(401, description="token or login required")
    limit = min(int(request.args.get("limit", 100)), 1000)
    events = _storage().list_events(
        limit=limit,
        severity=request.args.get("severity"),
        source=request.args.get("source"),
        category=request.args.get("category"),
        since_id=request.args.get("since_id", type=int))
    return jsonify(events=events)


@api.route("/events/<int:event_id>")
def get_event(event_id):
    if not _read_access_ok():
        abort(401, description="token or login required")
    event = _storage().get_event(event_id)
    if not event:
        abort(404, description="no such event")
    event["deliveries"] = _storage().deliveries_for_event(event_id)
    return jsonify(event)


@api.route("/devices/register", methods=["POST"])
def register_device():
    cfg = current_app.config["NOTIFY_CFG"]
    payload = request.get_json(force=True, silent=True) or {}
    if not auth.check_enrollment_token(cfg, payload.get("enrollment_token",
                                                        "")):
        abort(401, description="invalid or expired enrollment token")
    device, token = _storage().register_device(
        name=str(payload.get("name") or "iPhone")[:120],
        apns_token=str(payload.get("apns_token") or "")[:200])
    return jsonify(device=device, device_token=token,
                   server_url=_base_url()), 201


@api.route("/devices/token", methods=["POST"])
@auth.require_device_token
def update_apns_token():
    payload = request.get_json(force=True, silent=True) or {}
    apns_token = str(payload.get("apns_token") or "")[:200]
    if not apns_token:
        abort(400, description="apns_token required")
    device = _storage().update_device(request.device["id"],
                                      apns_token=apns_token)
    return jsonify(device=device)


@api.route("/devices/settings", methods=["POST"])
@auth.require_device_token
def update_device_settings():
    payload = request.get_json(force=True, silent=True) or {}
    fields = {}
    if payload.get("min_severity") in SEVERITIES:
        fields["min_severity"] = payload["min_severity"]
    if "name" in payload:
        fields["name"] = str(payload["name"])[:120]
    device = _storage().update_device(request.device["id"], **fields)
    return jsonify(device=device)


@api.route("/autoconfig/<token>")
def autoconfig(token):
    """Auto-configuration payload a phone fetches to set itself up."""
    cfg = current_app.config["NOTIFY_CFG"]
    if not auth.check_enrollment_token(cfg, token):
        abort(401, description="invalid or expired enrollment token")
    return jsonify(type="mu2edaq-notify-config", version=1,
                   server_url=_base_url(), enrollment_token=token,
                   register_endpoint="/api/devices/register")


@api.route("/stream")
def stream():
    if not _read_access_ok():
        abort(401, description="token or login required")
    hub = current_app.config["NOTIFY_SSE"]
    return Response(hub.stream(hub.subscribe()),
                    mimetype="text/event-stream",
                    headers={"Cache-Control": "no-cache",
                             "X-Accel-Buffering": "no"})


# --------------------------------------------------------------------------
# Web interface
# --------------------------------------------------------------------------

@web.route("/")
@auth.require_login
def dashboard():
    severity = request.args.get("severity") or None
    category = request.args.get("category") or None
    events = _storage().list_events(limit=100, severity=severity,
                                    category=category)
    return render_template("dashboard.html", events=events,
                           counts=_storage().event_counts(),
                           category_counts=_storage().category_counts(),
                           active_severity=severity,
                           active_category=category)

@web.route("/events/<int:event_id>")
@auth.require_login
def event_detail(event_id):
    event = _storage().get_event(event_id)
    if not event:
        abort(404, description="no such event")
    return render_template("event.html", event=event,
                           deliveries=_storage()
                           .deliveries_for_event(event_id))


@web.route("/filters", methods=["GET", "POST"])
@auth.require_login
def filters_page():
    if request.method == "POST":
        form = request.form
        name = form.get("name", "").strip()
        if name:
            _storage().upsert_filter(
                name,
                enabled=True,
                min_severity=form.get("min_severity", "warning"),
                source_pattern=form.get("source_pattern", "*") or "*",
                host_pattern=form.get("host_pattern", "*") or "*",
                category_pattern=form.get("category_pattern", "*") or "*",
                message_regex=form.get("message_regex", ""),
                destinations=form.getlist("destinations"))
        return redirect(url_for("web.filters_page"))
    return render_template("filters.html", filters=_storage().list_filters(),
                           destinations=_storage().list_destinations())


@web.route("/filters/<int:filter_id>/toggle", methods=["POST"])
@auth.require_login
def toggle_filter(filter_id):
    for rule in _storage().list_filters():
        if rule["id"] == filter_id:
            _storage().upsert_filter(rule["name"],
                                     enabled=not rule["enabled"])
    return redirect(url_for("web.filters_page"))


@web.route("/filters/<int:filter_id>/delete", methods=["POST"])
@auth.require_login
def delete_filter(filter_id):
    _storage().delete_filter(filter_id)
    return redirect(url_for("web.filters_page"))


@web.route("/destinations", methods=["GET", "POST"])
@auth.require_login
def destinations_page():
    if request.method == "POST":
        form = request.form
        name = form.get("name", "").strip()
        if name and form.get("type") in ("apns", "slack", "discord"):
            _storage().upsert_destination(
                name, type=form["type"], enabled=True,
                webhook_url=form.get("webhook_url", "").strip())
        return redirect(url_for("web.destinations_page"))
    return render_template("destinations.html",
                           destinations=_storage().list_destinations())


@web.route("/destinations/<int:dest_id>/toggle", methods=["POST"])
@auth.require_login
def toggle_destination(dest_id):
    for dest in _storage().list_destinations():
        if dest["id"] == dest_id:
            _storage().upsert_destination(dest["name"],
                                          enabled=not dest["enabled"])
    return redirect(url_for("web.destinations_page"))


@web.route("/destinations/<int:dest_id>/delete", methods=["POST"])
@auth.require_login
def delete_destination(dest_id):
    _storage().delete_destination(dest_id)
    return redirect(url_for("web.destinations_page"))


@web.route("/devices")
@auth.require_login
def devices_page():
    return render_template("devices.html", devices=_storage().list_devices())


@web.route("/devices/enroll", methods=["POST"])
@auth.require_login
def enroll_device():
    cfg = current_app.config["NOTIFY_CFG"]
    token = auth.make_enrollment_token(cfg)
    return render_template(
        "enroll.html", token=token, base_url=_base_url(),
        ttl_minutes=cfg["auth"].get("enrollment_ttl_minutes", 30),
        autoconfig_url="%s/api/autoconfig/%s" % (_base_url(), token))


@web.route("/devices/qr.png")
@auth.require_login
def enrollment_qr():
    token = request.args.get("token", "")
    cfg = current_app.config["NOTIFY_CFG"]
    if not auth.check_enrollment_token(cfg, token):
        abort(404, description="invalid or expired enrollment token")
    payload = enrollment_payload(_base_url(), token)
    buf = io.BytesIO()
    segno.make(payload, error="m").save(buf, kind="png", scale=6,
                                        border=2)
    buf.seek(0)
    return send_file(buf, mimetype="image/png")


@web.route("/devices/<int:device_id>/toggle", methods=["POST"])
@auth.require_login
def toggle_device(device_id):
    for dev in _storage().list_devices():
        if dev["id"] == device_id:
            _storage().update_device(device_id, enabled=not dev["enabled"])
    return redirect(url_for("web.devices_page"))


@web.route("/devices/<int:device_id>/delete", methods=["POST"])
@auth.require_login
def delete_device(device_id):
    _storage().delete_device(device_id)
    return redirect(url_for("web.devices_page"))


@web.route("/test-event", methods=["POST"])
@auth.require_login
def test_event():
    event = normalize_event({
        "source": "web-ui",
        "severity": request.form.get("severity", "warning"),
        "category": request.form.get("category", ""),
        "title": request.form.get("title") or "Test notification",
        "message": request.form.get("message")
        or "Test event sent from the web interface.",
    })
    _ingest(event)
    return redirect(url_for("web.dashboard"))


@web.route("/about")
@auth.require_login
def about():
    return render_template("about.html")


@web.route("/api-docs")
@auth.require_login
def api_docs():
    return render_template("api.html")


@web.route("/sitemap")
@auth.require_login
def sitemap():
    return render_template("sitemap.html")


# Login / logout -------------------------------------------------------------

@web.route("/login")
def login():
    oauth = current_app.config["NOTIFY_OAUTH"]
    if oauth is None:
        return redirect(url_for("web.dashboard"))
    redirect_uri = url_for("web.auth_callback", _external=True)
    return oauth.fnal.authorize_redirect(redirect_uri)


@web.route("/auth")
def auth_callback():
    oauth = current_app.config["NOTIFY_OAUTH"]
    if oauth is None:
        return redirect(url_for("web.dashboard"))
    token = oauth.fnal.authorize_access_token()
    session["user"] = token.get("userinfo") or {}
    return redirect(session.pop("next_url", url_for("web.dashboard")))


@web.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("web.dashboard"))
