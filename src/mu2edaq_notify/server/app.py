"""Flask application: JSON API + web interface."""
from __future__ import annotations

import io
import logging
import os
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


def _base_url():
    configured = current_app.config["NOTIFY_CFG"]["server"].get("base_url")
    return (configured or request.url_root).rstrip("/")


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
    events = _storage().list_events(limit=100, severity=severity)
    return render_template("dashboard.html", events=events,
                           counts=_storage().event_counts(),
                           active_severity=severity)

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
    payload = ('{"type":"mu2edaq-notify-config","server_url":"%s",'
               '"enrollment_token":"%s"}' % (_base_url(), token))
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
