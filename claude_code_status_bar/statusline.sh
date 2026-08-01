#!/bin/bash
# Claude Code statusline — model · effort · fast · dir · git · context window (in/out split) · time
# Receives session JSON on stdin. Requires jq (awk + git optional).
input=$(cat)

MODEL=$(echo "$input"  | jq -r '.model.display_name // "Claude"')
MODEL_ID=$(echo "$input" | jq -r '.model.id // ""')
DIR=$(echo "$input"    | jq -r '.workspace.current_dir // .cwd // ""')
DUR_MS=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')
INPUT_TOKENS=$(echo "$input"  | jq -r '.context_window.total_input_tokens // 0')
OUTPUT_TOKENS=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0')
SIZE=$(echo "$input"   | jq -r '.context_window.context_window_size // 200000')
EFF=$(echo "$input"    | jq -r '.effort.level // empty')
FAST=$(echo "$input"   | jq -r '.fast_mode // false')
TRANSCRIPT_PATH=$(echo "$input" | jq -r '.transcript_path // ""')

# GLM models: Claude Code reports a generic 200K for unknown models. Pin verified values.
case "$MODEL_ID" in
  *glm-5.1*)   SIZE=200000 ;;   # verified 200K context
  *glm-4.7*)   SIZE=200000 ;;   # verified 200K context
esac

# Token counts can flicker to 0 while a turn is generating: Claude Code emits a
# transient status payload whose context_window fields are absent mid-turn, so
# the "// 0" fallbacks flash the bar empty. Hold the last known-good counts per
# session so the bar stays steady mid-turn and refreshes when the reply lands.
SID=$(echo "$input" | jq -r '.session_id // "default"')
CACHE_DIR="${TMPDIR:-/tmp}/cc-statusline"; [ -d "$CACHE_DIR" ] || mkdir -p "$CACHE_DIR" 2>/dev/null
CACHE_FILE="$CACHE_DIR/$SID"
if [ "$INPUT_TOKENS" -gt 0 ] || [ "$OUTPUT_TOKENS" -gt 0 ]; then
  printf '%s %s %s\n' "$INPUT_TOKENS" "$OUTPUT_TOKENS" "$SIZE" > "$CACHE_FILE" 2>/dev/null   # remember
else
  [ -f "$CACHE_FILE" ] && read INPUT_TOKENS OUTPUT_TOKENS SIZE < "$CACHE_FILE"                # reuse
fi

# ANSI colors
C='\033[36m'; G='\033[32m'; Y='\033[33m'; R='\033[31m'; D='\033[90m'; B='\033[1m'; X='\033[0m'

# ---- context window: input (light) → output (dark) → remaining (lightest) ----
USED=$((INPUT_TOKENS + OUTPUT_TOKENS))
PCT=$(awk -v u="$USED" -v s="$SIZE" 'BEGIN{ if(s>0) printf "%.2f", u/s*100; else print 0 }')
PCT_INT=$(awk -v p="$PCT" 'BEGIN{printf "%d",(p+0.5)}')

# Base hue from overall usage (green→yellow→red). Three shades derived from it:
#   MAIN  = darkest  → output portion
#   LIGHT = medium   → input portion
#   EMPTY = lightest → remaining portion
read MR MG MB < <(awk -v p="$PCT" 'BEGIN{ if(p<0)p=0; if(p>100)p=100; if(p<=50){printf "%d 255 0", int(p/50*255)}else{printf "255 %d 0", int((100-p)/50*255)} }')
MAIN=$(printf '\033[38;2;%d;%d;%dm' "$MR" "$MG" "$MB")
read IL IG IB < <(awk -v r="$MR" -v g="$MG" -v b="$MB" 'BEGIN{ t=0.5; printf "%d %d %d", int(r+(255-r)*t), int(g+(255-g)*t), int(b+(255-b)*t) }')
LIGHT=$(printf '\033[38;2;%d;%d;%dm' "$IL" "$IG" "$IB")
read EL EG EB < <(awk -v r="$MR" -v g="$MG" -v b="$MB" 'BEGIN{ t=0.85; printf "%d %d %d", int(r+(255-r)*t), int(g+(255-g)*t), int(b+(255-b)*t) }')
EMPTY=$(printf '\033[38;2;%d;%d;%dm' "$EL" "$EG" "$EB")

