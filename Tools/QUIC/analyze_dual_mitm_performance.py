#!/usr/bin/env python3
"""
Analyze dual MITM performance from VPN NDJSON logs.

Usage:
  python3 Tools/QUIC/analyze_dual_mitm_performance.py /path/to/vpn_events.ndjson [...]
"""

from __future__ import annotations

import argparse
import json
import math
import re
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional


KV_RE = re.compile(r"([A-Za-z0-9_]+)=([^ ]+)")


@dataclass
class Event:
    ts: float
    type: str
    msg: str
    kv: Dict[str, str]


def parse_kv(message: str) -> Dict[str, str]:
    return {key: value for key, value in KV_RE.findall(message)}


def load_events(paths: List[Path]) -> List[Event]:
    events: List[Event] = []
    for path in paths:
        with path.open("r", encoding="utf-8") as handle:
            for raw in handle:
                line = raw.strip()
                if not line:
                    continue
                try:
                    item = json.loads(line)
                except json.JSONDecodeError:
                    continue
                ts = item.get("ts")
                event_type = item.get("type")
                msg = item.get("msg", "")
                if ts is None or event_type is None:
                    continue
                try:
                    ts_value = float(ts)
                except (TypeError, ValueError):
                    continue
                if not isinstance(event_type, str):
                    continue
                if not isinstance(msg, str):
                    msg = str(msg)
                events.append(Event(ts=ts_value, type=event_type, msg=msg, kv=parse_kv(msg)))
    events.sort(key=lambda event: event.ts)
    return events


def quantile(values: List[float], q: float) -> Optional[float]:
    if not values:
        return None
    if q <= 0:
        return min(values)
    if q >= 1:
        return max(values)
    ordered = sorted(values)
    index = (len(ordered) - 1) * q
    lower = math.floor(index)
    upper = math.ceil(index)
    if lower == upper:
        return ordered[lower]
    weight = index - lower
    return ordered[lower] * (1 - weight) + ordered[upper] * weight


def ms(seconds: float) -> float:
    return seconds * 1000.0


def format_ms(value: Optional[float]) -> str:
    if value is None:
        return "n/a"
    return f"{value:.1f} ms"


def print_quantiles(label: str, values_seconds: List[float]) -> None:
    if not values_seconds:
        print(f"- {label}: n/a")
        return
    values_ms = [ms(v) for v in values_seconds]
    p50 = quantile(values_ms, 0.50)
    p95 = quantile(values_ms, 0.95)
    p99 = quantile(values_ms, 0.99)
    print(
        f"- {label}: count={len(values_ms)} p50={format_ms(p50)} "
        f"p95={format_ms(p95)} p99={format_ms(p99)}"
    )


def startup_timings(events: List[Event]) -> None:
    startup_ts = next((event.ts for event in events if event.type == "startup"), None)
    packet_flow_ts = next((event.ts for event in events if event.type == "packet_flow_config"), None)
    socks_ready_ts = next(
        (
            event.ts
            for event in events
            if event.type == "local_socks5_server" and event.kv.get("outcome") == "success"
        ),
        None,
    )
    udp_support_ts = next(
        (
            event.ts
            for event in events
            if event.type == "udp_tunnel_support" and event.kv.get("supported") == "true"
        ),
        None,
    )

    print("Startup timings")
    if startup_ts is None:
        print("- startup anchor not found")
        return

    print(
        f"- startup -> packet_flow_config: "
        f"{format_ms(ms(packet_flow_ts - startup_ts) if packet_flow_ts is not None else None)}"
    )
    print(
        f"- startup -> local_socks5_server(success): "
        f"{format_ms(ms(socks_ready_ts - startup_ts) if socks_ready_ts is not None else None)}"
    )
    print(
        f"- startup -> udp_tunnel_support(supported=true): "
        f"{format_ms(ms(udp_support_ts - startup_ts) if udp_support_ts is not None else None)}"
    )


