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

# Truncate a long name (branch/folder) to 15 chars + "...".
short() { local n="$1"; [ "${#n}" -gt 15 ] && printf '%s...' "${n:0:15}" || printf '%s' "$n"; }

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
git rev-parse --git-dir >/dev/null 2>&1 && BRANCH=" ${D}> 🌿 $(short "$(git branch --show-current 2>/dev/null)")${X}"

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
  0[0-4]) G_E="😴"; G_MSGS=(
    "Bugs can wait. Sleep."
    "It's late. Log off."
    "Your bed misses you."
    "Late debugging is a trap."
    "Save work. Then yourself."
    "Sleep is best debugger."
    "Bug keeps until noon."
    "2am you isn't smart."
    "Commit, push, close lid."
    "Future you wants sleep."
    "Even servers are yawning."
    "Dark mode hides nothing."
    "One more fix lies."
    "Terminal glows. You stop."
    "Bugs breed after midnight."
    "Go to bed now."
    "Late code ages poorly."
    "Sleep debt compounds fast."
    "The moon saw enough."
    "Pivot to the pillow."
    "Midnight genius is tired."
    "Revert tonight's mess tomorrow."
    "Patience cache is empty."
    "Night shift? Night drift."
    "Keyboard's tired. You too."
    "Closed laptop, open bed."
    "Stop now. Future thanks."
    "Bug stays. You go."
    "Midnight rewrites, sunrise regrets."
    "Even grep needs rest."
    "Save state, save yourself."
    "Build waits for breakfast."
    "Late confidence breeds bugs."
    "Pillow outranks your PR."
    "Dim screen. Close it."
    "Git log forgives. Spine?"
    "3am refactors equal regret."
    "Ship nothing. Just sleep."
    "Eyes quit hours ago."
    "Terminal stays. Leave now."
    "Closing tabs is progress."
    "The bug is patient."
    "Darkness hides more bugs."
    "Merge waits till morning."
    "Midnight oil is empty."
    "Stop typing. Start dreaming."
    "Even linter is asleep."
    "Can't revert lost sleep."
    "Deploy glows. Don't trust."
    "Save. Quit. Sleep now."
    "Tomorrow starts with sleep."
    "Bug isn't worth bags."
    "Late nights ship bugs."
    "Bed filed a PR."
    "Tired code breeds bugs."
    "Rest is valid commit."
    "Night owls lie. Sleep."
    "Your coffee gave up."
    "Cursor blinks slower now."
    "Put the semicolon down."
    "Diff outlives your focus."
    "Sleep first. Refactor never."
    "Stash isn't a story."
    "3am fix, 3pm fire."
    "Bugs love tired devs."
    "Close laptop. Mean it."
    "Night is for restoration."
    "Future self dreads this."
    "Sleep is skipped dependency."
    "Terminal hums. Bed calls."
    "Late certainty is fatigue."
    "Eyes deserve real rest."
    "Prod's quiet. Brain isn't."
    "Commit waits for sunrise."
    "Tuck the code in."
    "Reflexes left at midnight."
    "Only hot thing: cocoa."
    "Stop. Drop. Deploy tomorrow."
    "TODO won't haunt sleep."
    "Night shift has limits."
    "Bug outlives tonight's sanity."
    "Save heroics for daylight."
    "Pillow uptime is zero."
    "Darkness is for closing."
    "Standup skips 3am commits."
    "Even loops need exits."
    "Caffeine clocked out already."
    "Screen's last task: off."
    "Late nights cost tomorrow."
    "Bug isn't nocturnal. Stubborn."
    "Brain battery: one percent."
    "Night owes you sleep."
    "Close issue. Open bed."
    "Midnight has a curfew."
    "Code worsens past midnight."
    "Ship yourself to bed."
    "Rest optimizes the runtime."
    "Trace won't tuck you."
    "Log off. Be proud."
    "Good night. Sleep well."
  );;
  0[5-7]) G_E="🌅"; G_MSGS=(
    "Up with the sun."
    "Dawn patrol. Let's ship."
    "Early code is fresh."
    "World's quiet. Use it."
    "Coffee is now mandatory."
    "Greet day, then terminal."
    "First light, first commit."
    "Early dev, clean merge."
    "Sunrise over the trace."
    "Fresh coffee, fresh bugs."
    "Internet's still asleep. Good."
    "Morning brain, bug-free runtime."
    "Dew on grass. Ship."
    "Rise and git pull."
    "Rooster crows. Linter wakes."
    "Quiet hours, shipping hours."
    "Brew coffee, then plan."
    "Dawn skips the Slack."
    "Early bird, green build."
    "Sun's up. Motivation too."
    "Fresh IDE, fresh mistakes."
    "Mornings are for momentum."
    "World boots. You too."
    "Sunrise between the commits."
    "Fewer meetings, more magic."
    "Code's crisp before noon."
    "First sip, first script."
    "Zero pings, infinite focus."
    "Birds are up. Match."
    "Morning glow beats screens."
    "Coffee in, cursor ready."
    "Day hasn't asked yet."
    "Dawn is pre-meeting bliss."
    "Rise. Brew. Run dev."
    "Quiet morning, loud progress."
    "Early start, easy merge."
    "Sunrise needs no status."
    "Fresh start beats fresh bug."
    "Morning focus is uncut."
    "Dew agrees: ship today."
    "First light, fewer fires."
    "Early shift skips backlog."
    "Dawn is meeting-free."
    "Brew strong. Ship stronger."
    "Willpower peaks with sun."
    "Morning's yours. Keep it."
    "Early commits age well."
    "Sunrise side of keyboard."
    "World's loading. Get ahead."
    "Morning energy is renewable."
    "First cup, first functions."
    "Dawn ignores the deadlines."
    "Early dev out-ships late."
    "Quiet dawn, clear diffs."
    "Rise with sun, flow."
    "Morning is debug gold."
    "Coffee's hot. Streak's live."
    "Dawn ships before standup."
    "Early light, light load."
    "Day's a blank branch."
    "Focus lives before email."
    "Sunrise sprint, no blockers."
    "Brew first. Refactor later."
    "Rooster's a better PM."
    "Early hours compound wins."
    "Dawn forgives. Day doesn't."
    "Quiet keys, loud results."
    "Morning hasn't met bugs."
    "Rise, rinse, run tests."
    "First light is free."
    "Sun's up, standards too."
    "Momentum is the framework."
    "Zero pings, max flow."
    "Early bird, clean tree."
    "Coffee's brewing. Work too."
    "Mornings are unbothered."
    "Sunrise ships the gnarly."
    "Day starts clean. Keep."
    "Early hours, no meetings."
    "Dawn clears the queue."
    "First light, fresh eyes."
    "Morning's a gift. Use."
    "Rise early, merge early."
    "Coffee done. Focus loading."
    "Early dev dodges slump."
    "Dawn skips your inbox."
    "Morning clarity is power."
    "Sun rose. Throughput too."
    "Early start, calm finish."
    "Quiet dawn, clean console."
    "Birds ship at sunrise."
    "Morning bar is empty."
    "Dawn is for doers."
    "First light, first feature."
    "Coffee calls. Cursor too."
    "Rise. Bugs aren't ready."
    "Momentum beats midnight heroics."
    "Sun agrees with roadmap."
    "Early, steady, ships product."
    "Dawn ships before world."
  );;
  0[89]|1[01]) G_E="☀️"; G_MSGS=(
    "Coffee first, dread later."
    "Good morning. Break things."
    "Fresh mind, fresh bugs."
    "Motivation: pure caffeine."
    "Today's bug, tomorrow's story."
    "Let's build something weird."
    "Caffeine compiled. Execute now."
    "Morning meetings: warm-up laps."
    "Green build, green tea."
    "Goal: more commits, fewer alarms."
    "Second cup, second wind."
    "Morning energy, handle carefully."
    "Standup comes. Arm yourself."
    "Fresh eyes find dumbness."
    "Good day to delete."
    "Coffee is hot reload."
    "Motivation runs on beans."
    "PR queue is warming."
    "New day, same types."
    "Morning focus: fragile, potent."
    "Inbox woke. Pace it."
    "Today's feature, tomorrow's debt."
    "Clarity fades by noon."
    "Coffee's working. You?"
    "Fresh context. Don't waste."
    "Morning's for hard problems."
    "Compiler's forgiving today."
    "Plan: ship, snack, repeat."
    "Momentum is mostly renewable."
    "Standup won't stand itself."
    "Fresh brew, fresh regret."
    "Morning you is optimistic."
    "Bug report, future story."
    "Coffee in, code out."
    "Keyboard's warm. So's lead."
    "TODO feels doable now."
    "Fresh mind, stale config."
    "Build today, debug tomorrow."
    "Pair up: two brains."
    "Sprint starts with sip."
    "Energy is limited offer."
    "Commits become tomorrow's blame."
    "Coffee first, meetings last."
    "Mornings make refactors wise."
    "Fresh log, dirty keyboard."
    "Bug gets squashed. Maybe."
    "Optimism dies at tests."
    "Caffeine in, blockers out."
    "Ambitious now, realistic later."
    "Fresh start, same doubts."
    "Write past-you's code."
    "Build passes. Enjoy briefly."
    "Window before scope creep."
    "Coffee makes merges bearable."
    "Three-coffee kind of problem."
    "Morning's underrated dependency."
    "Fresh mind, legacy code."
    "Be the dev needed."
    "Focus is currency. Spend."
    "Sprint board is hopeful."
    "Coffee turns later now."
    "Docs almost make sense."
    "Today the bug fears."
    "Standup reports to you."
    "Pair: two cups, cursor."
    "Fresh resolve, same task."
    "Type errors cooperate. Allegedly."
    "Meeting tests your caffeine."
    "Coffee charged. Patience loading."
    "Spend momentum on scary."
    "Merge like nobody's watching."
    "Inbox loud. Code louder."
    "Break things on purpose."
    "Fresh ideas need grounds."
    "One fewer TODO today."
    "Compiler's in good mood."
    "Clarity is free. Borrow."
    "Coffee is morning's tape."
    "Ship the avoided thing."
    "Mornings forgive bold refactors."
    "Fresh keys, same memory."
    "Today's the day. Always."
    "Energy peaks pre-meeting."
    "PRs pile up. Brew."
    "Coffee first, courage second."
    "Mornings make tests worthy."
    "Let linter be friend."
    "Standup's short. Sprint's long."
    "Fresh branch, fresh hope."
    "Calm before the calendar."
    "Diff is your canvas."
    "Coffee never breaks. Depend."
    "Motivation is caffeinated confidence."
    "Inbox waits. Idea doesn't."
    "Fewer lines, more meaning."
    "Delete a feature today."
    "Fresh coffee, old bugs."
    "Day's young. Branch too."
    "Ask why it's there."
    "Morning. Make it count."
  );;
  1[2-6]) G_E="🌤️"; G_MSGS=(
    "99 bugs in code…"
    "Lunch lied. Keep coding."
    "Stack Overflow awaits you."
    "Works on my machine 🤷"
    "Slump? Nope, nope."
    "Ship it. Patch later."
    "Post-lunch coma, no patch."
    "Slump is real. Coffee."
    "Take one down, 127."
    "Worked on my machine."
    "3pm slump fights back."
    "Stack Overflow: senior dev."
    "Afternoon energy is borrowed."
    "Meeting could've been diff."
    "One more ticket lied."
    "Afternoon's for gnarly bugs."
    "Copy, paste, then pray."
    "Slump hits. Coffee back."
    "Standups are status theater."
    "My machine is enough."
    "99 bugs, ship anyway."
    "2pm fog. Caffeine wipers."
    "Pair up, fight slump."
    "Deploy after lunch. Brave."
    "Lunch powered the brain."
    "Legacy code bites now."
    "Machine lies. Code doesn't."
    "99 bugs, merge ain't one."
    "Slump is blood sugar."
    "Tab count is classified."
    "Momentum's a hill. Climb."
    "Meeting could've been email."
    "Lunch real. Motivation debatable."
    "Afternoon bug's sneakier."
    "It worked. Past tense."
    "99 down, thousands left."
    "Slump wants company. Refuse."
    "Copy with intent. Paste."
    "Brave or foolish refactors."
    "Inbox peaks at three."
    "Lunch ended. Keyboard waits."
    "Afternoon deploy, leap faith."
    "Works on machine. Ship machine."
    "99 bugs, plain sight."
    "2pm struggle is universal."
    "Answer's somewhere on SO."
    "Focus negotiates with slump."
    "Meeting ran long. Code?"
    "Lunch lied via stomach."
    "Tickets multiply after noon."
    "Machine's a server now."
    "99 bugs, one fix."
    "Slump temporary. Diff forever."
    "Paste, refactor, regret. Cycle."
    "Energy sponsored by sugar."
    "Decaf invented for 3pm."
    "Lunch powered nothing. Coffee?"
    "Pair review saves deploys."
    "Machine enough for me."
    "99 bugs, zero tests."
    "Slump hits. Playlist saves."
    "Downvoted but still correct."
    "Bugs morning-you missed."
    "Meeting could've been comment."
    "Lunch lied. Cookie real."
    "Marathon of small wins."
    "Machine's also my bed."
    "99 bugs, CI is red."
    "Brain fog's allegedly feature."
    "Paste, credit the internet."
    "Motivation: three more hours."
    "Deploy green. Touch nothing."
    "Lunch was the highlight."
    "Bug hunt needs snacks."
    "Make it work elsewhere."
    "99 bugs, one function."
    "Slump needs second coffee."
    "SO saved you. Thanks."
    "Undo refactors pre-standup."
    "Slump sponsored by carbs."
    "Lunch real. Focus fictional."
    "Earn morning's optimism now."
    "Prod disagrees with machine."
    "Tests were aspirational."
    "Slump can't argue playlists."
    "Hope license is fine."
    "Ship-it energy from tomorrow."
    "Meeting ended. Dread lingers."
    "Lie that kept coding."
    "Close tickets, not tabs."
    "Ship at own risk."
    "99 bugs, none documented."
    "Espresso exists for 2pm."
    "SO is your pair."
    "Deadlines loom. Type fast."
    "Window closing. Patience too."
    "Lunch gone. Bugs fresh."
    "Pair session unblocks all."
    "Machine's on fire. Ship."
    "Fix one, ship, cry."
  );;
  1[7-9]|2[0]) G_E="🌆"; G_MSGS=(
    "Ship before it ships you."
    "Evening grind. Stay sharp."
    "One feature. Then dinner."
    "Almost beer o'clock."
    "Refactor now, regret less."
    "Deploy will hold. Probably."
    "Evening energy: low, determined."
    "Window narrows. Decide fast."
    "Dinner waits. Diff waits."
    "Golden hour, green build."
    "Evening bug, morning problem."
    "One commit. Then food."
    "Evening refactors age poorly."
    "Inbox quiet. You too."
    "Almost quitting time. Almost."
    "Slow-burn evening sprint."
    "Deploy queued. Nerves live."
    "Dinner's cooking. Build too."
    "Stand-down is earned."
    "Almost beer o'clock. Close."
    "Evening clarity hits different."
    "Last ticket's the heaviest."
    "One feature. Log off."
    "Pair review saves tomorrow."
    "Golden light, golden PR."
    "Deploy holds. Usually."
    "Flat battery, full resolve."
    "Five more minutes. Always."
    "Evening's for closing loops."
    "Almost done. Almost."
    "Evening commits are bolder."
    "Inbox begs. Dinner wins."
    "One more test. Done."
    "Wind-down starts with save."
    "Golden hour, glowing keys."
    "Deploy's in prod's hands."
    "Grind music on. Quietly."
    "Dinner's cold. Merge warm."
    "Seniors appear in diffs."
    "Almost beer is best."
    "Focus is scarce, precious."
    "Last meeting ended. Work."
    "One push, then away."
    "Evening deploy is trust-fall."
    "Golden fades. TODO doesn't."
    "Deploy holds. Trust tests."
    "Grit dressed as calm."
    "Dinner first. Refactor never."
    "Fix you postponed today."
    "Almost done is devil's bar."
    "Commits should warn you."
    "Inbox sleeps. Don't wake."
    "One feature is lying."
    "Wind-down is a skill."
    "Golden hour, peak output."
    "Deploy held. Modest cheers."
    "Evening grind, morning glory."
    "Dinner's ready. Cursor knows."
    "Bug waits for eyes."
    "Almost beer. Resist merge."
    "Five percent, applied precisely."
    "Last review needs care."
    "One file. Then done."
    "Tidy commits, tidy minds."
    "Golden screen, green tick."
    "Deploy's out. Breath held."
    "Quiet but stubborn grit."
    "Dinner waits for no one."
    "Backlog whispers at dusk."
    "Almost quit. No refactor."
    "Moody code. Test twice."
    "Inbox closed. Laptop next."
    "One ticket is trap."
    "Wrap-up is head start."
    "Golden hour, golden patience."
    "Deploy held. Prayers worked."
    "Grind needs a plan."
    "Dinner calls. Push first."
    "Deploy you prepped today."
    "Almost done. Close it."
    "Focus is a candle."
    "Last hour's for wins."
    "One feature. Then feast."
    "Notes saved. Mind cleared."
    "Golden fades. Ship first."
    "Deploy live. Watch dashboard."
    "Energy runs on anticipation."
    "Inbox empty. Savor it."
    "One commit. Close lid."
    "Ship, don't start."
    "Golden glow, green show."
    "Deploy holds. It must."
    "Grit got feature shipped."
    "Dinner's reward. Diff's price."
    "Bug keeps. You won't."
    "Almost beer. Log off."
    "Commit, push, then breathe."
    "Last review helps tomorrow."
    "One file. Food. Real."
    "Evening ends. Work waits."
  );;
  2[1-3]) G_E="🌙"; G_MSGS=(
    "Wind down. Save file."
    "Good night. Push first."
    "Tomorrow-you says thanks."
    "Log off. Code waits."
    "Dream clean architecture."
    "Commit, push, sleep, repeat."
    "Night mode is engaged."
    "Save file. Save yourself."
    "Moon agrees: log off."
    "Standup needs tonight's sleep."
    "Push before you pillow."
    "Rest, don't regress."
    "Bug keeps. Sleep first."
    "Close laptop. Open night."
    "Commit, push, lights out."
    "Dream in clean diffs."
    "Night's for restoration."
    "Save state. Exit process."
    "Tomorrow-you is grateful."
    "Prod has night shift."
    "Wind-down's the final merge."
    "Push it. Then sleep."
    "Moonlit commit is last."
    "Close tabs. Rest brain."
    "Good night. Build green."
    "Blank branch. Sleep in."
    "Subconscious debugs at night."
    "Save work. Save day."
    "Bug stays put tonight."
    "Commit, push, dream, repeat."
    "Night mode is best."
    "Log off, clean tree."
    "Tomorrow-you thanks tonight-you."
    "Night's for rest, refactors."
    "Push branch. Pull covers."
    "Good night. CI watches."
    "Dream of green tests."
    "Moon says stop typing."
    "Save file. Long day."
    "Laptop cools down finally."
    "Commit work. Keep memories."
    "Tomorrow starts tonight's sleep."
    "Bug waits for breakfast."
    "Diffs dream themselves now."
    "Wind-down beats midnight heroics."
    "Push it. Rest fully."
    "Moonlit desk should empty."
    "Close IDE. Open quiet."
    "Good night. Cache holds."
    "Clarity costs tonight's rest."
    "Night runs ideas best."
    "Save, quit, sleep. Pray."
    "Servers own the night."
    "Commit so tomorrow understands."
    "Push code. Park brain."
    "Moon saw enough diffs."
    "Dim screen, pause ambition."
    "Log off. New context."
    "Bug keeps till coffee."
    "Close day like PR."
    "Tomorrow-you watches commit count."
    "Let the mind defrag."
    "Save progress. Surrender day."
    "Night's kind to resters."
    "Push, sleep, run tests."
    "Good night. Dashboard's fine."
    "Dream legacy-free code."
    "Moonlit save is last."
    "Close laptop. Code forgives."
    "Tonight's sleep builds tomorrow."
    "Burnout born or prevented."
    "Log off before temptation."
    "Work waits. Sleep won't."
    "Commit wins. Drop dread."
    "Push it. Leave it."
    "Night owes rest, not revelations."
    "Good night. Rollback ready."
    "Merge needs tonight's rest."
    "Brain in low-power mode."
    "Save file. Tuck project."
    "Moon approves your exit."
    "Close session. Keep learnings."
    "Standup waits. Pillow doesn't."
    "Log off. Dawn returns."
    "Night's for off switch."
    "Commit, push, close, sleep."
    "Push final branch today."
    "Prod's shift, not yours."
    "Good night. Leak tomorrow."
    "Dream zero open tickets."
    "Close lid. Open rest."
    "Better sleep, better code."
    "Soul recompiles at night."
    "Save all. Let go."
    "Bug files for tomorrow."
    "Hot deploy tonight: blanket."
    "Push, sleep, repeat wisely."
    "Good code waits rest."
    "Close day. Fresh window."
    "Ship nothing but dreams."
  );;
  *) G_E="✨"; G_MSGS=(
    "Keep going."
    "One line at time."
    "Next commit's the one."
    "Breathe. Then build."
    "Progress over perfection."
  );;
