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
  0[0-4]) G_E="😴"; G_MSGS=(
    "Go to sleep. Bugs can wait."
    "It's late. Commit and log off."
    "Your bed misses you."
    "Late-night debugging is a trap."
    "Save your work. Then yourself."
    "Sleep is the best debugger."
    "The bug will still be here at noon."
    "2am you is not as smart as 2pm you."
    "Commit, push, and close the lid."
    "Your future self wants sleep, not commits."
    "Even the servers are yawning."
    "Dark mode can't hide how late it is."
    "That one-more-fix is a lie you tell at 3am."
    "The terminal's still glowing. You shouldn't be."
    "Bugs breed in the small hours."
    "Go to bed. The diff will keep."
    "Late-night code ages poorly."
    "Sleep debt compounds faster than technical debt."
    "The moon has seen enough of your stack traces."
    "Pivot to pillow."
    "Midnight genius is just tired."
    "Revert in the morning what you wrote tonight."
    "The cache of your patience is empty."
    "Night shift? More like night drift."
    "Your keyboard called. It's tired too."
    "Closed laptop, open bed."
    "Tomorrow's you will thank present's you for stopping."
    "The bug isn't going anywhere. You should."
    "Rewrites after midnight are regrets by sunrise."
    "Even grep needs rest."
    "Save state. Then save yourself."
    "The build can wait for breakfast."
    "Late-night confidence is a leading indicator of bugs."
    "Your pillow out-ranks your PR."
    "Dim the screen. Then close it."
    "The git log forgives. Your spine won't."
    "3am refactors are regret in draft form."
    "Ship nothing tonight. Sleep something."
    "Your eyes called it two hours ago."
    "The terminal isn't going anywhere. You are."
    "Closing tabs counts as progress."
    "The bug is patient. Be smarter: rest."
    "Darkness hides more bugs than it reveals."
    "Your merge will survive until morning."
    "The midnight oil is officially empty."
    "Stop typing. Start dreaming."
    "Even the linter is half-asleep."
    "You can't git revert a bad night's sleep."
    "The deploy button glows brighter at 3am. Don't trust it."
    "Save. Quit. Sleep. In that order."
    "Tomorrow is a feature you build tonight."
    "The bug isn't worth the bags under your eyes."
    "Late nights ship bugs in disguise."
    "Your bed filed a pull request for your presence."
    "Tired code is just bug habitat."
    "Rest is a valid commit message."
    "The night owls are lying to themselves."
    "Your coffee has given up."
    "Even the cursor blinks slower now."
    "Put the semicolon down."
    "The diff will outlive your alertness."
    "Sleep first. Refactor never."
    "Your stash is not a bedtime story."
    "The 3am fix is tomorrow's 3pm fire."
    "Bugs love an audience of one tired dev."
    "Close the laptop like you mean it."
    "The night is for restoration, not resolution."
    "Your future self is already dreading this commit."
    "Sleep is the only dependency you keep skipping."
    "The terminal hums. The bed calls. Choose wisely."
    "Late-night certainty is fatigue in a trench coat."
    "Your eyes deserve more than blue light."
    "Even prod is quieter than your brain right now."
    "The commit can wait for the sunrise."
    "Tuck the code in. Then yourself."
    "Your reflexes left at midnight."
    "The only hot thing at 3am should be cocoa."
    "Stop. Drop. Deploy tomorrow."
    "Your TODO list won't haunt you in your sleep."
    "Even the night shift has a shift end."
    "The bug will outlive tonight. Will your sanity?"
    "Save the heroic coding for a hero hour."
    "Your pillow's uptime is at zero. Fix it."
    "The darkness is for closing, not closing braces."
    "Tomorrow's standup doesn't need your 3am commits."
    "Even the loop needs an exit."
    "Your caffeine has clocked out."
    "The screen's last task is to turn off."
    "Late nights are interest on tomorrow's misery."
    "The bug isn't nocturnal. You're just stubborn."
    "Your brain's battery is at one percent. Plug into a pillow."
    "The night owes you nothing but sleep."
    "Close the issue. Open the bed."
    "Even midnight has a curfew."
    "Your code gets worse for every hour past midnight."
    "The only thing shipping tonight is you, to bed."
    "Rest is the most underrated runtime optimization."
    "The stack trace isn't going to tuck you in."
    "Be the dev who logs off."
    "Good night, truly."
  );;
  0[5-7]) G_E="🌅"; G_MSGS=(
    "Up with the sun. Or the rooster."
    "Dawn patrol. Let's ship."
    "Early code is fresh code."
    "The world is quiet. Use it."
    "Coffee: now mandatory."
    "Greet the day, then the terminal."
    "First light, first commit."
    "The early dev catches the clean merge."
    "Sunrise over the stack trace."
    "Fresh coffee, fresh context, fresh bugs."
    "The internet is still asleep. So is your inbox."
    "Morning brain is the only bug-free runtime."
    "Dew on the grass, tabs in the trash."
    "Rise and git pull."
    "The rooster crows. The linter wakes."
    "Quiet hours are shipping hours."
    "Brew the coffee, then the plan."
    "Dawn doesn't check Slack."
    "Early bird gets the green build."
    "The sun's up. So is your motivation."
    "Fresh IDE, fresh mind, fresh mistakes."
    "Mornings are for momentum."
    "The world boots up. So do you."
    "Catch the sunrise between commits."
    "Dawn patrol: fewer meetings, more magic."
    "Your code is crisp before the day heats up."
    "First sip, first script."
    "Early hours, zero interruptions, infinite possibility."
    "The birds are up. Match them."
    "Morning glow beats screen glow."
    "Coffee in hand, cursor in command."
    "The day hasn't asked you anything yet."
    "Dawn is the best pre-meeting."
    "Rise. Brew. Run dev."
    "Quiet morning, loud progress."
    "Early start, easy merge."
    "The sunrise doesn't need a status update."
    "Fresh start beats fresh bug."
    "Morning focus is uncut."
    "The dew agrees: today you'll ship."
    "First light, fewer fires."
    "The early shift skips the backlog."
    "Dawn is the only meeting-free hour."
    "Brew strong. Ship stronger."
    "Your willpower peaks with the sun."
    "The morning is yours before the calendar claims it."
    "Early commits age the best."
    "Sunrise side of the keyboard."
    "The world's still loading. Get ahead."
    "Morning energy is renewable. Use it now."
    "First cup, first-class functions."
    "Dawn doesn't do deadlines. Neither should you."
    "The early dev out-ships the late one."
    "Quiet dawn, clear diffs."
    "Rise with the sun, ride with the flow."
    "Morning is the best debug session."
    "The coffee is hot. The streak is live."
    "Dawn patrol ships before standup."
    "Early light, light cognitive load."
    "The day is a blank branch. Commit kindly."
    "Mornings are where focus lives before email kills it."
    "Sunrise sprint, no blockers yet."
    "Brew first. Refactor later."
    "The rooster's a better PM than your PM."
    "Early hours compound into shipped features."
    "Dawn is forgiving. The day isn't."
    "Quiet keys, loud results."
    "The morning hasn't met your bugs yet."
    "Rise, rinse, run tests."
    "First light is free focus."
    "The sun's up and so are your standards."
    "Morning momentum is the real framework."
    "Dawn: zero pings, maximum flow."
    "Early bird, clean working tree."
    "The coffee's brewing. So is your best work."
    "Mornings are unbothered. Be like mornings."
    "Sunrise sessions ship the gnarly stuff."
    "The day starts clean. Keep it that way."
    "Early hours are the meeting-free zone."
    "Dawn patrol clears the queue before it forms."
    "First light, fresh eyes on old bugs."
    "The morning is a gift. Don't spend it in Slack."
    "Rise early, merge early."
    "Coffee complete. Focus loading."
    "The early dev dodges the afternoon slump."
    "Dawn doesn't negotiate with your inbox."
    "Morning clarity is a superpower."
    "The sun rose. So did your throughput."
    "Early start, calm finish."
    "Quiet dawn, clean console."
    "The birds ship at sunrise. So can you."
    "Morning is the only time the bar is empty."
    "Dawn is for doers."
    "First light, first feature."
    "The coffee is calling and so is the cursor."
    "Rise. The bugs aren't ready for you."
    "Morning momentum beats midnight heroics."
    "The sun agrees with your roadmap."
    "Early and steady ships the product."
    "Dawn: shipped before the world wakes."
  );;
  0[89]|1[01]) G_E="☀️"; G_MSGS=(
    "Coffee first, dread later."
    "Good morning. Let's break things."
    "Fresh mind, fresh bugs."
    "Morning motivation: caffeine."
    "Today's bug, tomorrow's anecdote."
    "Let's build something weird."
    "Caffeine compiled. Ready to execute."
    "Morning meetings are the warm-up lap."
    "The build is green and so is your tea."
    "Today's goal: fewer alarms, more commits."
    "Second cup, second wind."
    "Morning energy: handle with code."
    "The standup approaches. Arm yourself."
    "Fresh eyes find yesterday's dumb mistakes."
    "Today's a good day to delete code."
    "Coffee is the original hot reload."
    "Morning motivation runs on beans."
    "The PR queue is warming up."
    "New day, same type system."
    "Morning focus is fragile but potent."
    "The inbox is awake. Pace yourself."
    "Today's feature is tomorrow's tech debt. Ship it anyway."
    "Morning clarity fades by 2pm. Use it."
    "The coffee's working. Are you?"
    "Fresh context loaded. Don't spend it on email."
    "Morning is for the hard problems."
    "The compiler is forgiving this morning."
    "Today's plan: ship, snack, repeat."
    "Morning momentum is a mostly renewable resource."
    "The standup won't stand itself."
    "Fresh brew, fresh ideas, fresh regret."
    "Morning you is optimistic. Don't waste it."
    "Today's bug report is tomorrow's story."
    "Coffee in, code out."
    "The keyboard is warm and so is the lead."
    "Morning is when the TODO list still feels doable."
    "Fresh mind, stale config, let's go."
    "Today we build. Tomorrow we debug. The cycle continues."
    "Morning pair programming: two brains, one coffee."
    "The sprint starts with a sip."
    "Morning energy is a limited-time offer."
    "Today's commits are tomorrow's git blame."
    "Coffee first, reviews second, meetings last."
    "The morning is when refactors feel wise."
    "Fresh log, clear mind, dirty keyboard."
    "Today's the day the bug finally gets squashed. Maybe."
    "Morning optimism is undefeated until the first failing test."
    "The caffeine is in. The blockers are out. Briefly."
    "Morning is for the ambitious. Afternoon is for the realistic."
    "Fresh start, same imposter syndrome."
    "Today, write the code past-you couldn't."
    "The build passes. Enjoy it while it lasts."
    "Morning is the brief window before scope creep."
    "Coffee makes the merge conflict bearable."
    "Today's a three-coffee kind of problem."
    "The morning is your most underrated dependency."
    "Fresh mind, same legacy code, new determination."
    "Today, be the dev you needed yesterday."
    "Morning focus is a currency. Spend it wisely."
    "The sprint board is hopeful this morning."
    "Coffee turns later into now."
    "Morning is when the docs almost make sense."
    "Today, the bug fears you."
    "The standup is a status report to yourself."
    "Morning pair: two cups, one cursor."
    "Fresh resolve, same recurring task."
    "Today's the day the type errors cooperate. Allegedly."
    "The morning meeting is a test of your caffeine."
    "Coffee charged. Patience loading."
    "Morning momentum is best spent on the scary ticket."
    "Today, merge like nobody's watching."
    "The inbox is loud. The code is louder."
    "Morning is for breaking things on purpose."
    "Fresh ideas need fresh grounds."
    "Today's goal: one fewer TODO than yesterday."
    "The compiler is in a good mood. So are you."
    "Morning clarity is free. Borrow it while it lasts."
    "Coffee is the duct tape of the morning."
    "Today, ship the thing you've been avoiding."
    "The morning is forgiving of bold refactors."
    "Fresh keyboard, same muscle memory."
    "Today's the day. It always is."
    "Morning energy peaks before the first meeting drains it."
    "The PRs are piling up. Brew accordingly."
    "Coffee first, courage second."
    "Morning is when tests feel worth writing."
    "Today, let the linter be your friend."
    "The standup is short. The sprint is long."
    "Fresh start, fresh branch, fresh hope."
    "Morning is the calm before the calendar."
    "Today, the diff is your canvas."
    "Coffee is the only dependency that never breaks."
    "Morning motivation is just caffeine with confidence."
    "The inbox can wait. The idea can't."
    "Today, write fewer lines and mean more."
    "Morning is the best time to delete a feature."
    "Fresh coffee, old bugs, new tactics."
    "The day's young. So is this branch."
    "Today's a good day to ask why that's there."
    "Morning. Let's make it count."
  );;
  1[2-6]) G_E="🌤️"; G_MSGS=(
    "99 little bugs in the code…"
    "Lunch was a lie. Keep coding."
    "Stack Overflow awaits."
    "It works on my machine 🤷"
    "Slump? Nopenope."
    "Ship it. Patch it later."
    "Post-lunch coma is a known issue with no patch."
    "The afternoon slump is real. So is the coffee."
    "99 little bugs, take one down, 127 little bugs."
    "It worked on my machine. It works in prod. Probably."
    "The 3pm slump is undefeated. Fight back."
    "Stack Overflow is the real senior dev."
    "Afternoon energy is borrowed, not owned."
    "The meeting that could've been a diff drags on."
    "Lunch was a lie. So was just one more ticket."
    "The afternoon is for the gnarly bugs."
    "Copy, paste, pray. The holy trinity."
    "The slump hits. The coffee hits back."
    "Afternoon standups are status theater."
    "It works on my machine, which is all that matters."
    "99 bugs in the code, ship it anyway."
    "The 2pm fog is thick. Caffeine is the wiper."
    "Afternoon pair programming fights the slump."
    "The deploy window opens after lunch. Brave."
    "Lunch powered the brain. Now use it."
    "The afternoon is when legacy code bites."
    "It works on my machine. The machine lies."
    "99 little bugs and a merge ain't one."
    "The slump is a state of mind. And blood sugar."
    "Stack Overflow tab count is classified."
    "Afternoon momentum is a hill. Keep climbing."
    "The 3pm meeting could've been an email. Again."
    "Lunch was real. The motivation is debatable."
    "The afternoon bug is sneakier than the morning one."
    "It works on my machine. It worked. Past tense."
    "99 bugs down, a thousand to go."
    "The slump wants company. Don't give it any."
    "Copy from Stack Overflow. Paste with intent."
    "Afternoon refactors are brave or foolish. Probably both."
    "The inbox hits peak chaos around 3pm."
    "Lunch is over. The keyboard misses you."
    "The afternoon deploy is a leap of faith."
    "It works on my machine. Ship the machine."
    "99 little bugs, hidden in plain sight."
    "The 2pm struggle is universal. So is the snack."
    "Stack Overflow has the answer. Somewhere."
    "Afternoon focus is a negotiation with the slump."
    "The meeting ran long. The code ran short."
    "Lunch was a lie told by your stomach."
    "The afternoon is when tickets multiply."
    "It works on my machine, which is a server now."
    "99 bugs, one fix, twelve new bugs."
    "The slump is temporary. The diff is forever."
    "Copy, paste, refactor, regret. The cycle."
    "Afternoon energy is brought to you by sugar."
    "The 3pm crash is why decaf was invented. Avoid it."
    "Lunch powered nothing. Coffee will."
    "The afternoon pair review saves the deploy."
    "It works on my machine, and that's enough for me."
    "99 little bugs, zero little tests."
    "The slump hits. The playlist saves."
    "Stack Overflow: downvoted, but correct."
    "The afternoon is for the bugs morning-you missed."
    "The meeting could've been a comment."
    "Lunch was a lie. The cookie was real."
    "The afternoon is a marathon of small wins."
    "It works on my machine, which is also my bed."
    "99 bugs and the CI is red."
    "The 2pm brain fog is allegedly a feature."
    "Copy, paste, and credit the internets."
    "Afternoon motivation: just three more hours."
    "The deploy is green. Touch nothing."
    "Lunch was the highlight. Sorry."
    "The afternoon bug hunt needs snacks and silence."
    "It works on my machine. Now make it work on theirs."
    "99 little bugs, all in your function."
    "The slump is why the second coffee exists."
    "Stack Overflow saved you. Thank it silently."
    "Afternoon refactors should be undone before standup."
    "The 3pm slump is sponsored by carbohydrates."
    "Lunch was real. The focus is fictional."
    "The afternoon is when you earn the morning's optimism."
    "It works on my machine. The prod environment disagrees."
    "99 little bugs, the tests were aspirational."
    "The slump can't argue with a good playlist."
    "Copy, paste, and hope the license is fine."
    "Afternoon ship-it energy is borrowed from tomorrow."
    "The meeting ended. The dread lingers."
    "Lunch was the lie that kept you coding."
    "The afternoon is for closing tickets, not opening tabs."
    "It works on my machine. Ship at your own risk."
    "99 little bugs, none of them documented."
    "The 2pm slump is why espresso exists."
    "Stack Overflow is your pair programmer now."
    "Afternoon deadlines approach. Type furiously."
    "The deploy window is closing. So is your patience."
    "Lunch was hours ago. The bugs are fresh."
    "The afternoon pair session unblocks everything."
    "It works on my machine, which is on fire."
    "99 little bugs. Fix one, ship, and cry."
  );;
  1[7-9]|2[0]) G_E="🌆"; G_MSGS=(
    "Ship it before it ships you."
    "Evening grind. Stay sharp."
    "One more feature. Then dinner."
    "Almost beer o'clock."
    "Refactor now, regret less."
    "The deploy will hold. Probably."
    "Evening energy is low but determined."
    "The deploy window narrows. Decide fast."
    "Dinner awaits. The diff can wait."
    "Golden hour, green build."
    "The evening bug is tomorrow's morning problem."
    "One more commit. Then food. Promise."
    "Evening refactors age into morning regrets."
    "The inbox is finally quiet. So are you."
    "Almost quitting time. Almost."
    "Evening grind is the slow-burn sprint."
    "The deploy is queued. The nerves are live."
    "Dinner's in the oven. The build's in the queue."
    "The evening stand-down is earned."
    "Almost beer o'clock. So close."
    "Evening clarity hits different."
    "The last ticket of the day is the heaviest."
    "One more feature, then log off. Probably."
    "The evening pair review saves tomorrow."
    "Golden hour light, golden PR."
    "The deploy will hold. It usually does."
    "Evening energy is a flat battery with resolve."
    "Dinner can wait five more minutes. It always does."
    "The evening is for closing loops."
    "Almost done. Almost. Almost."
    "Evening commits are bolder. Risk accordingly."
    "The inbox begs. The dinner bell wins."
    "One more test. Then truly done."
    "The evening wind-down starts with a save."
    "Golden hour, the keyboard glows."
    "The deploy is in prod's hands now."
    "Evening grind music is on. Volume is appropriate."
    "Dinner's getting cold. The merge is getting warm."
    "The evening is when senior devs appear in the diff."
    "Almost beer o'clock is the best o'clock."
    "Evening focus is scarcer and more precious."
    "The last meeting ended. Now the real work."
    "One more push, then push away from the desk."
    "The evening deploy is a trust fall."
    "Golden hour fades. The TODO list doesn't."
    "The deploy will hold. Trust the tests. Trust them."
    "Evening energy is grit dressed as calm."
    "Dinner first. Refactor never."
    "The evening is for the fix you put off all day."
    "Almost done is the devil's progress bar."
    "Evening commits should come with a warning."
    "The inbox is asleep. Don't wake it."
    "One more feature is a lie evening-you tells."
    "The evening wind-down is a skill. Practice it."
    "Golden hour productivity is undefeated."
    "The deploy held. Celebrate modestly."
    "Evening grind, morning glory."
    "Dinner's ready. The cursor understands."
    "The evening bug is best left for fresh eyes."
    "Almost beer o'clock. Resist the merge."
    "Evening energy is five percent, applied precisely."
    "The last review of the day deserves care."
    "One more file. Just one. Then done."
    "The evening is for tidy commits and tidy minds."
    "Golden hour on the screen, green tick on the build."
    "The deploy is out. The breath is held."
    "Evening determination is quiet but stubborn."
    "Dinner waits for no dev. Mostly."
    "The evening is when the backlog whispers."
    "Almost quitting time. Don't start the big refactor."
    "Evening code is moodier. Test it twice."
    "The inbox is closed. The laptop is next."
    "One more ticket is a trap dressed as progress."
    "The evening wrap-up is tomorrow's head start."
    "Golden hour, golden patience."
    "The deploy held. The prayers worked."
    "Evening grind is best paired with a plan."
    "Dinner is calling. Git push and go."
    "The evening is for the deploy you prepped all day."
    "Almost done. Close the laptop like you mean it."
    "Evening focus is a candle. Guard it."
    "The last hour is for the wins, not the wars."
    "One more feature, then we feast."
    "The evening stand-down: notes saved, mind cleared."
    "Golden hour fades. Ship before it does."
    "The deploy is live. Watch the dashboard, not your fears."
    "Evening energy runs on dinner anticipation."
    "The inbox is empty. Savor it."
    "One more commit, then close the lid for real."
    "The evening is for shipping, not starting."
    "Golden hour glow, green build show."
    "The deploy will hold. It has to."
    "Evening grit got the feature over the line."
    "Dinner is the reward. The diff was the price."
    "The evening bug will keep. You won't."
    "Almost beer o'clock. Log off first."
    "Evening wind-down: commit, push, breathe."
    "The last review of the day makes tomorrow easier."
    "One more file. Then food. For real this time."
    "The evening ends. The work waits patiently."
  );;
  2[1-3]) G_E="🌙"; G_MSGS=(
    "Wind down. Save the file."
    "Good night. Push first."
    "Tomorrow-you thanks present-you."
    "Log off. The code will wait."
    "Dream in clean architecture."
    "Commit, push, sleep. Repeat."
    "Night mode is engaged."
    "Save the file. Save yourself."
    "The moon agrees: log off."
    "Tomorrow's standup needs tonight's sleep."
    "Push before you pillow."
    "Night is for rest, not regress."
    "The bug will keep. Your sleep shouldn't wait."
    "Close the laptop. Open the night."
    "Commit, push, lights out."
    "Dream in clean diffs."
    "The night is for restoration."
    "Save state. Exit process."
    "Tomorrow-you is already grateful."
    "Log off. The prod server has the night shift."
    "Night wind-down is the day's final merge."
    "Push it real good. Then sleep."
    "The moonlit commit is the last one."
    "Close the tabs. Rest the brain."
    "Good night. The build is green."
    "Tomorrow's a blank branch. Sleep into it."
    "Night is when the subconscious debugs."
    "Save the work. Save the day."
    "The bug isn't going anywhere tonight."
    "Commit, push, dream, repeat."
    "Night mode is the best mode."
    "Log off with a clean working tree."
    "Tomorrow-you thanks tonight-you, again."
    "The night belongs to rest, not refactors."
    "Push the branch. Pull the covers."
    "Good night. The CI will watch the build."
    "Dream of green tests and clean merges."
    "The moon says stop typing."
    "Save the file. It's been a long day."
    "Night is when the laptop finally cools down."
    "Commit the work. Keep the memories."
    "Tomorrow's you starts with tonight's sleep."
    "The bug can wait for breakfast."
    "Log off. The diffs will dream themselves."
    "Night wind-down beats midnight heroics."
    "Push it. Then genuinely rest."
    "The moonlit desk should be empty by now."
    "Close the IDE. Open the quiet."
    "Good night. The cache will hold."
    "Tomorrow's clarity costs tonight's rest. Pay it."
    "Night is the best runtime for ideas."
    "Save, quit, sleep: the dev's prayer."
    "The night shift belongs to the servers."
    "Commit with a message tomorrow-you will understand."
    "Push the code. Park the brain."
    "The moon has seen enough diffs."
    "Night mode: screen dimmed, ambition paused."
    "Log off. Tomorrow's a new context."
    "The bug will keep until the coffee returns."
    "Close the day like you close a PR: clean."
    "Tomorrow-you is watching tonight's commit count."
    "Night is for letting the mind defrag."
    "Save the progress. Surrender the day."
    "The night is kind to devs who rest."
    "Push, sleep, and let the tests run."
    "Good night. The dashboard will be fine."
    "Dream of a codebase with no legacy."
    "The moonlit save is the last save."
    "Close the laptop. The code forgives."
    "Tomorrow's energy is built tonight, in bed."
    "Night is when burnout is born or prevented."
    "Log off before the bug tempts you back."
    "The work will wait. Your sleep won't negotiate."
    "Commit the wins. Discard the dread."
    "Push it. Then leave it."
    "The night owes you rest, not revelations."
    "Good night. The rollback is ready if not."
    "Tomorrow's merge needs tonight's rest."
    "Night mode: brain in low-power state."
    "Save the file. Tuck in the project."
    "The moon approves of your exit."
    "Close the session. Keep the learnings."
    "Tomorrow's standup can wait. Your pillow can't."
    "Log off. The terminal will be here at dawn."
    "The night is for the off switch."
    "Commit, push, close, sleep: the loop of a wise dev."
    "Push the final branch of the day."
    "The night shift is for prod, not you."
    "Good night. The memory leak will be found tomorrow."
    "Dream of zero open tickets."
    "Close the lid. Open the rest."
    "Tomorrow-you will write better code on better sleep."
    "Night is when the soul recompiles."
    "Save everything. Then let it go."
    "The bug filed itself to bother you tomorrow."
    "Log off. The only hot deploy tonight is the blanket."
    "Push, sleep, repeat, wisely."
    "The moon says good code can wait for good rest."
    "Close the day. Tomorrow's a fresh context window."
    "Good night. Ship nothing but dreams."
  );;
  *) G_E="✨"; G_MSGS=(
    "Keep going."
    "One line at a time."
    "The next commit is the one."
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
  "Paws on the keyboard. Ship it anyway."
  "The deploy purred on the first try."
  "It works on my machine. The cat knocked it off."
  "Merge conflict. The cat is unimpressed."
  "Ship it, they said. The cat doubts it."
  "Production is down. The cat knocked over the rack."
  "The deploy failed. The cat mourns your uptime."
  "A cat walked across the keyboard. New feature unlocked."
  "The black cat cursed your null pointers."
  "Green build. The cat grins with you."
  "Merged clean. The cat sends kisses."
  "The bug fixed itself. The cat claims credit."
  "Code review passed. The cat is smitten."
  "The build is red. So is the cat's patience."
  "The cat approved this commit."
  "Late-night refactors. The cat judges silently."
  "The cat naps on the warm laptop. So should you, briefly."
  "Squashed the bug. The cat approves."
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

printf "%b" "🤖 ${B}${C}${MODEL}${X}${TAG}${SEP}📁 ${DIR##*/}${BRANCH}${SEP}${BAR}${X} ${PCT_INT}% ${CTX}${SEP}⏱️ ${T_FMT}${GREET}\n"
[ -n "$SUB_LINES" ] && printf '%b' "$SUB_LINES"
exit 0
