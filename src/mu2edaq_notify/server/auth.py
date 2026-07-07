"""Authentication: publisher API tokens, device bearer tokens, device
enrollment tokens (signed, short-lived), and optional Fermilab SSO
(OIDC) for the web interface.
"""
from __future__ import annotations

import functools
import logging
import time

import jwt
from flask import (abort, current_app, redirect, request, session, url_for)

log = logging.getLogger(__name__)


def bearer_token():
    header = request.headers.get("Authorization", "")
    if header.startswith("Bearer "):
        return header[len("Bearer "):].strip()
    return None


def require_api_token(view):
    """Publisher endpoints: token must be in ``auth.api_tokens``."""
    @functools.wraps(view)
    def wrapped(*args, **kwargs):
        cfg = current_app.config["NOTIFY_CFG"]
        tokens = cfg["auth"]["api_tokens"] or []
        token = bearer_token()
        if not tokens:
            # No tokens configured: accept (bootstrap / closed network).
            return view(*args, **kwargs)
        if token and token in tokens:
            return view(*args, **kwargs)
        abort(401, description="valid API bearer token required")
    return wrapped


def require_device_token(view):
    """Device endpoints: token must map to a registered device."""
    @functools.wraps(view)
    def wrapped(*args, **kwargs):
        token = bearer_token()
        device = (current_app.config["NOTIFY_STORAGE"].device_by_token(token)
                  if token else None)
        if not device:
            abort(401, description="valid device bearer token required")
        request.device = device
        return view(*args, **kwargs)
    return wrapped


# Enrollment tokens ---------------------------------------------------------

def make_enrollment_token(cfg):
    ttl = int(cfg["auth"].get("enrollment_ttl_minutes", 30)) * 60
    return jwt.encode({"purpose": "enroll", "exp": int(time.time()) + ttl},
                      cfg["auth"]["enrollment_secret"], algorithm="HS256")


def check_enrollment_token(cfg, token):
    try:
        claims = jwt.decode(token, cfg["auth"]["enrollment_secret"],
                            algorithms=["HS256"])
        return claims.get("purpose") == "enroll"
    except jwt.PyJWTError as exc:
        log.debug("enrollment token rejected: %s", exc)
        return False


# Web-interface login (Fermilab SSO via OIDC) -------------------------------

def init_oidc(app, cfg):
    """Register the Authlib OIDC client if enabled. Returns it or None."""
    oidc_cfg = cfg["auth"]["oidc"]
    if not oidc_cfg.get("enabled"):
        return None
    from authlib.integrations.flask_client import OAuth
    oauth = OAuth(app)
    oauth.register(
        name="fnal",
        client_id=oidc_cfg["client_id"],
        client_secret=oidc_cfg["client_secret"],
        server_metadata_url=oidc_cfg["issuer"].rstrip("/")
        + "/.well-known/openid-configuration",
        client_kwargs={"scope": "openid email profile"},
    )
    return oauth


def require_login(view):
    """Web pages: enforce OIDC login when enabled, no-op otherwise."""
    @functools.wraps(view)
    def wrapped(*args, **kwargs):
        cfg = current_app.config["NOTIFY_CFG"]
        if not cfg["auth"]["oidc"].get("enabled"):
            return view(*args, **kwargs)
        user = session.get("user")
        if not user:
            session["next_url"] = request.url
            return redirect(url_for("web.login"))
        allowed = cfg["auth"]["oidc"].get("allowed_users") or []
        if allowed and user.get("email") not in allowed \
                and user.get("preferred_username") not in allowed:
            abort(403, description="user not in allowed_users")
        return view(*args, **kwargs)
    return wrapped