esac
G_N=${#G_MSGS[@]}
G_I=$(awk -v seed="$(( 10#$HOUR*1000 + 10#$DOY ))" -v n="$G_N" 'BEGIN{srand(seed+0); print int(rand()*n)}')
GREET="${SEP}${G_E} ${D}${G_MSGS[$G_I]}${X}"

# Special cat cameo — a rare, time-independent surprise that can pop at any hour.
# Only a cat emoji is ever shown here (never the section emoji); each line carries
# its own fitting cat emoji. ~1/16 chance per hour, deterministic by day-of-year +
# hour, so it's stable within the hour and varies day-to-day. Tweak the fraction
# to make the cat rarer or more frequent.
G_CAT_E=( 😺 😻 😹 😾 😼 🙀 😿 🐈 🐈‍⬛ 😸 😽 😹 😻 😾 😺 😼 🐈 😸 )
G_CAT_M=(
  "Paws on keyboard. Ship."
  "Deploy purred first try."
  "Cat knocked it off."
  "Merge conflict. Cat unimpressed."
  "Ship it. Cat doubts."
  "Prod's down. Cat's guilty."
  "Deploy failed. Cat mourns."
  "Cat walked keyboard. Feature."
  "Black cat cursed pointers."
  "Green build. Cat grins."
  "Merged clean. Cat kisses."
  "Bug fixed itself. Cat."
  "Review passed. Cat smitten."
  "Build red. Cat impatient."
  "Cat approved this commit."
  "Refactors judged. Cat silent."
  "Cat naps. So should you."
  "Squashed bug. Cat approves."
)
if awk -v seed="$(( 10#$DOY*31 + 10#$HOUR + 99999 ))" 'BEGIN{srand(seed); exit !(rand() < 1/16)}'; then
  _CN=${#G_CAT_M[@]}
  _CI=$(awk -v seed="$(( 10#$DOY*31 + 10#$HOUR + 99999 ))" -v n="$_CN" 'BEGIN{srand(seed+7); print int(rand()*n)}')
  GREET="${SEP}${G_CAT_E[$_CI]} ${D}${G_CAT_M[$_CI]}${X}"
fi

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

printf "%b" "🤖 ${B}${C}${MODEL}${X}${TAG}${SEP}📁 $(short "${DIR##*/}")${BRANCH}${SEP}${BAR}${X} ${PCT_INT}% ${CTX}${SEP}⏱️ ${T_FMT}${GREET}\n"
[ -n "$SUB_LINES" ] && printf '%b' "$SUB_LINES"
exit 0
