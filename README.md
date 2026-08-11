# Claude Code Status Line — Context & Quota Tracker

A drop-in status line for [Claude Code](https://code.claude.com) that shows, always visible at the bottom of your terminal:

- **Model** in use
- **Current folder** and **git branch** (with staged `+`/modified `~` counts)
- **Context window usage** as a color-coded progress bar
- **Rate-limit quota** used (5-hour / 7-day windows)
- **Session duration**

Example output:

```
[Sonnet] 📁 orodruin-3 | 🌿 feature/onsite-nps +2 ~5
██████░░░░ 62% ctx | 5h: 24% 7d: 41% quota | ⏱️ 12m 8s
```

Colors shift as usage climbs: **green** under 70%, **yellow** 70–89%, **red** 90%+ — for both the context bar and the quota text.

## Requirements

- Claude Code (any recent version with `statusLine` support)
- [`jq`](https://jqlang.org/) installed
  - macOS: `brew install jq`
  - Linux (Debian/Ubuntu): `sudo apt install jq`
- On Windows, this script runs via Git Bash. If you don't have Git Bash, see the [PowerShell alternative](https://code.claude.com/docs/en/statusline#windows-configuration) in Anthropic's docs.

## Automatic install (recommended)

From the project directory, make the installer executable and run it:

```bash
chmod +x install-statusline.sh
./install-statusline.sh
```

The installer will:

- Check whether `jq` is available and, if necessary, try to install it with Homebrew, `apt`, `dnf`, or `pacman`.
- Create `~/.claude/statusline.sh` and make it executable.
- Add or update the `statusLine` entry in `~/.claude/settings.json` without removing your other settings.
- Back up an existing status-line script or settings file using a timestamped `.bak` file before replacing it.

The script may ask for your password through `sudo` when installing `jq` on Linux. If it cannot detect a supported package manager, install [`jq`](https://jqlang.org/download/) manually and run the installer again.

Once it finishes, open or restart Claude Code. If the status line does not appear, make sure you have accepted the workspace trust prompt for the folder.

> **Windows:** run the installer from Git Bash. Without Git Bash, use the [PowerShell alternative](https://code.claude.com/docs/en/statusline#windows-configuration) from Anthropic's documentation.

## Manual install

1. Save the script below as `~/.claude/statusline.sh` (`~` is your home directory).
2. Make it executable:
   ```bash
   chmod +x ~/.claude/statusline.sh
   ```
3. Add this to `~/.claude/settings.json` (create the file if it doesn't exist):
   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "~/.claude/statusline.sh"
     }
   }
   ```
4. Restart Claude Code, or just send your next message — the status line appears automatically.

That's it. No restart of your shell needed, and it doesn't consume any API tokens.

## The script

```bash
#!/bin/bash
# Claude Code custom status line
# Shows: model | dir | git branch+status | context usage bar | rate-limit quota | duration
#
# Note: rate_limits (5h/7d quota) is only sent for Claude.ai Pro/Max
# subscribers, and only after the first API response in the session.
# On API/console billing this field is absent, so the script falls
# back to "n/a" for that segment.
#
# Install:
#   1. Save this file to ~/.claude/statusline.sh
#   2. chmod +x ~/.claude/statusline.sh
#   3. Add to ~/.claude/settings.json:
#      {
#        "statusLine": {
#          "type": "command",
#          "command": "~/.claude/statusline.sh"
#        }
#      }

input=$(cat)

MODEL=$(echo "$input" | jq -r '.model.display_name')
DIR=$(echo "$input" | jq -r '.workspace.current_dir')
DURATION_MS=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')
PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
FIVE_H=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
WEEK=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')

CYAN='\033[36m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
RESET='\033[0m'

# Color the context bar based on how full it is
if [ "$PCT" -ge 90 ]; then
  BAR_COLOR="$RED"
elif [ "$PCT" -ge 70 ]; then
  BAR_COLOR="$YELLOW"
else
  BAR_COLOR="$GREEN"
fi

# Build a 10-block progress bar
BAR_WIDTH=10
FILLED=$((PCT * BAR_WIDTH / 100))
EMPTY=$((BAR_WIDTH - FILLED))
BAR=""
[ "$FILLED" -gt 0 ] && printf -v FILL "%${FILLED}s" && BAR="${FILL// /█}"
[ "$EMPTY" -gt 0 ] && printf -v PAD "%${EMPTY}s" && BAR="${BAR}${PAD// /░}"

# Quota usage: "5h: X% 7d: Y%", falls back to n/a if the field is absent
# (API/console billing, or before the first response in the session)
QUOTA=""
[ -n "$FIVE_H" ] && QUOTA="5h: $(printf '%.0f' "$FIVE_H")%"
[ -n "$WEEK" ] && QUOTA="${QUOTA:+$QUOTA }7d: $(printf '%.0f' "$WEEK")%"
[ -z "$QUOTA" ] && QUOTA="n/a"

# Color the quota text based on how close to the limit it is
QUOTA_MAX=0
[ -n "$FIVE_H" ] && QUOTA_MAX=$(printf '%.0f' "$FIVE_H")
if [ -n "$WEEK" ]; then
  WEEK_INT=$(printf '%.0f' "$WEEK")
  [ "$WEEK_INT" -gt "$QUOTA_MAX" ] && QUOTA_MAX=$WEEK_INT
fi
if [ "$QUOTA_MAX" -ge 90 ]; then
  QUOTA_COLOR="$RED"
elif [ "$QUOTA_MAX" -ge 70 ]; then
  QUOTA_COLOR="$YELLOW"
else
  QUOTA_COLOR="$GREEN"
fi

# Duration as Xm Ys
DURATION_SEC=$((DURATION_MS / 1000))
MINS=$((DURATION_SEC / 60))
SECS=$((DURATION_SEC % 60))

# Git branch + dirty state (skips cleanly if not a git repo)
BRANCH=""
if git rev-parse --git-dir > /dev/null 2>&1; then
  BRANCH_NAME=$(git branch --show-current 2>/dev/null)
  STAGED=$(git diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')
  MODIFIED=$(git diff --numstat 2>/dev/null | wc -l | tr -d ' ')
  GIT_STATUS=""
  [ "$STAGED" -gt 0 ] && GIT_STATUS="${GREEN}+${STAGED}${RESET}"
  [ "$MODIFIED" -gt 0 ] && GIT_STATUS="${GIT_STATUS}${YELLOW}~${MODIFIED}${RESET}"
  BRANCH=" | 🌿 ${BRANCH_NAME} ${GIT_STATUS}"
fi

# Line 1: model, folder, git info
echo -e "${CYAN}[$MODEL]${RESET} 📁 ${DIR##*/}${BRANCH}"
# Line 2: context bar, quota, duration
echo -e "${BAR_COLOR}${BAR}${RESET} ${PCT}% ctx | ${QUOTA_COLOR}${QUOTA}${RESET} quota | ⏱️ ${MINS}m ${SECS}s"
```

## Notes

- **Quota (`5h`/`7d`) only shows for Claude.ai Pro/Max subscriptions.** On API or console billing, that field isn't sent, and the script prints `n/a` instead of breaking.
- The script runs locally on your machine and doesn't cost API tokens.
- It updates automatically whenever a new message arrives, after `/compact`, or when the permission mode changes.
- To customize further, ask Claude Code directly: `/statusline show <what you want>` will generate/adjust a script for you interactively.
- Full field reference: [Claude Code — Customize your status line](https://code.claude.com/docs/en/statusline)