# Sub-step positions across W blocks × 8 sub-steps (W*8 levels map to SIZE tokens)
W=10; TOT=$((W*8))
IN_FS=$(awk -v i="$INPUT_TOKENS" -v s="$SIZE" -v tot="$TOT" 'BEGIN{ v=int(i/s*tot+0.5); if(v<0)v=0; if(v>tot)v=tot; print v }')
OUT_FS=$(awk -v o="$OUTPUT_TOKENS" -v s="$SIZE" -v tot="$TOT" 'BEGIN{ v=int(o/s*tot+0.5); if(v<0)v=0; if(v>tot)v=tot; print v }')
[ "$((IN_FS + OUT_FS))" -gt "$TOT" ] && OUT_FS=$((TOT - IN_FS))   # never overflow the bar
[ "$OUT_FS" -lt 0 ] && OUT_FS=0
# A small but nonzero output should still be visible as one sub-step
[ "$OUTPUT_TOKENS" -gt 0 ] && [ "$OUT_FS" -eq 0 ] && OUT_FS=1

EIGHTS=(▏ ▎ ▍ ▌ ▋ ▊ ▉)
BAR=""
for ((c=0; c<W; c++)); do
  start=$((c*8)); end=$((start+8))
  filled=0; col=""
  for ((s=start; s<end; s++)); do
    if   [ "$s" -lt "$IN_FS" ];               then filled=$((filled+1)); col="$LIGHT"   # input
    elif [ "$s" -lt "$((IN_FS + OUT_FS))" ];  then filled=$((filled+1)); col="$MAIN"    # output
    else break; fi
  done
  if   [ "$filled" -ge 8 ]; then BAR+="${col}█"
  elif [ "$filled" -gt 0 ]; then BAR+="${col}${EIGHTS[$((filled-1))]}"
  else BAR+="${EMPTY}░"; fi
done

# Token → readable string: raw int below 1k, else "N.Nk"
tok_fmt() {
  local t=$1
  [ -z "$t" ] && { echo 0; return; }
  if [ "$t" -lt 1000 ]; then printf "%d" "$t"
  else awk "BEGIN{printf \"%.1fk\", $t/1000}"; fi
}

# Model -> context window size. GLM family pinned (verified 200K); unknown falls
# back to 200K (same default the main session uses when the payload omits a size).
size_for_model() {
  case "$1" in
    *glm-5.1*|*glm-4.7*|*glm-5.2*) echo 200000 ;;
    *) echo 200000 ;;
  esac
}

# Effort level -> 5-dot meter (matches the main effort badge).
effort_dots() {
  case "$1" in
    low)    printf '●○○○○' ;;
    medium) printf '●●○○○' ;;
    high)   printf '●●●○○' ;;
    xhigh)  printf '●●●●○' ;;
    max)    printf '●●●●●' ;;
    *)      printf '%s' "$1" ;;
  esac
}

# Portable file mtime in epoch seconds (macOS BSD stat -f %m vs Linux GNU stat -c %Y).
_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

# Compact 8-cell gradient bar (green->red by %) for one subagent's context usage.
sub_bar() {
  read r g b lv < <(awk -v u="$1" -v s="$2" 'BEGIN{
    p=(s>0)?u/s*100:0; if(p<0)p=0; if(p>100)p=100;
    if(p<=50){r=int(p/50*255);g=255;b=0}else{r=255;g=int((100-p)/50*255);b=0}
    lv=int(p/100*64+0.5); if(lv>64)lv=64; printf "%d %d %d %d",r,g,b,lv
  }')
  local col=$(printf '\033[38;2;%d;%d;%dm' "$r" "$g" "$b")
  local bar="" c base filled
  for ((c=0;c<8;c++)); do
    base=$((c*8))
    if   [ "$lv" -ge $((base+8)) ]; then bar+="${col}█"
    elif [ "$lv" -gt  "$base" ];   then filled=$((lv-base)); bar+="${col}${EIGHTS[$((filled-1))]}"
    else bar+="${D}░"; fi
  done
  printf '%s%s' "$bar" "$X"
}

in_k=$(tok_fmt "$INPUT_TOKENS"); out_k=$(tok_fmt "$OUTPUT_TOKENS")
size_k=$(awk "BEGIN{printf \"%dk\", $SIZE/1000}")

T=$((DUR_MS/1000))
if [ "$T" -ge 6000 ]; then
  printf -v T_FMT "%dh%02dm" $((T/3600)) $(((T%3600)/60))   # ≥100 min → hours
else
  printf -v T_FMT "%dm%02ds" $((T/60)) $((T%60))
fi

# Git branch (only when inside a repo)
BRANCH=""
git rev-parse --git-dir >/dev/null 2>&1 && BRANCH=" ${D}> 🌿 $(git branch --show-current 2>/dev/null)${X}"

