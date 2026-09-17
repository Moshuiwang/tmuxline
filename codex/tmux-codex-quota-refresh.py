#!/usr/bin/env python3
"""Fetch Codex account limits and write a tiny tmux-friendly cache.

This helper deliberately does not start a Codex model run.  It first uses the
existing local WHAM provider and only falls back to the app-server proxy when
the provider is unavailable.  The hook wrapper is responsible for locking
and detaching this process from Codex.
"""

from __future__ import annotations

import os
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path


CODEX_DIR = Path("/home/wangzp/.codex")
STATE_DIR = Path(os.environ.get("TMUX_CODEX_STATE_DIR", "/home/wangzp/.local/state/tmux-codex-quota"))
AUTH_FILE = CODEX_DIR / "auth.json"
RPC_SOCKET = CODEX_DIR / "app-server-control" / "app-server-control.sock"
WIDGET_ROOT = Path("/home/wangzp/ai-usage-widget")
CACHE_FILE = STATE_DIR / "tmux-codex-usage.dat"
HISTORY_FILE = STATE_DIR / "tmux-codex-usage-5h.hist"
WEEK_HISTORY_FILE = STATE_DIR / "tmux-codex-usage-7d.hist"

# 周燃速参数,与 ~/.claude/tmux-claude-usage-rate.sh 同算法(2026-09-17):
# 缓存末尾多两列「24h 燃速(%/周) 上周终值%」,渲染器据此在周初与冲刺当天也能给出预测。
WEEK = 604800
RATE24_WIN = 86400
RATE24_MIN_SPAN = 21600
WEEK_HISTORY_KEEP = 2500

sys.path.insert(0, str(WIDGET_ROOT))

from ai_usage_widget.codex_limits_provider import (  # noqa: E402
    CodexAppServerRPCProvider,
    CodexWhamProvider,
)


def main() -> int:
    windows, errors = _collect_windows()
    if not windows:
        # Keep diagnostics local and deliberately omit exception text because
        # provider errors can contain environment-specific details.
        print("Codex quota refresh failed: " + ", ".join(errors), file=sys.stderr)
        return 1

    observed_at = int(time.time())
    h5 = _pick_window(windows, short=True)
    week = _pick_window(windows, short=False)

    week_pct, week_reset = _percent(week), _reset_epoch(week)
    history = _append_week_history(observed_at, week_pct, week_reset)
    r24, lf = _week_rate(history, observed_at, week_pct, week_reset)

    values = [
        str(observed_at),
        _percent(h5),
        _reset_epoch(h5),
        week_pct,
        week_reset,
        r24,
        lf,
    ]
    _atomic_write(CACHE_FILE, " ".join(values) + "\n")

    if h5 is not None:
        _append_history(observed_at, _percent(h5), _reset_epoch(h5))
    return 0


def _collect_windows():
    errors: list[str] = []

    try:
        return CodexWhamProvider(auth_file=str(AUTH_FILE), timeout=8.0).collect(), errors
    except Exception as exc:  # provider failures must not break Codex hooks
        errors.append(f"wham:{exc.__class__.__name__}")

    if RPC_SOCKET.exists():
        try:
            return (
                CodexAppServerRPCProvider(socket_path=str(RPC_SOCKET), timeout=8.0).collect(),
                errors,
            )
        except Exception as exc:
            errors.append(f"rpc:{exc.__class__.__name__}")

    return [], errors


