#!/bin/bash
# Instalador automático do status line do Claude Code
# (context usage + quota 5h/7d + git branch + duração da sessão)
#
# O que este script faz:
#   1. Verifica/instala o jq (necessário para o statusline.sh)
#   2. Cria ~/.claude/statusline.sh (faz backup se já existir)
#   3. Torna o script executável
#   4. Adiciona/atualiza a chave "statusLine" em ~/.claude/settings.json
#      sem apagar outras configurações que já existam ali
#
# Uso:
#   chmod +x install-statusline.sh
#   ./install-statusline.sh

set -e

CLAUDE_DIR="$HOME/.claude"
STATUSLINE_PATH="$CLAUDE_DIR/statusline.sh"
SETTINGS_PATH="$CLAUDE_DIR/settings.json"
TIMESTAMP=$(date +%Y%m%d%H%M%S)

echo "==> Configurando status line do Claude Code..."

# ---------------------------------------------------------------
# 1. Verificar / instalar jq
# ---------------------------------------------------------------
if command -v jq > /dev/null 2>&1; then
  echo "✓ jq já está instalado."
else
  echo "! jq não encontrado. Tentando instalar automaticamente..."
  if command -v brew > /dev/null 2>&1; then
    brew install jq
  elif command -v apt-get > /dev/null 2>&1; then
    sudo apt-get update && sudo apt-get install -y jq
  elif command -v dnf > /dev/null 2>&1; then
    sudo dnf install -y jq
  elif command -v pacman > /dev/null 2>&1; then
    sudo pacman -S --noconfirm jq
  else
    echo "✗ Não foi possível detectar um gerenciador de pacotes conhecido (brew/apt/dnf/pacman)."
    echo "  Instale o jq manualmente (https://jqlang.org/download/) e rode este script de novo."
    exit 1
  fi
fi

if ! command -v jq > /dev/null 2>&1; then
  echo "✗ A instalação do jq falhou. Instale manualmente e rode este script de novo."
  exit 1
fi

# ---------------------------------------------------------------
# 2. Criar ~/.claude e escrever o statusline.sh (com backup se existir)
# ---------------------------------------------------------------
mkdir -p "$CLAUDE_DIR"

if [ -f "$STATUSLINE_PATH" ]; then
  cp "$STATUSLINE_PATH" "$STATUSLINE_PATH.bak.$TIMESTAMP"
  echo "✓ Script existente salvo como backup: statusline.sh.bak.$TIMESTAMP"
fi

cat > "$STATUSLINE_PATH" << 'STATUSLINE_EOF'
#!/bin/bash
# Claude Code custom status line
# Shows: model | dir | git branch+status | context usage bar | rate-limit quota | duration
#
# Note: rate_limits (5h/7d quota) is only sent for Claude.ai Pro/Max
# subscribers, and only after the first API response in the session.
# On API/console billing this field is absent, so the script falls
# back to "n/a" for that segment.

input=$(cat)

MODEL=$(echo "$input" | jq -r '.model.display_name')
DIR=$(echo "$input" | jq -r '.workspace.current_dir')
DURATION_MS=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')
PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
TOKENS=$(echo "$input" | jq -r '
  .context_window.total_input_tokens //
  ((.context_window.current_usage.input_tokens // 0) +
   (.context_window.current_usage.cache_creation_input_tokens // 0) +
   (.context_window.current_usage.cache_read_input_tokens // 0))
')
FIVE_H=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
WEEK=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')

CYAN='\033[36m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
RESET='\033[0m'

# Compact token count: 46600 -> 46.6k
TOKENS_DISPLAY=$(awk -v tokens="$TOKENS" 'BEGIN {
  if (tokens >= 1000000) printf "%.1fM", tokens / 1000000
  else if (tokens >= 1000) printf "%.1fk", tokens / 1000
  else printf "%d", tokens
}')

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

# Duration as Xm Ys, or Xh Ym after one hour
DURATION_SEC=$((DURATION_MS / 1000))
MINS=$((DURATION_SEC / 60))
SECS=$((DURATION_SEC % 60))
if [ "$MINS" -ge 60 ]; then
  HOURS=$((MINS / 60))
  REMAINING_MINS=$((MINS % 60))
  DURATION="${HOURS}h ${REMAINING_MINS}m"
else
  DURATION="${MINS}m ${SECS}s"
fi

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
echo -e "${BAR_COLOR}${BAR}${RESET} ${PCT}% ctx (${TOKENS_DISPLAY}) | ${QUOTA_COLOR}${QUOTA}${RESET} quota | ⏱️ ${DURATION}"
STATUSLINE_EOF

chmod +x "$STATUSLINE_PATH"
echo "✓ Script criado em: $STATUSLINE_PATH"

# ---------------------------------------------------------------
# 3. Atualizar settings.json sem apagar o que já existe
# ---------------------------------------------------------------
if [ -f "$SETTINGS_PATH" ]; then
  cp "$SETTINGS_PATH" "$SETTINGS_PATH.bak.$TIMESTAMP"
  echo "✓ settings.json existente salvo como backup: settings.json.bak.$TIMESTAMP"

  if ! jq empty "$SETTINGS_PATH" > /dev/null 2>&1; then
    echo "✗ $SETTINGS_PATH existe mas não é um JSON válido."
    echo "  Corrija o arquivo manualmente (veja o backup) e rode este script de novo."
    exit 1
  fi

  jq '.statusLine = {"type": "command", "command": "~/.claude/statusline.sh"}' \
    "$SETTINGS_PATH" > "$SETTINGS_PATH.tmp" && mv "$SETTINGS_PATH.tmp" "$SETTINGS_PATH"
else
  cat > "$SETTINGS_PATH" << 'SETTINGS_EOF'
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh"
  }
}
SETTINGS_EOF
fi

echo "✓ settings.json atualizado em: $SETTINGS_PATH"
echo ""
echo "==> Tudo pronto! Abra (ou reinicie) o Claude Code e a status line já deve aparecer."
echo "    Se ela não aparecer, verifique se você aceitou o diálogo de 'workspace trust' da pasta."
