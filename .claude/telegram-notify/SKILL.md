---
name: telegram-notify
description: >
  Send notifications and messages to Telegram chats using the Telegram Bot API.
  Use this skill whenever the user wants to send a Telegram message, notification,
  alert, or update via a bot token. Triggers include: send a Telegram message,
  notify via Telegram, Telegram bot, send notification to Telegram, alert me on
  Telegram, or any workflow where the final step is delivering a message to Telegram.
  Also use when the user wants to send files, photos, or formatted messages through
  Telegram. Always use this skill if a BOT_API_TOKEN or chat_id is mentioned
  alongside any messaging intent.
---

# Telegram Notify Skill

Send messages and notifications to Telegram chats using the Telegram Bot API.

---

## Prerequisites

The user must have:
1. A **Telegram Bot Token** — obtained from [@BotFather](https://t.me/BotFather) on Telegram
2. A **Chat ID** — the destination chat, group, or channel ID

### How to get a Chat ID (if user doesn't know it)
- For personal chats: have the user message their bot, then call `getUpdates` (see below)
- For groups/channels: add the bot to the group, send a message, then call `getUpdates`

---

## Implementation

### Language selection

Use **Python** (preferred, uses `requests`) or **bash** (uses `curl`). Match whatever the user's existing codebase uses. Default to Python.

---

### Python Implementation

```python
import requests

def send_telegram_message(
    token: str,
    chat_id: str | int,
    text: str,
    parse_mode: str = "Markdown",   # "Markdown", "HTML", or None
    disable_notification: bool = False,
) -> dict:
    """
    Send a text message via Telegram Bot API.

    Args:
        token: Bot API token from @BotFather (e.g. "123456:ABC-DEF...")
        chat_id: Target chat, group, or channel ID
        text: Message text (supports Markdown or HTML depending on parse_mode)
        parse_mode: Formatting mode — "Markdown", "HTML", or None for plain text
        disable_notification: Send silently (no sound/vibration)

    Returns:
        Telegram API JSON response dict
    """
    url = f"https://api.telegram.org/bot{token}/sendMessage"
    payload = {
        "chat_id": chat_id,
        "text": text,
        "parse_mode": parse_mode,
        "disable_notification": disable_notification,
    }
    response = requests.post(url, json=payload, timeout=10)
    response.raise_for_status()
    return response.json()


# --- Usage example ---
if __name__ == "__main__":
    BOT_TOKEN = "YOUR_BOT_TOKEN_HERE"   # ← replace
    CHAT_ID   = "YOUR_CHAT_ID_HERE"     # ← replace (string or integer)

    result = send_telegram_message(
        token=BOT_TOKEN,
        chat_id=CHAT_ID,
        text="*Hello!* This is a notification from your bot 🎉",
    )
    print("Sent:", result)
```

#### Send a photo

```python
def send_telegram_photo(token, chat_id, photo_path_or_url, caption=""):
    url = f"https://api.telegram.org/bot{token}/sendPhoto"
    if photo_path_or_url.startswith("http"):
        payload = {"chat_id": chat_id, "photo": photo_path_or_url, "caption": caption}
        response = requests.post(url, json=payload, timeout=10)
    else:
        with open(photo_path_or_url, "rb") as f:
            response = requests.post(url, data={"chat_id": chat_id, "caption": caption}, files={"photo": f}, timeout=30)
    response.raise_for_status()
    return response.json()
```

#### Send a document/file

```python
def send_telegram_document(token, chat_id, file_path, caption=""):
    url = f"https://api.telegram.org/bot{token}/sendDocument"
    with open(file_path, "rb") as f:
        response = requests.post(url, data={"chat_id": chat_id, "caption": caption}, files={"document": f}, timeout=60)
    response.raise_for_status()
    return response.json()
```

---

### Bash / curl Implementation

```bash
#!/usr/bin/env bash
# send_telegram.sh — send a Telegram message via curl

BOT_TOKEN="YOUR_BOT_TOKEN_HERE"   # ← replace
CHAT_ID="YOUR_CHAT_ID_HERE"       # ← replace
MESSAGE="Hello from bash\! 🚀"    # MarkdownV2: escape special chars with \

curl -s -X POST \
  "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
  -H "Content-Type: application/json" \
  -d "{
    \"chat_id\": \"${CHAT_ID}\",
    \"text\": \"${MESSAGE}\",
    \"parse_mode\": \"MarkdownV2\"
  }"
```

---

### Get Chat ID (helper)

Call this after the user sends a message to their bot:

```bash
curl "https://api.telegram.org/bot<BOT_TOKEN>/getUpdates"
```

Look for `result[].message.chat.id` in the JSON response.

Or in Python:

```python
def get_updates(token):
    url = f"https://api.telegram.org/bot{token}/getUpdates"
    return requests.get(url, timeout=10).json()
```

---

## Formatting Guide

| Mode | Bold | Italic | Code | Link |
|------|------|--------|------|------|
| `Markdown` | `*bold*` | `_italic_` | `` `code` `` | `[text](url)` |
| `HTML` | `<b>bold</b>` | `<i>italic</i>` | `<code>code</code>` | `<a href="url">text</a>` |
| `MarkdownV2` | `*bold*` | `_italic_` | `` `code` `` | `[text](url)` — special chars must be escaped with `\` |

**Recommendation**: Use `Markdown` for simplicity, `HTML` for complex formatting, `MarkdownV2` for Telegram's latest features.

---

## Common API Endpoints

| Action | Endpoint |
|--------|----------|
| Send text | `POST /sendMessage` |
| Send photo | `POST /sendPhoto` |
| Send document | `POST /sendDocument` |
| Send audio | `POST /sendAudio` |
| Send video | `POST /sendVideo` |
| Get bot info | `GET /getMe` |
| Get updates | `GET /getUpdates` |

All endpoints: `https://api.telegram.org/bot<TOKEN>/<endpoint>`

---

## Error Handling

Always check for API errors:

```python
result = response.json()
if not result.get("ok"):
    raise RuntimeError(f"Telegram API error: {result.get('description')}")
```

Common errors:
- `401 Unauthorized` — invalid bot token
- `400 Bad Request: chat not found` — wrong chat ID or bot not added to group
- `403 Forbidden` — bot was blocked by the user
- `429 Too Many Requests` — rate limited; respect `retry_after` field in response

---

## Security Notes

- **Never hardcode tokens** in source files that get committed. Use environment variables:
  ```python
  import os
  BOT_TOKEN = os.environ["TELEGRAM_BOT_TOKEN"]
  ```
- Store tokens in `.env` files (add to `.gitignore`) or a secrets manager.
- Bot tokens grant full control of the bot — treat them like passwords.

---

## Integration Pattern (notifications in a script)

```python
import os, requests

TELEGRAM_TOKEN = os.environ["TELEGRAM_BOT_TOKEN"]
TELEGRAM_CHAT  = os.environ["TELEGRAM_CHAT_ID"]

def notify(message: str):
    """Drop-in notification helper — call anywhere in your code."""
    try:
        url = f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/sendMessage"
        requests.post(url, json={"chat_id": TELEGRAM_CHAT, "text": message}, timeout=5)
    except Exception as e:
        print(f"[notify] Telegram error: {e}")  # fail silently

# Use it anywhere:
notify("✅ Job finished successfully")
notify("❌ Error: database connection failed")
```