def quic_intercept_metrics(events: List[Event]) -> None:
    first_intercepted_by_flow: Dict[str, float] = {}
    pass_through_durations: List[float] = []
    pass_through_reasons: Counter[str] = Counter()
    event_count_by_flow: Counter[str] = Counter()
    no_progress_durations: List[float] = []

    for event in events:
        if event.type == "quic_intercept":
            flow_id = event.kv.get("flow_id")
            if flow_id:
                event_count_by_flow[flow_id] += 1
            outcome = event.kv.get("outcome")
            if outcome == "intercepted" and flow_id and flow_id not in first_intercepted_by_flow:
                first_intercepted_by_flow[flow_id] = event.ts
            elif outcome == "pass_through" and flow_id and flow_id in first_intercepted_by_flow:
                pass_through_durations.append(event.ts - first_intercepted_by_flow[flow_id])
                pass_through_reasons[event.kv.get("reason", "unknown")] += 1

        if event.type == "quic_mitm_session" and event.kv.get("outcome") == "no_progress_fail_open":
            flow_id = event.kv.get("flow_id")
            if flow_id and flow_id in first_intercepted_by_flow:
                no_progress_durations.append(event.ts - first_intercepted_by_flow[flow_id])

    print("QUIC fail-open timings")
    print_quantiles("intercepted -> pass_through", pass_through_durations)
    print_quantiles("intercepted -> no_progress_fail_open", no_progress_durations)
    if pass_through_reasons:
        joined = ", ".join(f"{reason}:{count}" for reason, count in pass_through_reasons.most_common(8))
        print(f"- pass_through reasons: {joined}")
    else:
        print("- pass_through reasons: n/a")

    print("QUIC route decision volume")
    counts = list(event_count_by_flow.values())
    if not counts:
        print("- no quic_intercept flow data")
        return
    p50 = quantile(counts, 0.50)
    p95 = quantile(counts, 0.95)
    print(f"- events per flow: flows={len(counts)} p50={p50:.1f} p95={p95:.1f} max={max(counts)}")
    top_flows = event_count_by_flow.most_common(10)
    rendered = ", ".join(f"{flow}:{count}" for flow, count in top_flows)
    print(f"- top flows: {rendered}")


def tcp_mitm_stage_metrics(events: List[Event]) -> None:
    stage_ts_by_flow: Dict[str, Dict[str, float]] = defaultdict(dict)

    for event in events:
        if event.type != "proxy_nio_transparent_tls":
            continue
        flow_id = event.kv.get("flow_id")
        if not flow_id:
            continue
        stage = event.kv.get("stage")
        if not stage:
            continue
        if stage not in stage_ts_by_flow[flow_id]:
            stage_ts_by_flow[flow_id][stage] = event.ts

    start_to_sni: List[float] = []
    start_to_prepare: List[float] = []
    start_to_connect_begin: List[float] = []
    sni_to_prepare: List[float] = []

    for stages in stage_ts_by_flow.values():
        start = stages.get("upstream_hint")
        sni = stages.get("sni_detected")
        prepare = stages.get("mitm_prepare")
        connect = stages.get("mitm_connect")
        if start and sni and sni >= start:
            start_to_sni.append(sni - start)
        if start and prepare and prepare >= start:
            start_to_prepare.append(prepare - start)
        if start and connect and connect >= start:
            start_to_connect_begin.append(connect - start)
        if sni and prepare and prepare >= sni:
            sni_to_prepare.append(prepare - sni)

    print("TCP MITM stage timings")
    print_quantiles("upstream_hint -> sni_detected", start_to_sni)
    print_quantiles("upstream_hint -> mitm_prepare", start_to_prepare)
    print_quantiles("upstream_hint -> mitm_connect", start_to_connect_begin)
    print_quantiles("sni_detected -> mitm_prepare", sni_to_prepare)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Analyze dual MITM NDJSON performance logs")
    parser.add_argument(
        "paths",
        nargs="+",
        help="NDJSON log file path(s)",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    paths = [Path(raw).expanduser().resolve() for raw in args.paths]
    missing = [str(path) for path in paths if not path.exists()]
    if missing:
        print("Missing input files:")
        for path in missing:
            print(f"- {path}")
        return 1

    events = load_events(paths)
    if not events:
        print("No events found in provided file(s).")
        return 1

    print(f"Loaded {len(events)} events from {len(paths)} file(s).")
    startup_timings(events)
    print()
    tcp_mitm_stage_metrics(events)
    print()
    quic_intercept_metrics(events)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
