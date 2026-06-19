"""Bittensor subnet owner burn rate monitoring via taostats (see subnet_rada.py)."""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from typing import Any

OWNER_BURN_DECIMALS = 4


def api_base() -> str:
    return os.environ.get("TAOSTATS_API_BASE", "https://api.taostats.io").rstrip("/")


def request_headers(auth: str) -> dict[str, str]:
    ua = os.environ.get(
        "TAOSTATS_USER_AGENT",
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    )
    return {
        "Authorization": auth,
        "User-Agent": ua,
        "Accept": "application/json, text/plain, */*",
        "Accept-Language": "en-US,en;q=0.9",
    }


def taostats_auth() -> str | None:
    key = os.environ.get("TAOSTATS_API_KEY", "").strip()
    return key or None


def http_get_json(
    path: str,
    params: dict[str, Any],
    auth: str,
    *,
    timeout: float = 60.0,
) -> dict[str, Any]:
    q = "&".join(
        f"{k}={v}" for k, v in params.items() if v is not None and v != ""
    )
    url = f"{api_base()}{path}" + (f"?{q}" if q else "")
    req = urllib.request.Request(url, headers=request_headers(auth))
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode()
    except urllib.error.HTTPError as e:
        body = e.read().decode() if e.fp else ""
        try:
            err = json.loads(body)
        except json.JSONDecodeError:
            err = {"status_code": e.code, "message": body or e.reason}
        err["http_status"] = e.code
        return err
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        reason = getattr(e, "reason", e)
        return {"error": "network", "message": str(reason)}
    try:
        return json.loads(body)
    except json.JSONDecodeError as e:
        return {"parse_error": str(e), "raw": body[:500]}


def is_rate_limited(payload: dict[str, Any]) -> bool:
    return payload.get("status_code") == 429 or "Rate Limited" in str(
        payload.get("message", "")
    )


def with_retries(
    path: str,
    params: dict[str, Any],
    auth: str,
    *,
    max_retries: int = 6,
    timeout: float = 60.0,
) -> dict[str, Any]:
    delay = 2.0
    for attempt in range(max_retries):
        payload = http_get_json(path, params, auth, timeout=timeout)
        if payload.get("error") == "network":
            if attempt == max_retries - 1:
                return payload
            time.sleep(delay)
            delay = min(delay * 1.8, 120.0)
            continue
        if not is_rate_limited(payload):
            return payload
        if attempt == max_retries - 1:
            return payload
        time.sleep(delay)
        delay = min(delay * 1.8, 120.0)
    return payload


def fetch_all_subnets_latest(
    auth: str,
    *,
    timeout: float = 60.0,
    max_retries: int = 6,
) -> list[dict[str, Any]] | dict[str, Any]:
    p = with_retries(
        "/api/subnet/latest/v1",
        {"limit": 1024, "order": "netuid_asc"},
        auth,
        max_retries=max_retries,
        timeout=timeout,
    )
    if p.get("error"):
        return {"error": p.get("error"), "response": p}
    rows = p.get("data") or []
    if not rows:
        return {"error": "no_subnet_rows", "response": p}
    return rows


def owner_burn_from_row(row: dict[str, Any]) -> str:
    return str(row.get("incentive_burn") or "0")


def format_owner_burn(value: str) -> str:
    try:
        return f"{float(value):.{OWNER_BURN_DECIMALS}f}"
    except (TypeError, ValueError):
        return value


def owner_burn_changed(old: str, new: str, threshold: float) -> bool:
    try:
        return abs(float(old) - float(new)) > threshold
    except (TypeError, ValueError):
        return old != new


def load_burn_state(path: str) -> dict[str, str]:
    if not os.path.isfile(path):
        return {}
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (json.JSONDecodeError, OSError):
        return {}
    burns = data.get("owner_burn_rate")
    if isinstance(burns, dict):
        return {str(k): str(v) for k, v in burns.items()}
    return {}


def save_burn_state(path: str, burns: dict[str, str], updated_at: str) -> None:
    with open(path, "w", encoding="utf-8") as f:
        json.dump(
            {"updated_at_utc": updated_at, "owner_burn_rate": burns},
            f,
            indent=2,
            sort_keys=True,
        )
        f.write("\n")


def diff_burns(
    prev: dict[str, str],
    current: dict[str, str],
    threshold: float,
) -> list[tuple[str, str, str]]:
    changes: list[tuple[str, str, str]] = []
    for netuid, new_burn in sorted(current.items(), key=lambda x: int(x[0])):
        old_burn = prev.get(netuid)
        if old_burn is None or not owner_burn_changed(old_burn, new_burn, threshold):
            continue
        changes.append((netuid, old_burn, new_burn))
    return changes


def format_burn_alert(changes: list[tuple[str, str, str]], updated_at: str) -> str:
    lines = ["Owner burn rate changed", f"{updated_at} UTC", ""]
    for netuid, old_burn, new_burn in changes:
        lines.append(
            f"SN{netuid}: {format_owner_burn(old_burn)} → {format_owner_burn(new_burn)}"
        )
    return "\n".join(lines)


def format_burn_snapshot(rows: list[dict[str, Any]], updated_at: str) -> str:
    lines = [
        "Subnet owner burn rates (startup)",
        f"{updated_at} UTC",
        f"{len(rows)} subnets",
        "",
    ]
    for row in sorted(rows, key=lambda r: int(r.get("netuid", 0))):
        netuid = row.get("netuid")
        burn = format_owner_burn(owner_burn_from_row(row))
        lines.append(f"SN{netuid}: {burn}")
    return "\n".join(lines)


