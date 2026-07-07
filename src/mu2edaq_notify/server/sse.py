"""Server-Sent Events hub for the live web dashboard."""
from __future__ import annotations

import json
import queue
import threading


class SseHub:
    def __init__(self, max_queue=200):
        self._clients = set()
        self._lock = threading.Lock()
        self._max_queue = max_queue

    def subscribe(self):
        q = queue.Queue(maxsize=self._max_queue)
        with self._lock:
            self._clients.add(q)
        return q

    def unsubscribe(self, q):
        with self._lock:
            self._clients.discard(q)

    def publish(self, event_type, data):
        message = "event: %s\ndata: %s\n\n" % (event_type, json.dumps(data))
        with self._lock:
            clients = list(self._clients)
        for q in clients:
            try:
                q.put_nowait(message)
            except queue.Full:
                pass  # slow client; it will catch up or drop off

    def stream(self, q, keepalive=25.0):
        """Generator for a Flask streaming response."""
        try:
            yield "retry: 3000\n\n"
            while True:
                try:
                    yield q.get(timeout=keepalive)
                except queue.Empty:
                    yield ": keepalive\n\n"
        finally:
            self.unsubscribe(q)