def _pick_window(windows, *, short: bool):
    candidates = []
    for window in windows:
        duration = int(getattr(window, "window_duration_minutes", 0) or 0)
        name = str(getattr(window, "window", "")).lower()
        # A reported duration is authoritative; the label is only a fallback
        # for responses that omit it. Letting the name win outright misfiled
        # this account's sole weekly window -- itself named "session" -- as
        # a 5h window as well, which then wrote a phantom 5h entry to the
        # cache.
        if duration > 0:
            is_short = duration <= 6 * 60
            is_week = duration >= 24 * 60
        else:
            is_short = name in {"session", "primary", "5h"}
            is_week = name in {"week", "weekly", "secondary", "7d"}
        if (short and is_short) or (not short and is_week):
            candidates.append(window)

    if candidates:
        return sorted(candidates, key=lambda item: int(getattr(item, "window_duration_minutes", 0) or 0))[0]

    # Be conservative if a future response uses unfamiliar labels: with two
    # windows, the shorter one is still the best 5h candidate and the longer
    # one the best weekly candidate. A single long window is different: some
    # accounts do not have a 5h quota at all, so never reinterpret that weekly
    # window as 5h.
    ordered = sorted(windows, key=lambda item: int(getattr(item, "window_duration_minutes", 0) or 0))
    if not ordered:
        return None
    if short:
        return ordered[0] if len(ordered) > 1 else None
    return ordered[-1] if len(ordered) > 1 else None


def _percent(window) -> str:
    if window is None:
        return "-"
    value = float(getattr(window, "used_percent", 0.0))
    return str(max(0, min(999, int(value))))


def _reset_epoch(window) -> str:
    if window is None:
        return "-"
    value = str(getattr(window, "reset_at", ""))
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        epoch = int(parsed.timestamp())
    except (TypeError, ValueError, OverflowError):
        return "-"
    return str(epoch) if epoch > int(time.time()) else "-"


def _append_history(observed_at: int, percent: str, reset: str) -> None:
    if percent == "-" or reset == "-":
        return
    try:
        existing = HISTORY_FILE.read_text(encoding="utf-8").splitlines()
    except OSError:
        existing = []
    existing.append(f"{observed_at} {percent} {reset}")
    # The renderer only needs recent samples.  Keep the file bounded even if
    # a user starts many short-lived Codex sessions.
    _atomic_write(HISTORY_FILE, "\n".join(existing[-2000:]) + "\n")


def _append_week_history(observed_at: int, percent: str, reset: str) -> list[tuple[int, int, int]]:
    """Record the weekly sample and return the parsed history (oldest first)."""
    try:
        lines = WEEK_HISTORY_FILE.read_text(encoding="utf-8").splitlines()
    except OSError:
        lines = []
    if percent != "-" and reset != "-":
        lines.append(f"{observed_at} {percent} {reset}")
        lines = lines[-WEEK_HISTORY_KEEP:]
        _atomic_write(WEEK_HISTORY_FILE, "\n".join(lines) + "\n")
    history = []
    for line in lines:
        parts = line.split()
        if len(parts) < 3 or not all(part.isdigit() for part in parts[:3]):
            continue
        t, p, r = int(parts[0]), int(parts[1]), int(parts[2])
        if t <= observed_at:
            history.append((t, p, r))
    return history


def _week_rate(history, now: int, percent: str, reset: str) -> tuple[str, str]:
    """Return ("<24h burn in %-points per week>", "<last window's final %>"), "-" when unknown."""
    if percent == "-" or reset == "-" or not history:
        return "-", "-"
    p, r = int(percent), int(reset)
    r24, lf = "-", "-"

    # Last final: the adjacent previous window's latest sample.
    prev_r = max((h[2] for h in history if h[2] < r), default=0)
    if prev_r > 0 and r - prev_r <= WEEK + 86400:
        lf = str(next(h[1] for h in reversed(history) if h[2] == prev_r))
    else:
        prev_r = 0

    # 24h burn: the latest sample at least RATE24_WIN ago, else the oldest one.
    t0 = now - RATE24_WIN
    old = None
    for sample in history:
        if sample[0] <= t0:
            old = sample
    if old is None:
        old = history[0]
    span = now - old[0]
    if span < RATE24_MIN_SPAN:
        return r24, lf
    if old[2] == r:
        delta = p - old[1]
    elif prev_r > 0 and old[2] == prev_r:
        last_prev = max((h[1] for h in history if h[2] == prev_r and h[0] >= old[0]), default=old[1])
        delta = last_prev - old[1] + p
    else:
        return r24, lf
    delta = max(0, delta)
    r24 = str((delta * WEEK + span // 2) // span)
    return r24, lf


def _atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
        os.replace(temporary, path)
    except Exception:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


if __name__ == "__main__":
    raise SystemExit(main())
