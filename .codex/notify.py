#!/usr/bin/env python3
# ~/.codex/notify.py
# Send Telegram and Google Chat notifications when the Codex CLI finishes a turn.
# (meaning it's waiting for you to enter more information). Register via config.toml: notify = ["python3", "/path/to/notify.py"]

import json
import os
import sys
import urllib.request

TELEGRAM_BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "PLACEHOLDER_DEFAULT_VALUE")
TELEGRAM_CHAT_ID = os.environ.get("TELEGRAM_CHAT_ID", "PLACEHOLDER_DEFAULT_VALUE")
GCHAT_WEBHOOK_URL = os.environ.get("GCHAT_WEBHOOK_URL", "PLACEHOLDER_DEFAULT_VALUE")


def send_telegram(text: str) -> None:
    url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"
    data = json.dumps({
        "chat_id": TELEGRAM_CHAT_ID,
        "text": text,
        "parse_mode": "Markdown",
    }).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=10)
    except Exception as e:
        print(f"Telegram error: {e}", file=sys.stderr)


def send_gchat(text: str) -> None:
    data = json.dumps({"text": text}).encode("utf-8")
    req = urllib.request.Request(
        GCHAT_WEBHOOK_URL, data=data, headers={"Content-Type": "application/json; charset=UTF-8"}
    )
    try:
        urllib.request.urlopen(req, timeout=10)
    except Exception as e:
        print(f"Google Chat error: {e}", file=sys.stderr)


def main() -> int:
    if len(sys.argv) < 2:
        return 0

    notification = json.loads(sys.argv[1])

    if notification.get("type") != "agent-turn-complete":
        return 0

    last_message = notification.get("last-assistant-message", "Turn complete!")
    cwd = notification.get("cwd", "")
    thread_id = notification.get("thread-id", "")

    text = (
        f"🤖 *Codex CLI* waiting for you to enter more.\n"
        f"{last_message}\n"
        f"📁 `{cwd}`\n"
        f"🧵 `{thread_id}`"
    )

    send_telegram(text)
    send_gchat(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
