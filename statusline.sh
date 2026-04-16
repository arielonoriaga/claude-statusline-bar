#!/usr/bin/env bash
# Claude Code status line script
# Groups: [AI state] │ [Usage metrics] │ [Session mode] │ [Workspace]

input=$(cat)

# --- Claude Code defaults ---
model=$(echo "$input" | jq -r '.model.display_name // empty')
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
output_style=$(echo "$input" | jq -r '.output_style.name // empty')
vim_mode=$(echo "$input" | jq -r '.vim.mode // empty')

# --- Session token usage (cumulative, always present after first message) ---
total_in=$(echo "$input" | jq -r '.context_window.total_input_tokens // empty')
total_out=$(echo "$input" | jq -r '.context_window.total_output_tokens // empty')

# --- Rate limits (Claude Pro/Max subscription; absent for API-key-only users) ---
five_hr_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
five_hr_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
seven_day_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
seven_day_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

# --- Effort + permissions from settings.json (static config, not in JSON input) ---
SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
effort_level=$(jq -r '.effortLevel // empty' "$SETTINGS" 2>/dev/null)
bypass_perms=$(jq -r '.skipDangerousModePermissionPrompt // false' "$SETTINGS" 2>/dev/null)

# --- Workspace ---
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')

# --- Git info (skip optional locks for safety) ---
git_branch=""
git_changed=""
git_behind=""

if git -C "$cwd" rev-parse --git-dir > /dev/null 2>&1; then
  git_branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null || git -C "$cwd" rev-parse --short HEAD 2>/dev/null)

  # Count changed files (staged + unstaged + untracked)
  git_changed=$(git -C "$cwd" status --porcelain 2>/dev/null | wc -l | tr -d ' ')

  # Check for commits to pull (behind remote)
  remote_branch=$(git -C "$cwd" rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null)
  if [ -n "$remote_branch" ]; then
    git -C "$cwd" -c gc.auto=0 fetch --quiet 2>/dev/null
    behind=$(git -C "$cwd" rev-list --count HEAD.."$remote_branch" 2>/dev/null)
    [ -n "$behind" ] && [ "$behind" -gt 0 ] && git_behind="$behind"
  fi
fi

# --- ANSI colors ---
RESET='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'

C_BLUE='\033[34m'
C_CYAN='\033[36m'
C_YELLOW='\033[33m'
C_GREEN='\033[32m'
C_RED='\033[31m'
C_MAGENTA='\033[35m'
C_WHITE='\033[37m'

# --- Separators ---
# Between groups: full-weight padded pipe
GROUP_SEP="$(printf "  ${RESET}│  ")"
# Within a group: dim middle dot
ITEM_SEP="$(printf " ${DIM}·${RESET} ")"

# --- Helpers ---

fmt_until() {
  local target="$1" now delta d h m
  now=$(date +%s)
  delta=$((target - now))
  if [ "$delta" -le 0 ]; then echo "now"; return; fi
  d=$((delta / 86400))
  h=$(((delta % 86400) / 3600))
  m=$(((delta % 3600) / 60))
  if [ "$d" -gt 0 ]; then
    [ "$h" -gt 0 ] && echo "${d}d ${h}h" || echo "${d}d"
  elif [ "$h" -gt 0 ]; then
    [ "$m" -gt 0 ] && echo "${h}h ${m}m" || echo "${h}h"
  else
    echo "${m}m"
  fi
}

pct_color() {
  local p="$1"
  if [ "$p" -ge 80 ]; then printf '%s' "$C_RED"
  elif [ "$p" -ge 50 ]; then printf '%s' "$C_YELLOW"
  else printf '%s' "$C_GREEN"
  fi
}

join_items() {
  local sep="$1"; shift
  local result=""
  for item in "$@"; do
    [ -z "$item" ] && continue
    if [ -z "$result" ]; then
      result="$item"
    else
      result="${result}${sep}${item}"
    fi
  done
  printf '%s' "$result"
}

# ============================================================
# GROUP 1: AI state — model · ● effort
# ============================================================
g1_items=()

if [ -n "$model" ]; then
  g1_items+=("$(printf "${C_CYAN}${BOLD}%s${RESET}" "$model")")
fi

if [ -n "$effort_level" ]; then
  case "$effort_level" in
    xhigh)  eff_color="$C_RED" ;;
    high)   eff_color="$C_YELLOW" ;;
    medium) eff_color="$C_WHITE" ;;
    *)      eff_color="$C_WHITE" ;;
  esac
  g1_items+=("$(printf "${eff_color}●${RESET} ${DIM}%s${RESET}" "$effort_level")")
fi

g1=$(join_items "$ITEM_SEP" "${g1_items[@]}")

# ============================================================
# GROUP 2: Usage metrics — ctx · tok · 5h pct reset · 7d pct reset
# ============================================================
g2_items=()

# Context window %
if [ -n "$used_pct" ]; then
  rounded=$(printf '%.0f' "$used_pct")
  ctx_color=$(pct_color "$rounded")
  g2_items+=("$(printf "${DIM}ctx${RESET} ${ctx_color}%s%%${RESET}" "$rounded")")
