#!/usr/bin/env python3
"""Fetch Antigravity CLI (agy) account limits and write a tiny tmux-friendly cache.

Runs `agy -p /usage --output-format json` (which is handled locally by agy's
printmode.usageReport against RetrieveUserQuotaSummary without starting a model
turn or consuming any tokens), parses the 5h and weekly quota buckets across
groups (Claude & GPT `3p`, Gemini 4 Argon `Ar`, Gemini Models `Gm`), computes
weekly burn rate and last-week final percentage, and writes:

  ~/.local/state/tmux-agy-quota/tmux-agy-usage.dat
    15 columns: ts h5p h5r p3p p3r arp arr gmp gmr p3k p3l ark arl gmk gml
  ~/.local/state/tmux-agy-quota/tmux-agy-usage-5h.hist
    3 columns:  ts h5p h5r
  ~/.local/state/tmux-agy-quota/tmux-agy-usage-7d.hist
    7 columns:  ts p3p p3r arp arr gmp gmr

Standard library only; no hardcoded username.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path


STATE_DIR = Path(os.environ.get("TMUX_AGY_STATE_DIR", str(Path.home() / ".local/state/tmux-agy-quota")))
CACHE_FILE = STATE_DIR / "tmux-agy-usage.dat"
HISTORY_FILE = STATE_DIR / "tmux-agy-usage-5h.hist"
WEEK_HISTORY_FILE = STATE_DIR / "tmux-agy-usage-7d.hist"

FETCH_TIMEOUT = 12.0
WEEK = 604800
RATE24_WIN = 21600       # 与 claude/tmux-claude-usage-rate.sh 一致(6h 燃速窗口)
RATE24_MIN_SPAN = 10800  # 至少跨 3h 才算燃速
RESET_TOL = 300          # 重置时刻抖动 ≤ 5 分钟视为同一窗口
HISTORY_KEEP = 30
WEEK_HISTORY_KEEP = 2500


class ProviderError(RuntimeError):
    """Any failure between us and usable limit buckets; message never carries secrets."""


class Bucket:
    """一个额度桶。不用 dataclass，兼容 spec_from_file_location 动态加载。"""

    __slots__ = ("bucket_id", "group_name", "window", "used_percent", "reset_at")

    def __init__(self, bucket_id: str, group_name: str, window: str, used_percent: int, reset_at: str) -> None:
        self.bucket_id = bucket_id
        self.group_name = group_name
        self.window = window
        self.used_percent = used_percent
        self.reset_at = reset_at

    def __repr__(self) -> str:
        return (
            f"Bucket({self.bucket_id!r}, {self.group_name!r}, "
            f"{self.window!r}, {self.used_percent}, {self.reset_at!r})"
        )


def _resolve_agy_bin() -> str:
    env_bin = os.environ.get("AGY_BIN", "").strip()
    if env_bin:
        return env_bin
    found = shutil.which("agy")
    if found:
        return found
    candidate = Path.home() / ".local" / "bin" / "agy"
    if candidate.is_file() and os.access(candidate, os.X_OK):
        return str(candidate)
    raise ProviderError("agy binary not found")


def _fetch_agy_usage(timeout: float = FETCH_TIMEOUT) -> list[Bucket]:
    agy_bin = _resolve_agy_bin()
    env = dict(os.environ)
    # 剥离 TMUX 环境变量，防止无头 `agy -p /usage` 触发任何分屏状态钩子
    env.pop("TMUX", None)
    env.pop("TMUX_PANE", None)
    try:
        result = subprocess.run(
            [agy_bin, "-p", "/usage", "--output-format", "json"],
            cwd="/tmp",
            env=env,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
    except Exception as exc:
        raise ProviderError(f"agy command failed: {exc.__class__.__name__}") from exc
    if result.returncode != 0:
        raise ProviderError(f"agy exited {result.returncode}")
    return _parse_usage_stdout(result.stdout)


def _parse_usage_stdout(stdout: str) -> list[Bucket]:
    text = stdout.strip()
    if not text:
        raise ProviderError("agy returned empty output")
    try:
        payload = json.loads(text)
    except json.JSONDecodeError as exc:
        # 若 stdout 混杂了前缀行，尝试逐行取最后一个 JSON 对象
        payload = None
        for line in reversed(text.splitlines()):
            line = line.strip()
            if line.startswith("{") and line.endswith("}"):
                try:
                    payload = json.loads(line)
                    break
                except json.JSONDecodeError:
                    continue
        if payload is None:
            raise ProviderError("agy returned invalid JSON") from exc
    return _parse_usage_payload(payload)


def _parse_usage_payload(payload: object) -> list[Bucket]:
    if not isinstance(payload, dict):
        raise ProviderError("usage payload is not an object")
    data = payload
    cmd = payload.get("command")
    if isinstance(cmd, dict) and isinstance(cmd.get("data"), dict):
        data = cmd["data"]
    elif isinstance(payload.get("data"), dict):
        data = payload["data"]

    groups = data.get("groups")
    if not isinstance(groups, list) or not groups:
        raise ProviderError("usage payload contains no groups")

    buckets: list[Bucket] = []
    for group in groups:
        if not isinstance(group, dict):
            continue
        group_name = str(group.get("name") or group.get("displayName") or "").strip()
        raw_buckets = group.get("buckets")
        if not isinstance(raw_buckets, list):
            continue
        for item in raw_buckets:
            if not isinstance(item, dict):
                continue
            buckets.append(_parse_bucket(item, group_name))

    if not buckets:
        raise ProviderError("usage payload contains no buckets")
    return buckets


def _parse_bucket(item: dict, group_name: str) -> Bucket:
    bucket_id = str(item.get("id") or item.get("bucketId") or "").strip()
    window = str(item.get("window") or "").strip().lower()
    if "remaining_fraction" in item and item["remaining_fraction"] is not None:
        frac = item["remaining_fraction"]
        if isinstance(frac, bool) or not isinstance(frac, (int, float)):
            raise ProviderError("remaining_fraction is not a number")
        rem_pct = round(float(frac) * 100.0)
    elif "remainingFraction" in item and item["remainingFraction"] is not None:
        frac = item["remainingFraction"]
        if isinstance(frac, bool) or not isinstance(frac, (int, float)):
            raise ProviderError("remainingFraction is not a number")
        rem_pct = round(float(frac) * 100.0)
    elif "used_percent" in item and item["used_percent"] is not None:
        used_val = item["used_percent"]
        if isinstance(used_val, bool) or not isinstance(used_val, (int, float)):
            raise ProviderError("used_percent is not a number")
        rem_pct = 100 - round(float(used_val))
    else:
        raise ProviderError("missing remaining_fraction in bucket")

    used_pct = max(0, min(100, int(100 - rem_pct)))
    reset_raw = item.get("reset_time") or item.get("resetTime") or item.get("reset_at") or item.get("resetsAt")
    if not isinstance(reset_raw, str) or not reset_raw.strip():
        raise ProviderError("reset_time is not a non-empty string")
    return Bucket(
        bucket_id=bucket_id,
        group_name=group_name,
        window=window,
        used_percent=used_pct,
        reset_at=reset_raw.strip(),
    )


def _select_buckets(buckets: list[Bucket], now: int) -> tuple[Bucket | None, Bucket | None, Bucket | None, Bucket | None]:
    """Return (h5, p3_weekly, argon_weekly, gemini_weekly)."""
    h5_candidates: list[Bucket] = []
    p3_week: Bucket | None = None
    ar_week: Bucket | None = None
    gm_week: Bucket | None = None

    for b in buckets:
        bid = b.bucket_id.lower()
        gname = b.group_name.lower()
        win = b.window.lower()
        is_5h = win in {"5h", "session", "five_hour"} or "5h" in bid or "five hour" in bid
        is_week = win in {"weekly", "week", "7d"} or "weekly" in bid or "week" in bid

        if is_5h:
            h5_candidates.append(b)
        elif is_week:
            if bid == "3p-weekly" or "3p" in bid or "claude" in gname or "gpt" in gname:
                p3_week = b
            elif "argon" in bid or "argon" in gname:
                ar_week = b
            elif bid == "gemini-weekly" or "gemini" in bid or "gemini" in gname:
                gm_week = b

    # 5h 取已用百分比最高的那个桶（若相同则取重置更早的），确保任一模型池触发 5h 限流都能立刻告警
    h5: Bucket | None = None
    if h5_candidates:
        h5_candidates.sort(
            key=lambda b: (-b.used_percent, _reset_epoch_int(b, now) or (1 << 62))
        )
        h5 = h5_candidates[0]

    return h5, p3_week, ar_week, gm_week


def _percent(bucket: Bucket | None) -> str:
    if bucket is None:
        return "-"
    return str(max(0, min(999, int(bucket.used_percent))))


def _reset_epoch_int(bucket: Bucket | None, now: int) -> int | None:
    if bucket is None:
        return None
    try:
        parsed = datetime.fromisoformat(bucket.reset_at.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        epoch = int(parsed.timestamp())
    except (TypeError, ValueError, OverflowError):
        return None
    return epoch if epoch > now else None


def _reset_epoch(bucket: Bucket | None, now: int | None = None) -> str:
    cur = int(time.time()) if now is None else now
    epoch = _reset_epoch_int(bucket, cur)
    return str(epoch) if epoch is not None else "-"


def _append_history(observed_at: int, percent: str, reset: str) -> None:
    if percent == "-" or reset == "-":
        return
    try:
        existing = HISTORY_FILE.read_text(encoding="utf-8").splitlines()
    except OSError:
        existing = []
    existing.append(f"{observed_at} {percent} {reset}")
    _atomic_write(HISTORY_FILE, "\n".join(existing[-HISTORY_KEEP:]) + "\n")


def _append_week_history(
    observed_at: int,
    p3_pct: str,
    p3_reset: str,
    ar_pct: str,
    ar_reset: str,
    gm_pct: str,
    gm_reset: str,
) -> list[str]:
    try:
        lines = WEEK_HISTORY_FILE.read_text(encoding="utf-8").splitlines()
    except OSError:
        lines = []
    if any(p != "-" and r != "-" for p, r in ((p3_pct, p3_reset), (ar_pct, ar_reset), (gm_pct, gm_reset))):
        lines.append(f"{observed_at} {p3_pct} {p3_reset} {ar_pct} {ar_reset} {gm_pct} {gm_reset}")
        lines = lines[-WEEK_HISTORY_KEEP:]
        _atomic_write(WEEK_HISTORY_FILE, "\n".join(lines) + "\n")
    return lines


def _extract_series(lines: list[str], col_idx: int, observed_at: int) -> list[tuple[int, int, int]]:
    """Extract (timestamp, pct, reset) for column pair (col_idx, col_idx+1) from 7-column history lines."""
    history: list[tuple[int, int, int]] = []
    for line in lines:
        parts = line.split()
        if len(parts) <= col_idx + 1:
            continue
        t_str, p_str, r_str = parts[0], parts[col_idx], parts[col_idx + 1]
        if not (t_str.isdigit() and p_str.isdigit() and r_str.isdigit()):
            continue
        t, p, r = int(t_str), int(p_str), int(r_str)
        if t <= observed_at:
            history.append((t, p, r))
    return history


def _week_rate(history: list[tuple[int, int, int]], now: int, percent: str, reset: str) -> tuple[str, str]:
    """Return ("<burn in %-points per week>", "<last window's final %>"), "-" when unknown."""
    if percent == "-" or reset == "-" or not history:
        return "-", "-"
    p, r = int(percent), int(reset)
    r24, lf = "-", "-"

    def near(a: int, b: int) -> bool:
        return abs(a - b) <= RESET_TOL

    prev_r = max((h[2] for h in history if h[2] < r - RESET_TOL), default=0)
    if prev_r > 0 and r - prev_r <= WEEK + 86400:
        lf = str(next(h[1] for h in reversed(history) if near(h[2], prev_r)))
    else:
        prev_r = 0

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
    if near(old[2], r):
        delta = p - old[1]
    elif prev_r > 0 and near(old[2], prev_r):
        last_prev = max((h[1] for h in history if near(h[2], prev_r) and h[0] >= old[0]), default=old[1])
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


def main() -> int:
    try:
        buckets = _fetch_agy_usage(FETCH_TIMEOUT)
    except Exception as exc:
        print(f"AGY quota refresh failed: {exc.__class__.__name__}", file=sys.stderr)
        return 1

    observed_at = int(time.time())
    h5, p3, ar, gm = _select_buckets(buckets, observed_at)

    h5_pct, h5_reset = _percent(h5), _reset_epoch(h5, observed_at)
    p3_pct, p3_reset = _percent(p3), _reset_epoch(p3, observed_at)
    ar_pct, ar_reset = _percent(ar), _reset_epoch(ar, observed_at)
    gm_pct, gm_reset = _percent(gm), _reset_epoch(gm, observed_at)

    lines = _append_week_history(observed_at, p3_pct, p3_reset, ar_pct, ar_reset, gm_pct, gm_reset)
    p3_r24, p3_lf = _week_rate(_extract_series(lines, 1, observed_at), observed_at, p3_pct, p3_reset)
    ar_r24, ar_lf = _week_rate(_extract_series(lines, 3, observed_at), observed_at, ar_pct, ar_reset)
    gm_r24, gm_lf = _week_rate(_extract_series(lines, 5, observed_at), observed_at, gm_pct, gm_reset)

    values = [
        str(observed_at),
        h5_pct,
        h5_reset,
        p3_pct,
        p3_reset,
        ar_pct,
        ar_reset,
        gm_pct,
        gm_reset,
        p3_r24,
        p3_lf,
        ar_r24,
        ar_lf,
        gm_r24,
        gm_lf,
    ]
    _atomic_write(CACHE_FILE, " ".join(values) + "\n")

    if h5 is not None:
        _append_history(observed_at, h5_pct, h5_reset)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
