#!/usr/bin/env python3
"""Diagnose burn Telegram bot token + chat id from the user .env file."""
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENV = os.path.join(ROOT, ".env")


def load_env(path):
    out = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, _, v = line.partition("=")
            out[k.strip()] = v.strip().strip('"').strip("'")
    return out


def main():
    cfg = load_env(ENV)
    token = cfg.get("BURN_TELEGRAM_BOT_TOKEN", "")
    chat = cfg.get("BURN_TELEGRAM_CHAT_ID", "")
    if not token or not chat:
        print("FAIL: missing BURN_TELEGRAM_BOT_TOKEN or BURN_TELEGRAM_CHAT_ID in", ENV)
        sys.exit(1)
    print("token: set (%d chars)" % len(token))
    print("chat_id:", chat)

    me_url = f"https://api.telegram.org/bot{token}/getMe"
    try:
        with urllib.request.urlopen(me_url, timeout=15) as r:
            me = json.loads(r.read().decode())
        print("getMe:", me.get("ok"), me.get("result", {}).get("username"))
    except urllib.error.HTTPError as e:
        print("getMe FAIL:", e.code, e.read().decode()[:300])
        sys.exit(1)

    msg = "bittensor-burn-message diagnostic test"
    send_url = f"https://api.telegram.org/bot{token}/sendMessage"
    data = urllib.parse.urlencode({"chat_id": chat, "text": msg}).encode()
    try:
        with urllib.request.urlopen(send_url, data=data, timeout=15) as r:
            body = json.loads(r.read().decode())
        print("sendMessage:", body.get("ok"))
        if not body.get("ok"):
            print("FAIL:", body)
            sys.exit(1)
        print("OK: check Telegram for test message")
    except urllib.error.HTTPError as e:
        print("sendMessage FAIL:", e.code, e.read().decode()[:500])
        sys.exit(1)


if __name__ == "__main__":
    main()