fi

# Session tokens
if [ -n "$total_in" ] && [ -n "$total_out" ]; then
  total_tok=$((total_in + total_out))
  if [ "$total_tok" -ge 1000000 ]; then
    tok_display="$(awk "BEGIN{printf \"%.1fM\", $total_tok/1000000}")"
  elif [ "$total_tok" -ge 1000 ]; then
    tok_display="$(awk "BEGIN{printf \"%.0fk\", $total_tok/1000}")"
  else
    tok_display="${total_tok}"
  fi
  g2_items+=("$(printf "${DIM}tok${RESET} ${C_WHITE}%s${RESET}" "$tok_display")")
fi

# 5-hour rate limit: "5h 35% 4h23m"
if [ -n "$five_hr_pct" ]; then
  rounded_5h=$(printf '%.0f' "$five_hr_pct")
  fh_color=$(pct_color "$rounded_5h")
  fh_part="$(printf "${DIM}5h${RESET} ${fh_color}%s%%${RESET}" "$rounded_5h")"
  if [ -n "$five_hr_reset" ] && [ "$five_hr_reset" != "null" ]; then
    fh_until=$(fmt_until "$five_hr_reset")
    fh_part="${fh_part}$(printf " ${DIM}%s${RESET}" "$fh_until")"
  fi
  g2_items+=("$fh_part")
fi

# 7-day rate limit: "7d 62% 3d"
if [ -n "$seven_day_pct" ]; then
  rounded_7d=$(printf '%.0f' "$seven_day_pct")
  rl_color=$(pct_color "$rounded_7d")
  sd_part="$(printf "${DIM}7d${RESET} ${rl_color}%s%%${RESET}" "$rounded_7d")"
  if [ -n "$seven_day_reset" ] && [ "$seven_day_reset" != "null" ]; then
    sd_until=$(fmt_until "$seven_day_reset")
    sd_part="${sd_part}$(printf " ${DIM}%s${RESET}" "$sd_until")"
  fi
  g2_items+=("$sd_part")
fi

# Output style (skip if default)
if [ -n "$output_style" ] && [ "$output_style" != "default" ]; then
  g2_items+=("$(printf "${DIM}style %s${RESET}" "$output_style")")
fi

g2=$(join_items "$ITEM_SEP" "${g2_items[@]}")

# ============================================================
# GROUP 3: Session mode — vim mode · bypass
# ============================================================
g3_items=()

if [ -n "$vim_mode" ]; then
  if [ "$vim_mode" = "INSERT" ]; then
    g3_items+=("$(printf "${C_GREEN}${BOLD}INSERT${RESET}")")
  else
    g3_items+=("$(printf "${C_YELLOW}${BOLD}NORMAL${RESET}")")
  fi
fi

if [ "$bypass_perms" = "true" ]; then
  g3_items+=("$(printf "${C_YELLOW}bypass${RESET}")")
fi

g3=$(join_items "$ITEM_SEP" "${g3_items[@]}")

# ============================================================
# GROUP 4: Workspace — folder  branch status
# ============================================================
g4_items=()

# CWD display
if [ -n "$cwd" ]; then
  project_dir=$(echo "$input" | jq -r '.workspace.project_dir // empty')
  if [ -n "$project_dir" ] && [ "$cwd" != "$project_dir" ]; then
    rel="${cwd#$project_dir}"
    display_cwd="$(basename "$project_dir")${rel}"
  else
    display_cwd=$(basename "$cwd")
  fi
  g4_items+=("$(printf "${C_BLUE}${BOLD}%s${RESET}" "$display_cwd")")
fi

# Git — branch and status kept together, no item-sep between them
if [ -n "$git_branch" ]; then
  git_part="$(printf "${C_MAGENTA}%s${RESET}" "$git_branch")"

  if [ -n "$git_changed" ] && [ "$git_changed" -gt 0 ]; then
    git_part="${git_part}$(printf " ${C_YELLOW}~%s${RESET}" "$git_changed")"
    if [ -n "$git_behind" ]; then
      git_part="${git_part}$(printf " ${C_RED}↓%s${RESET}" "$git_behind")"
    fi
  else
    if [ -n "$git_behind" ]; then
      git_part="${git_part}$(printf " ${C_RED}↓%s${RESET}" "$git_behind")"
    else
      git_part="${git_part}$(printf " ${C_GREEN}✓${RESET}")"
    fi
  fi

  g4_items+=("$git_part")
fi

g4=$(join_items "$ITEM_SEP" "${g4_items[@]}")

# ============================================================
# Assemble groups — only include non-empty ones
# ============================================================
groups=()
[ -n "$g1" ] && groups+=("$g1")
[ -n "$g2" ] && groups+=("$g2")
[ -n "$g3" ] && groups+=("$g3")
[ -n "$g4" ] && groups+=("$g4")

result=$(join_items "$GROUP_SEP" "${groups[@]}")

printf "%b\n" "$result"