def _chunk_text(text: str, max_len: int = 3900) -> list[str]:
    if len(text) <= max_len:
        return [text]
    lines = text.split("\n")
    header = lines[:3]
    body = lines[4:] if len(lines) > 4 else []
    chunks: list[str] = []
    current = list(header) + ([""] if body else [])
    for line in body:
        candidate = "\n".join(current + [line])
        if len(candidate) > max_len and len(current) > len(header) + 1:
            chunks.append("\n".join(current))
            current = list(header) + ["", line]
        else:
            current.append(line)
    if current:
        chunks.append("\n".join(current))
    return chunks or [text[:max_len]]


def send_burn_telegram_messages(
    text: str, token: str, chat_id: str
) -> tuple[bool, str]:
    parts = _chunk_text(text)
    total = len(parts)
    for index, part in enumerate(parts, start=1):
        body = f"({index}/{total})\n{part}" if total > 1 else part
        ok, err = send_burn_telegram(body, token, chat_id)
        if not ok:
            return False, err
        if index < total:
            time.sleep(0.4)
    return True, ""


def send_burn_telegram(text: str, token: str, chat_id: str) -> tuple[bool, str]:
    if not token or not chat_id:
        return False, "burn telegram not configured"
    url = f"https://api.telegram.org/bot{token}/sendMessage"
    body = urllib.parse.urlencode(
        {
            "chat_id": chat_id,
            "text": text,
            "disable_web_page_preview": "true",
        }
    ).encode()
    req = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            payload = json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        err_body = e.read().decode() if e.fp else ""
        try:
            data = json.loads(err_body)
            return False, data.get("description") or err_body[:300]
        except json.JSONDecodeError:
            return False, err_body or str(e)
    except OSError as e:
        return False, str(e)
    if not payload.get("ok"):
        return False, str(payload)
    return True, ""


def run_burn_watch_once(
    *,
    state_path: str,
    threshold: float,
    burn_token: str,
    burn_chat_id: str,
) -> int:
    auth = taostats_auth()
    if not auth:
        sys.stderr.write(
            "[burn] taostats API not configured (set TAOSTATS_API_KEY in your .env)\n"
        )
        return 1

    updated_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    result = fetch_all_subnets_latest(auth)
    if isinstance(result, dict) and result.get("error"):
        sys.stderr.write(f"[burn] fetch failed: {json.dumps(result)}\n")
        return 1

    rows: list[dict[str, Any]] = result
    current = {str(r["netuid"]): owner_burn_from_row(r) for r in rows if "netuid" in r}
    prev = load_burn_state(state_path)
    changes = diff_burns(prev, current, threshold) if prev else []
    save_burn_state(state_path, current, updated_at)

    if not changes:
        return 0

    diff_msg = format_burn_alert(changes, updated_at)
    ok, err = send_burn_telegram_messages(diff_msg, burn_token, burn_chat_id)
    if ok:
        sys.stderr.write(f"[burn] alert sent ({len(changes)} subnet(s))\n")
    else:
        sys.stderr.write(f"[burn] telegram failed: {err}\n")
    return 0 if ok else 1


def run_burn_startup_snapshot(
    *,
    state_path: str,
    burn_token: str,
    burn_chat_id: str,
    http_timeout: float = 60.0,
    max_retries: int = 6,
) -> int:
    """Fetch all subnets and send full burn-rate snapshot to burn Telegram."""
    auth = taostats_auth()
    if not auth:
        sys.stderr.write(
            "[burn] taostats API not configured (set TAOSTATS_API_KEY in your .env)\n"
        )
        return 1

    updated_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    result = fetch_all_subnets_latest(
        auth,
        timeout=http_timeout,
        max_retries=max_retries,
    )
    if isinstance(result, dict) and result.get("error"):
        sys.stderr.write(f"[burn] startup fetch failed: {json.dumps(result)}\n")
        return 1

    rows: list[dict[str, Any]] = result
    current = {str(r["netuid"]): owner_burn_from_row(r) for r in rows if "netuid" in r}
    save_burn_state(state_path, current, updated_at)
    snapshot = format_burn_snapshot(rows, updated_at)
    ok, err = send_burn_telegram_messages(snapshot, burn_token, burn_chat_id)
    if ok:
        sys.stderr.write(f"[burn] startup snapshot sent ({len(rows)} subnets)\n")
    else:
        sys.stderr.write(f"[burn] startup telegram failed: {err}\n")
    return 0 if ok else 1


def _burn_is_paused(pause_path: str) -> bool:
    return bool(pause_path) and os.path.isfile(pause_path)


def _sleep_until_interval(interval_seconds: float, pause_path: str) -> bool:
    """Sleep in 1s steps. Returns False if paused before interval elapsed."""
    remaining = max(0.0, interval_seconds)
    while remaining > 0:
        if _burn_is_paused(pause_path):
            return False
        step = min(1.0, remaining)
        time.sleep(step)
        remaining -= step
    return not _burn_is_paused(pause_path)


def run_burn_poll_loop(
    *,
    state_path: str,
    threshold: float,
    interval_minutes: float,
    burn_token: str,
    burn_chat_id: str,
    pause_path: str = "",
) -> None:
    interval = max(1.0, interval_minutes) * 60.0
    while True:
        if _burn_is_paused(pause_path):
            sys.stderr.write("[burn] monitoring paused\n")
            return
        try:
            run_burn_watch_once(
                state_path=state_path,
                threshold=threshold,
                burn_token=burn_token,
                burn_chat_id=burn_chat_id,
            )
        except Exception as exc:
            sys.stderr.write(f"[burn] error: {exc}\n")
        if not _sleep_until_interval(interval, pause_path):
            sys.stderr.write("[burn] monitoring paused\n")
            return
