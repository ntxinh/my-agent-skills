#!/bin/bash
# ~/.claude/hooks/notify-telegram.sh
# Sends Telegram notifications when Claude Code needs input from you. (Notification event)

BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-PLACEHOLDER_DEFAULT_VALUE}"
CHAT_ID="${TELEGRAM_CHAT_ID:-PLACEHOLDER_DEFAULT_VALUE}"

INPUT=$(cat)
MESSAGE=$(echo "$INPUT" | jq -r '.message // "Claude Code needs your confirmation/input."')
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')

TEXT="🤖 *Claude Code* needs your input
${MESSAGE}
📁 \`${CWD}\`"

curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
  -d chat_id="${CHAT_ID}" \
  -d parse_mode="Markdown" \
  --data-urlencode text="${TEXT}" > /dev/null

exit 0
