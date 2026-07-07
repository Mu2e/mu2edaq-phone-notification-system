"""SQLAlchemy storage layer.

SQLite by default; any SQLAlchemy URL works (set ``database.url`` to a
``postgresql+psycopg2://`` URL to move to Postgres, no code changes).
"""
from __future__ import annotations

import hashlib
import json
import os
import secrets
from datetime import datetime, timedelta, timezone

from sqlalchemy import (Boolean, Column, DateTime, ForeignKey, Integer,
                        String, Text, create_engine)
from sqlalchemy.orm import declarative_base, sessionmaker

Base = declarative_base()


def _utcnow():
    return datetime.now(timezone.utc).replace(tzinfo=None)  # store naive UTC


class Event(Base):
    __tablename__ = "events"
    id = Column(Integer, primary_key=True)
    source = Column(String(100), nullable=False, index=True)
    host = Column(String(100), nullable=False, default="")
    severity = Column(String(16), nullable=False, index=True)
    title = Column(String(200), nullable=False)
    message = Column(Text, nullable=False, default="")
    timestamp = Column(String(40), nullable=False, default="")
    received_at = Column(DateTime, nullable=False, default=_utcnow, index=True)
    meta_json = Column(Text, nullable=False, default="{}")

    def to_dict(self):
        return {
            "id": self.id,
            "source": self.source,
            "host": self.host,
            "severity": self.severity,
            "title": self.title,
            "message": self.message,
            "timestamp": self.timestamp,
            "received_at": self.received_at.replace(
                tzinfo=timezone.utc).isoformat(timespec="seconds"),
            "meta": json.loads(self.meta_json or "{}"),
        }


class Device(Base):
    __tablename__ = "devices"
    id = Column(Integer, primary_key=True)
    name = Column(String(120), nullable=False, default="iPhone")
    apns_token = Column(String(200), nullable=False, default="")
    token_hash = Column(String(64), nullable=False, unique=True)
    enabled = Column(Boolean, nullable=False, default=True)
    min_severity = Column(String(16), nullable=False, default="warning")
    created_at = Column(DateTime, nullable=False, default=_utcnow)
    last_seen = Column(DateTime, nullable=False, default=_utcnow)

    def to_dict(self):
        return {
            "id": self.id,
            "name": self.name,
            "enabled": self.enabled,
            "min_severity": self.min_severity,
            "has_apns_token": bool(self.apns_token),
            "created_at": self.created_at.isoformat(timespec="seconds"),
            "last_seen": self.last_seen.isoformat(timespec="seconds"),
        }


class FilterRule(Base):
    __tablename__ = "filter_rules"
    id = Column(Integer, primary_key=True)
    name = Column(String(120), nullable=False, unique=True)
    enabled = Column(Boolean, nullable=False, default=True)
    min_severity = Column(String(16), nullable=False, default="warning")
    source_pattern = Column(String(200), nullable=False, default="*")
    host_pattern = Column(String(200), nullable=False, default="*")
    message_regex = Column(String(400), nullable=False, default="")
    destinations_json = Column(Text, nullable=False, default="[]")

    @property
    def destinations(self):
        return json.loads(self.destinations_json or "[]")

    def to_dict(self):
        return {
            "id": self.id,
            "name": self.name,
            "enabled": self.enabled,
            "min_severity": self.min_severity,
            "source_pattern": self.source_pattern,
            "host_pattern": self.host_pattern,
            "message_regex": self.message_regex,
            "destinations": self.destinations,
        }


class Destination(Base):
    __tablename__ = "destinations"
    id = Column(Integer, primary_key=True)
    name = Column(String(120), nullable=False, unique=True)
    type = Column(String(16), nullable=False)  # apns | slack | discord
    enabled = Column(Boolean, nullable=False, default=True)
    webhook_url = Column(String(400), nullable=False, default="")

    def to_dict(self):
        return {
            "id": self.id,
            "name": self.name,
            "type": self.type,
            "enabled": self.enabled,
            "webhook_url": self.webhook_url,
        }


