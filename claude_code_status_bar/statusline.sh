#!/bin/bash
# Claude Code statusline — model · effort · fast · dir · git · context window · spend · time
# Receives session JSON on stdin. Requires jq (awk + git optional).
input=$(cat)

MODEL=$(echo "$input"  | jq -r '.model.display_name // "Claude"')
DIR=$(echo "$input"    | jq -r '.workspace.current_dir // .cwd // ""')
COST=$(echo "$input"   | jq -r '.cost.total_cost_usd // 0')
DUR_MS=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')
PCT=$(echo "$input"    | jq -r '.context_window.used_percentage // 0')
USED=$(echo "$input"   | jq -r '.context_window.total_input_tokens // 0')
SIZE=$(echo "$input"   | jq -r '.context_window.context_window_size // 200000')
EFF=$(echo "$input"    | jq -r '.effort.level // empty')
FAST=$(echo "$input"   | jq -r '.fast_mode // false')

# ANSI colors
C='\033[36m'; G='\033[32m'; Y='\033[33m'; R='\033[31m'; D='\033[90m'; B='\033[1m'; X='\033[0m'

# Context bar: single shade from % (green→yellow→red). 10 blocks × 8 sub-steps = 80 levels.
# filled = solid shade; edge = partial block ▏▎▍▌▋▊▉; empty = light tint of the same hue.
PCT_INT=$(awk -v p="$PCT" 'BEGIN{printf "%d",(p+0.5)}')
W=10; FS=$(awk -v p="$PCT" -v s="$((W*8))" 'BEGIN{printf "%d",(p/100*s)+0.5}')
FULL=$((FS/8)); REM=$((FS%8))
read MR MG MB < <(awk -v p="$PCT" 'BEGIN{ if(p<0)p=0; if(p>100)p=100; if(p<=50){printf "%d 255 0", int(p/50*255)}else{printf "255 %d 0", int((100-p)/50*255)} }')
read LR LG LB < <(awk -v r="$MR" -v g="$MG" -v b="$MB" 'BEGIN{ t=0.6; printf "%d %d %d", int(r+(255-r)*t), int(g+(255-g)*t), int(b+(255-b)*t) }')
MAIN=$(printf '\033[38;2;%d;%d;%dm' "$MR" "$MG" "$MB")
LIGHT=$(printf '\033[38;2;%d;%d;%dm' "$LR" "$LG" "$LB")
EIGHTS=(▏ ▎ ▍ ▌ ▋ ▊ ▉)
BAR=""
for ((c=0; c<W; c++)); do
  if   [ "$c" -lt "$FULL" ]; then BAR+="${MAIN}█"
  elif [ "$c" -eq "$FULL" ] && [ "$REM" -gt 0 ]; then BAR+="${MAIN}${EIGHTS[$((REM-1))]}"
  else BAR+="${LIGHT}░"; fi
done

used_k=$(awk "BEGIN{printf \"%.1fk\",$USED/1000}")
size_k=$(awk "BEGIN{printf \"%dk\",$SIZE/1000}")
T=$((DUR_MS/1000))
if [ "$T" -ge 6000 ]; then
  printf -v T_FMT "%dh%02dm" $((T/3600)) $(((T%3600)/60))   # ≥100 min → hours
else
  printf -v T_FMT "%dm%02ds" $((T/60)) $((T%60))
fi
COST_FMT=$(printf '$%.2f' "$COST")

# Git branch (only when inside a repo)
BRANCH=""
git rev-parse --git-dir >/dev/null 2>&1 && BRANCH=" ${D}> 🌿 $(git branch --show-current 2>/dev/null)${X}"

# Optional badges
TAG=""; [ -n "$EFF" ] && TAG=" ${D}🧠 ${EFF}${X}"; [ "$FAST" = "true" ] && TAG="$TAG ${Y}⚡ fast${X}"

# Dim separator between major groups (model · location · context · spend · time · greeting)
SEP=" ${D}│${X} "

# Time-of-day greeting — per-hour rotation (local time). Seed = hour + day-of-year,
# so the message is stable within the hour and also varies day-to-day.
HOUR=$(date +%H); DOY=$(date +%j)
case "$HOUR" in
  0[0-4])      G_E="😴";  G_MSGS=( "Go to sleep. Bugs can wait." "It's late. Commit and log off." "Your bed misses you." "Late-night debugging is a trap." "Save your work. Then yourself." "Sleep is the best debugger." );;
  0[5-7])      G_E="🌅";  G_MSGS=( "Up with the sun. Or the rooster." "Dawn patrol. Let's ship." "Early code is fresh code." "The world is quiet. Use it." "Coffee: now mandatory." "Greet the day, then the terminal." );;
  0[89]|1[01]) G_E="☀️";  G_MSGS=( "Coffee first, dread later." "Good morning. Let's break things." "Fresh mind, fresh bugs." "Morning motivation: caffeine." "Today's bug, tomorrow's anecdote." "Let's build something weird." );;
  1[2-6])      G_E="🌤️"; G_MSGS=( "99 little bugs in the code…" "Lunch was a lie. Keep coding." "Stack Overflow awaits." "It works on my machine 🤷" "Slump? Nopenope." "Ship it. Patch it later." );;
  1[7-9]|2[0]) G_E="🌆";  G_MSGS=( "Ship it before it ships you." "Evening grind. Stay sharp." "One more feature. Then dinner." "Almost beer o'clock." "Refactor now, regret less." "The deploy will hold. Probably." );;
  2[1-3])      G_E="🌙";  G_MSGS=( "Wind down. Save the file." "Good night. Push first." "Tomorrow-you thanks present-you." "Log off. The code will wait." "Dream in clean architecture." "Commit, push, sleep. Repeat." );;
  *)           G_E="✨";  G_MSGS=( "Keep going." );;
esac
G_I=$(awk -v seed="$(( 10#$HOUR*1000 + 10#$DOY ))" -v n="${#G_MSGS[@]}" 'BEGIN{srand(seed+0); print int(rand()*n)}')
GREET="${SEP}${G_E} ${D}${G_MSGS[$G_I]}${X}"

printf "%b" "🤖 ${B}${C}${MODEL}${X}${TAG}${SEP}📁 ${DIR##*/}${BRANCH}${SEP}${BAR}${X} ${PCT_INT}% ${D}(${used_k}/${size_k})${X}${SEP}💸 ${Y}${COST_FMT}${X}${SEP}⏱️ ${T_FMT}${GREET}\n"