# Optional badges — effort as a compact 5-dot meter (●/○), fast as a bare bolt.
case "$EFF" in
  low)    EFF_S="●○○○○" ;;
  medium) EFF_S="●●○○○" ;;
  high)   EFF_S="●●●○○" ;;
  xhigh)  EFF_S="●●●●○" ;;
  max)    EFF_S="●●●●●" ;;
  *)      EFF_S="$EFF" ;;
esac
TAG=""
[ -n "$EFF" ] && TAG=" ${D}${EFF_S}${X}"
if [ "$FAST" = "true" ]; then
  # bolt sits flush against the effort meter; standalone (with a leading space) otherwise
  [ -n "$TAG" ] && TAG="${TAG}${Y}⚡${X}" || TAG=" ${Y}⚡${X}"
fi

# Dim separator between major groups (model · location · context · time · greeting)
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
G_N=${#G_MSGS[@]}
G_I=$(awk -v seed="$(( 10#$HOUR*1000 + 10#$DOY ))" -v n="$G_N" 'BEGIN{srand(seed+0); print int(rand()*n)}')
GREET="${SEP}${G_E} ${D}${G_MSGS[$G_I]}${X}"

CTX="${D}(${LIGHT}↑${D}${in_k} ${MAIN}↓${D}${out_k}/${size_k})${X}"

# Subagent rows: one line per currently-running subagent (transcript mtime within
# SUB_STALE seconds). While any run, the greeting is hidden to make room; it
# returns when idle. SUB_STALE is env-tunable (default 15s).
SUB_STALE="${SUB_STALE:-15}"
SUB_LINES=""
SUB_DIR="${TRANSCRIPT_PATH%.jsonl}/subagents"
if [ -d "$SUB_DIR" ]; then
  _now=$(date +%s); _n=0; _extra=0
  while IFS= read -r _af; do
    [ -z "$_af" ] && continue
    _mt=$(_mtime "$_af"); [ -z "$_mt" ] && continue
    [ $((_now - _mt)) -ge "$SUB_STALE" ] && continue
    _n=$((_n + 1))
    if [ "$_n" -gt 3 ]; then _extra=$((_extra + 1)); continue; fi
    _meta="${_af%.jsonl}.meta.json"
    _atype=$(jq -r '.agentType // "subagent"' "$_meta" 2>/dev/null)
    _desc=$(jq -r '.description // ""' "$_meta" 2>/dev/null); _desc=${_desc:0:40}
    _last=$(jq -c 'select(.type=="assistant") | {m:(.message.model//""), u:.message.usage, e:(.effort|if type=="object" then (.level//"") elif type=="string" then . else "" end)}' "$_af" 2>/dev/null | tail -1)
    read _inctx _out _smodel _seff < <(printf '%s' "$_last" | jq -r '[(.u.input_tokens//0)+(.u.cache_creation_input_tokens//0)+(.u.cache_read_input_tokens//0),(.u.output_tokens//0),.m,(.e//"")]|@tsv' 2>/dev/null)
    _name="$_atype"; [ -n "$_desc" ] && _name="$_atype · $_desc"
    _line="  ${D}↳${X} ${C}${_name}${X}"
    [ -n "$_smodel" ] && _line+=" ${SEP}🤖 ${D}${_smodel}${X}"
    [ -n "$_seff" ]   && _line+=" ${SEP}${D}$(effort_dots "$_seff")${X}"
    if [ -z "$_inctx" ]; then
      _line+=" ${D}starting…${X}"
    else
      _ssize=$(size_for_model "$_smodel")
      _used=$((_inctx + _out))
      _line+=" ${SEP}$(sub_bar "$_used" "$_ssize") ${D}$(tok_fmt "$_used")${X}"
    fi
    SUB_LINES+="${_line}\n"
  done < <(ls -t "$SUB_DIR"/agent-*.jsonl 2>/dev/null)
  [ "$_extra" -gt 0 ] && SUB_LINES+="  ${D}↳ … +${_extra} more${X}\n"
fi
[ -n "$SUB_LINES" ] && GREET=""

printf "%b" "🤖 ${B}${C}${MODEL}${X}${TAG}${SEP}📁 ${DIR##*/}${BRANCH}${SEP}${BAR}${X} ${PCT_INT}% ${CTX}${SEP}⏱️ ${T_FMT}${GREET}\n"
[ -n "$SUB_LINES" ] && printf '%b' "$SUB_LINES"
exit 0
