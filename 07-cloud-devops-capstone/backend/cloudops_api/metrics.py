"""Tiny in-process metrics registry exposed in Prometheus text format at /metrics.

No client library: a counter per (method, path-template, status), a latency histogram and
process uptime are enough to draw request rate, error rate and p95 in Grafana/Prometheus or to
scrape with curl. Values are per worker process (gunicorn runs 2), which is fine for a demo and
documented in docs/architecture.md.
"""

from __future__ import annotations

import threading
import time
from collections import defaultdict

BUCKETS = (5, 10, 25, 50, 100, 250, 500, 1000, 2500)  # milliseconds


class Metrics:
    def __init__(self):
        self._lock = threading.Lock()
        self._started = time.time()
        self._requests: dict[tuple[str, str, int], int] = defaultdict(int)
        self._latency_buckets: dict[str, list[int]] = defaultdict(lambda: [0] * (len(BUCKETS) + 1))
        self._latency_sum: dict[str, float] = defaultdict(float)
        self._latency_count: dict[str, int] = defaultdict(int)

    def observe(self, method: str, route: str, status: int, duration_ms: float) -> None:
        with self._lock:
            self._requests[(method, route, status)] += 1
            buckets = self._latency_buckets[route]
            for i, upper in enumerate(BUCKETS):
                if duration_ms <= upper:
                    buckets[i] += 1
                    break
            else:
                buckets[-1] += 1
            self._latency_sum[route] += duration_ms
            self._latency_count[route] += 1

    def render(self) -> str:
        lines = [
            "# HELP cloudops_http_requests_total Requests by method, route and status.",
            "# TYPE cloudops_http_requests_total counter",
        ]
        with self._lock:
            for (method, route, status), n in sorted(self._requests.items()):
                lines.append(
                    f'cloudops_http_requests_total{{method="{method}",route="{route}",'
                    f'status="{status}"}} {n}'
                )
            lines += [
                "# HELP cloudops_http_request_duration_ms Request latency in milliseconds.",
                "# TYPE cloudops_http_request_duration_ms histogram",
            ]
            for route, buckets in sorted(self._latency_buckets.items()):
                cumulative = 0
                for upper, n in zip(BUCKETS, buckets[:-1], strict=True):
                    cumulative += n
                    lines.append(
                        f'cloudops_http_request_duration_ms_bucket{{route="{route}",le="{upper}"}} '
                        f"{cumulative}"
                    )
                cumulative += buckets[-1]
                lines.append(
                    f'cloudops_http_request_duration_ms_bucket{{route="{route}",le="+Inf"}} '
                    f"{cumulative}"
                )
                lines.append(
                    f'cloudops_http_request_duration_ms_sum{{route="{route}"}} '
                    f"{self._latency_sum[route]:.3f}"
                )
                lines.append(
                    f'cloudops_http_request_duration_ms_count{{route="{route}"}} '
                    f"{self._latency_count[route]}"
                )
        lines += [
            "# HELP cloudops_process_uptime_seconds Seconds since this worker started.",
            "# TYPE cloudops_process_uptime_seconds gauge",
            f"cloudops_process_uptime_seconds {time.time() - self._started:.1f}",
        ]
        return "\n".join(lines) + "\n"

    def totals(self) -> dict:
        with self._lock:
            total = sum(self._requests.values())
            errors = sum(n for (_, _, s), n in self._requests.items() if s >= 500)
        return {
            "requests": total,
            "errors_5xx": errors,
            "uptime_seconds": round(time.time() - self._started, 1),
        }
