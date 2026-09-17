#!/usr/bin/env python3
"""Fetch Codex account limits and write a tiny tmux-friendly cache.

This helper deliberately does not start a Codex model run.  It first asks the
WHAM usage endpoint with the local OAuth token and only falls back to the
app-server proxy when that is unavailable.  The hook wrapper is responsible
for locking and detaching this process from Codex.

2026-09-17: 拉取与解析逻辑内联在本文件(原来 import 本机 ~/ai-usage-widget 的
ai_usage_widget.codex_limits_provider),仓库自足,不再依赖仓库外目录;路径也不再写死用户名。
只用标准库。
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path


CODEX_DIR = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))
STATE_DIR = Path(os.environ.get("TMUX_CODEX_STATE_DIR", str(Path.home() / ".local/state/tmux-codex-quota")))
AUTH_FILE = CODEX_DIR / "auth.json"
RPC_SOCKET = CODEX_DIR / "app-server-control" / "app-server-control.sock"
CACHE_FILE = STATE_DIR / "tmux-codex-usage.dat"
HISTORY_FILE = STATE_DIR / "tmux-codex-usage-5h.hist"
WEEK_HISTORY_FILE = STATE_DIR / "tmux-codex-usage-7d.hist"

WHAM_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
RPC_REQUEST_ID = "tmux-codex-quota-rate-limits"
FETCH_TIMEOUT = 8.0

# 周燃速参数,与 ~/.claude/tmux-claude-usage-rate.sh 同算法(2026-09-17):
# 缓存末尾多两列「24h 燃速(%/周) 上周终值%」,渲染器据此在周初与冲刺当天也能给出预测。
WEEK = 604800
RATE24_WIN = 86400
RATE24_MIN_SPAN = 21600
WEEK_HISTORY_KEEP = 2500


class ProviderError(RuntimeError):
    """Any failure between us and a usable limit window; the message never carries secrets."""


class Window:
    """一个额度窗口。不用 dataclass:测试用 spec_from_file_location 加载本文件时 dataclass 会因模块未注册而崩。"""

    __slots__ = ("window", "used_percent", "reset_at", "window_duration_minutes")

    def __init__(self, window: str, used_percent: float, reset_at: str, window_duration_minutes: int) -> None:
        self.window = window                    # "session" / "week"(接口字段名映射,_pick_window 只当兜底用)
        self.used_percent = used_percent
        self.reset_at = reset_at                # ISO 8601
        self.window_duration_minutes = window_duration_minutes  # 0 = 接口没给

    def __repr__(self) -> str:
        return f"Window({self.window!r}, {self.used_percent}, {self.reset_at!r}, {self.window_duration_minutes})"


# ---- 拉取 ---------------------------------------------------------------

def _load_access_token(auth_file: Path) -> str:
    try:
        payload = json.loads(auth_file.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ProviderError("auth file unreadable") from exc
    for path in (("tokens", "access_token"), ("oauth", "access_token"), ("access_token",), ("token", "access_token")):
        current = payload
        for key in path:
            current = current.get(key) if isinstance(current, dict) else None
        if isinstance(current, str) and current.strip():
            return current.strip()
    raise ProviderError("no access token in auth file")


def _fetch_wham(auth_file: Path, timeout: float) -> list[Window]:
    token = _load_access_token(auth_file)
    request = urllib.request.Request(
        WHAM_USAGE_URL,
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
        method="GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            status, payload = int(response.status), json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        status, payload = int(exc.code), {}
    except Exception as exc:
        raise ProviderError(f"WHAM request failed: {exc.__class__.__name__}") from exc
    if status != 200:
        raise ProviderError(f"WHAM HTTP {status}")
    if not isinstance(payload, dict):
        raise ProviderError("WHAM payload is not an object")
    inner = payload.get("rate_limit")
    return _parse_windows(inner if isinstance(inner, dict) else payload,
                          (("primary_window", "session"), ("secondary_window", "week")))


def _fetch_rpc(socket_path: Path, timeout: float) -> list[Window]:
    command = ["codex", "app-server", "proxy", "--sock", str(socket_path)]
    request = {"id": RPC_REQUEST_ID, "method": "account/rateLimits/read", "params": None}
    try:
        result = subprocess.run(command, input=json.dumps(request) + "\n", text=True,
                                capture_output=True, timeout=timeout, check=False)
    except Exception as exc:
        raise ProviderError(f"app-server proxy failed: {exc.__class__.__name__}") from exc
    if result.returncode != 0:
        raise ProviderError("app-server proxy exited non-zero")
    payload = _parse_rpc_stdout(result.stdout)
    if "error" in payload:
        raise ProviderError("app-server RPC returned an error")
    result_obj = payload.get("result")
    if result_obj is not None:
        payload = result_obj
    if not isinstance(payload, dict):
        raise ProviderError("RPC result is not an object")
    limits = payload.get("rate_limits", payload.get("rateLimits"))
    if not isinstance(limits, dict):
        raise ProviderError("RPC result has no rate_limits")
    return _parse_windows(limits, (("primary", "session"), ("secondary", "week")))


def _parse_rpc_stdout(stdout: str) -> dict:
    text = stdout.strip()
    if not text:
        raise ProviderError("app-server RPC returned empty output")
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        for line in text.splitlines():
            try:
                payload = json.loads(line.strip())
            except json.JSONDecodeError:
                continue
            if isinstance(payload, dict) and payload.get("id") == RPC_REQUEST_ID:
                return payload
        raise ProviderError("app-server RPC returned invalid JSON")
    if not isinstance(payload, dict):
        raise ProviderError("app-server RPC response is not an object")
    return payload


# ---- 解析 ---------------------------------------------------------------

def _parse_windows(payload: dict, fields: tuple[tuple[str, str], ...]) -> list[Window]:
    windows: list[Window] = []
    for field, name in fields:
        value = payload.get(field)
        if value is None:
            continue
        if not isinstance(value, dict):
            raise ProviderError(f"{field} is not an object")
        windows.append(_parse_window(value, name))
    if not windows:
        raise ProviderError("response contains no limit windows")
    return windows


def _parse_window(payload: dict, name: str) -> Window:
    used = _first(payload, "used_percent", "usedPercent")
    if isinstance(used, bool) or not isinstance(used, (int, float)):
        raise ProviderError("used_percent is not a number")
    reset = _first(payload, "reset_at", "resets_at", "resetsAt")
    if isinstance(reset, bool):
        raise ProviderError("reset_at is not a datetime")
    if isinstance(reset, (int, float)):
        reset = datetime.fromtimestamp(float(reset), timezone.utc).isoformat()
    elif not isinstance(reset, str) or not reset.strip():
        raise ProviderError("reset_at is not a datetime")
    # 窗口时长缺失不算错(_pick_window 会退回按字段名判断),只有给了却不是数才算错。
    if "limit_window_seconds" in payload:
        seconds = payload["limit_window_seconds"]
        duration = int(seconds) // 60 if isinstance(seconds, (int, float)) and not isinstance(seconds, bool) else 0
    else:
        minutes = _first(payload, "window_duration_minutes", "windowDurationMins", default=0)
        duration = int(minutes) if isinstance(minutes, (int, float)) and not isinstance(minutes, bool) else 0
    return Window(window=name, used_percent=float(used), reset_at=reset.strip(), window_duration_minutes=duration)


_MISSING = object()


def _first(payload: dict, *names: str, default=_MISSING):
    for key in names:
        if key in payload:
            return payload[key]
    if default is _MISSING:
        raise ProviderError("missing field: " + "/".join(names))
    return default


# ---- 主流程 -------------------------------------------------------------

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
        return _fetch_wham(AUTH_FILE, FETCH_TIMEOUT), errors
    except Exception as exc:  # provider failures must not break Codex hooks
        errors.append(f"wham:{exc.__class__.__name__}")

    if RPC_SOCKET.exists():
        try:
            return _fetch_rpc(RPC_SOCKET, FETCH_TIMEOUT), errors
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