class Delivery(Base):
    __tablename__ = "deliveries"
    id = Column(Integer, primary_key=True)
    event_id = Column(Integer, ForeignKey("events.id"), nullable=False,
                      index=True)
    destination = Column(String(120), nullable=False)
    target = Column(String(200), nullable=False, default="")
    status = Column(String(16), nullable=False)  # sent | logged | failed | suppressed
    detail = Column(String(400), nullable=False, default="")
    created_at = Column(DateTime, nullable=False, default=_utcnow)

    def to_dict(self):
        return {
            "id": self.id,
            "event_id": self.event_id,
            "destination": self.destination,
            "target": self.target,
            "status": self.status,
            "detail": self.detail,
            "created_at": self.created_at.isoformat(timespec="seconds"),
        }


def hash_token(token):
    return hashlib.sha256(token.encode()).hexdigest()


def new_device_token():
    return "mu2edev-" + secrets.token_urlsafe(32)


class Storage:
    """Thread-safe facade over the database (sessions per operation)."""

    def __init__(self, db_url):
        if db_url.startswith("sqlite:///"):
            path = db_url[len("sqlite:///"):]
            if path and not os.path.isabs(path):
                os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        self.engine = create_engine(
            db_url, future=True,
            connect_args={"check_same_thread": False}
            if db_url.startswith("sqlite") else {})
        Base.metadata.create_all(self.engine)
        self._session_factory = sessionmaker(bind=self.engine, future=True,
                                             expire_on_commit=False)

    def session(self):
        return self._session_factory()

    # Events ---------------------------------------------------------------
    def add_event(self, event):
        with self.session() as s:
            row = Event(source=event["source"], host=event["host"],
                        severity=event["severity"], title=event["title"],
                        message=event["message"],
                        timestamp=event["timestamp"],
                        meta_json=json.dumps(event.get("meta", {})))
            s.add(row)
            s.commit()
            return row.to_dict()

    def get_event(self, event_id):
        with self.session() as s:
            row = s.get(Event, event_id)
            return row.to_dict() if row else None

    def list_events(self, limit=100, severity=None, source=None, since_id=None):
        with self.session() as s:
            q = s.query(Event).order_by(Event.id.desc())
            if severity:
                q = q.filter(Event.severity == severity)
            if source:
                q = q.filter(Event.source == source)
            if since_id:
                q = q.filter(Event.id > since_id)
            return [r.to_dict() for r in q.limit(limit).all()]

    def event_counts(self):
        with self.session() as s:
            out = {}
            for sev, in s.query(Event.severity).all():
                out[sev] = out.get(sev, 0) + 1
            return out

    def prune_events(self, retention_days):
        if not retention_days:
            return 0
        cutoff = _utcnow() - timedelta(days=retention_days)
        with self.session() as s:
            old = s.query(Event).filter(Event.received_at < cutoff)
            ids = [e.id for e in old.all()]
            if ids:
                s.query(Delivery).filter(Delivery.event_id.in_(ids)).delete(
                    synchronize_session=False)
                s.query(Event).filter(Event.id.in_(ids)).delete(
                    synchronize_session=False)
                s.commit()
            return len(ids)

    # Devices --------------------------------------------------------------
    def register_device(self, name, apns_token=""):
        token = new_device_token()
        with self.session() as s:
            row = Device(name=name or "iPhone", apns_token=apns_token,
                         token_hash=hash_token(token))
            s.add(row)
            s.commit()
            return row.to_dict(), token

    def device_by_token(self, token):
        with self.session() as s:
            row = (s.query(Device)
                   .filter(Device.token_hash == hash_token(token)).first())
            if row:
                row.last_seen = _utcnow()
                s.commit()
            return row.to_dict() if row else None

    def update_device(self, device_id, **fields):
        with self.session() as s:
            row = s.get(Device, device_id)
            if not row:
                return None
            for key in ("name", "apns_token", "enabled", "min_severity"):
                if key in fields and fields[key] is not None:
                    setattr(row, key, fields[key])
            row.last_seen = _utcnow()
            s.commit()
            return row.to_dict()

    def delete_device(self, device_id):
        with self.session() as s:
            row = s.get(Device, device_id)
            if row:
                s.delete(row)
                s.commit()
                return True
            return False

    def list_devices(self):
        with self.session() as s:
            return [d.to_dict() for d in s.query(Device).order_by(Device.id)]

    def apns_targets(self, severity):
        """Enabled devices whose min_severity admits this event."""
        from ..events import severity_index
        rank = severity_index(severity)
        with self.session() as s:
            rows = s.query(Device).filter(Device.enabled.is_(True)).all()
            return [{"id": d.id, "name": d.name, "apns_token": d.apns_token}
                    for d in rows
                    if d.apns_token and severity_index(d.min_severity) <= rank]

    # Filters / destinations -----------------------------------------------
    def list_filters(self):
        with self.session() as s:
            return [f.to_dict() for f in
                    s.query(FilterRule).order_by(FilterRule.id)]

    def upsert_filter(self, name, **fields):
        with self.session() as s:
            row = s.query(FilterRule).filter(FilterRule.name == name).first()
            if not row:
                row = FilterRule(name=name)
                s.add(row)
            for key in ("enabled", "min_severity", "source_pattern",
                        "host_pattern", "message_regex"):
                if key in fields and fields[key] is not None:
                    setattr(row, key, fields[key])
            if fields.get("destinations") is not None:
                row.destinations_json = json.dumps(fields["destinations"])
            s.commit()
            return row.to_dict()

    def delete_filter(self, filter_id):
        with self.session() as s:
            row = s.get(FilterRule, filter_id)
            if row:
                s.delete(row)
                s.commit()
                return True
            return False

    def list_destinations(self):
        with self.session() as s:
            return [d.to_dict() for d in
                    s.query(Destination).order_by(Destination.id)]

    def upsert_destination(self, name, **fields):
        with self.session() as s:
            row = s.query(Destination).filter(
                Destination.name == name).first()
            if not row:
                row = Destination(name=name, type=fields.get("type", "slack"))
                s.add(row)
            for key in ("type", "enabled", "webhook_url"):
                if key in fields and fields[key] is not None:
                    setattr(row, key, fields[key])
            s.commit()
            return row.to_dict()

    def delete_destination(self, dest_id):
        with self.session() as s:
            row = s.get(Destination, dest_id)
            if row:
                s.delete(row)
                s.commit()
                return True
            return False

    # Deliveries -------------------------------------------------------------
    def add_delivery(self, event_id, destination, target, status, detail=""):
        with self.session() as s:
            row = Delivery(event_id=event_id, destination=destination,
                           target=target[:200], status=status,
                           detail=detail[:400])
            s.add(row)
            s.commit()
            return row.to_dict()

    def deliveries_for_event(self, event_id):
        with self.session() as s:
            return [d.to_dict() for d in
                    s.query(Delivery).filter(Delivery.event_id == event_id)
                    .order_by(Delivery.id)]

    def seed(self, seed_cfg):
        """Load config-file filters/destinations if the tables are empty."""
        if not self.list_destinations():
            for dest in seed_cfg.get("destinations", []) or []:
                if dest.get("name") and dest.get("type"):
                    self.upsert_destination(
                        dest["name"], type=dest["type"],
                        webhook_url=dest.get("webhook_url", ""),
                        enabled=dest.get("enabled", True))
        if not self.list_filters():
            for rule in seed_cfg.get("filters", []) or []:
                if rule.get("name"):
                    self.upsert_filter(
                        rule["name"],
                        enabled=rule.get("enabled", True),
                        min_severity=rule.get("min_severity", "warning"),
                        source_pattern=rule.get("source_pattern", "*"),
                        host_pattern=rule.get("host_pattern", "*"),
                        message_regex=rule.get("message_regex", ""),
                        destinations=rule.get("destinations", []))
