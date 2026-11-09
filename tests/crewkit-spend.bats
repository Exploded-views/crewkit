#!/usr/bin/env bats
# The registry holder's spend cap (the phase-1 plan's Task 18c), the part that stands alone:
# libexec/ck/spend.sh, a sourced library of integer-cent arithmetic and a small state file.
# The holder's loop, `status` and `doctor` call it once their branches land.

# shellcheck disable=SC2016  # dollar signs in the expected text are literal

bats_require_minimum_version 1.5.0
load helpers
load crewkit-helpers

# 2026-10-01 00:00:00 UTC, and the first of November: October is 31 days (2678400 s).
OCT=1790812800
NOV=1793491200
DAY=86400

setup() {
  ck_setup
  ck_lib
  # shellcheck source=/dev/null
  source "$TREE/libexec/ck/spend.sh"
  STATE="$BATS_TEST_TMPDIR/holder-spend.state"
}

# run_for DAYS: tick the state every six hours for DAYS days from the first of October (six hours
# is the gap allowed between ticks here), and once more in the last second.
run_for() {
  local t=$OCT end=$((OCT + $1 * DAY))
  ck_spend_tick "$STATE" "$t" 21600
  while ((t + 21600 < end)); do t=$((t + 21600)); ck_spend_tick "$STATE" "$t" 21600; done
  ck_spend_tick "$STATE" $((end - 1)) 21600
}

# ---- money ---------------------------------------------------------------------------------------

@test "a price is read as whole cents" {
  [ "$(ck_spend_cents 4.99)" = 499 ]
  [ "$(ck_spend_cents 5)" = 500 ]
  [ "$(ck_spend_cents 5.5)" = 550 ]
  [ "$(ck_spend_cents 0.07)" = 7 ]
}

@test "anything that is not a plain decimal price is refused" {
  local v
  for v in '' abc -1 1.234 1. .5 '1 2' '$5' 1e3 100000; do
    run ck_spend_cents "$v"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
  done
}

@test "cents are shown as dollars" {
  [ "$(ck_spend_fmt 499)" = '$4.99' ]
  [ "$(ck_spend_fmt 500)" = '$5.00' ]
  [ "$(ck_spend_fmt 7)" = '$0.07' ]
  [ "$(ck_spend_fmt 0)" = '$0.00' ]
}

# ---- the cap setting -----------------------------------------------------------------------------

@test "the cap is five dollars unless registry.spend_cap_usd says otherwise" {
  [ "$(ck_spend_cap_cents)" = 500 ]
  user_setting registry.spend_cap_usd:7.25
  [ "$(ck_spend_cap_cents)" = 725 ]
}

@test "a cap that is not a price is refused, not read as zero or unlimited" {
  user_setting registry.spend_cap_usd:lots
  run ck_spend_cap_cents
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "a project file cannot raise the cap" {
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  printf -- '---\nregistry.spend_cap_usd: 500\n---\n' > "$BATS_TEST_TMPDIR/proj/crewkit.local.md"
  cd "$BATS_TEST_TMPDIR/proj"
  [ "$(ck_spend_cap_cents)" = 500 ]
}

# ---- a machine price over the cap ----------------------------------------------------------------

@test "a monthly price over the cap is refused at start (78)" {
  run ck_spend_check_price 10 500
  [ "$status" -eq 78 ]
}

@test "a monthly price equal to the cap, or under it, is accepted" {
  ck_spend_check_price 5 500
  ck_spend_check_price 3.59 500
}

@test "a monthly price of zero is refused (78): it would never reach any cap" {
  run ck_spend_check_price 0 500
  [ "$status" -eq 78 ]
  run ck_spend_check_price 0.00 500
  [ "$status" -eq 78 ]
}

@test "a monthly price that is not a price is refused (78)" {
  run ck_spend_check_price banana 500
  [ "$status" -eq 78 ]
  run ck_spend_check_price '' 500
  [ "$status" -eq 78 ]
}

# ---- the estimate: price times the fraction of the month run -------------------------------------

@test "the estimate is the monthly price times the fraction of the month run" {
  run_for 31   # all of October, ticked every six hours
  [ "$(ck_spend_estimate_cents "$STATE" 1000 $((OCT + 31 * DAY - 1)))" -ge 999 ]
  [ "$(ck_spend_estimate_cents "$STATE" 1000 $((OCT + 31 * DAY - 1)))" -le 1000 ]
}

@test "ten days run in a 31-day month is ten thirty-firsts of the price" {
  run_for 10
  local c; c=$(ck_spend_estimate_cents "$STATE" 3100 $((OCT + 10 * DAY)))
  [ "$c" -ge 999 ]
  [ "$c" -le 1000 ]
}

@test "a gap in the ticks (the holder was stopped) is not counted as running" {
  ck_spend_tick "$STATE" "$OCT"
  ck_spend_tick "$STATE" $((OCT + 600))
  ck_spend_tick "$STATE" $((OCT + 10 * DAY))   # ten days with no tick between
  local c; c=$(ck_spend_estimate_cents "$STATE" 3100 $((OCT + 10 * DAY)))
  [ "$c" -lt 20 ]
}

@test "a new month starts again from zero" {
  run_for 10
  ck_spend_tick "$STATE" "$NOV"
  [ "$(ck_spend_estimate_cents "$STATE" 3100 "$NOV")" = 0 ]
}

# a price of 2678400 cents makes the estimate equal the seconds counted in a 31-day month
BIG=2678400

@test "a clock that goes backwards adds nothing and does not wipe the count" {
  ck_spend_tick "$STATE" "$OCT"
  ck_spend_tick "$STATE" $((OCT + 600)) 7200
  ck_spend_tick "$STATE" "$OCT"
  [ "$(ck_spend_estimate_cents "$STATE" "$BIG" "$OCT")" = 600 ]
}

@test "a clock that jumped forward and was corrected counts again from the corrected time" {
  ck_spend_tick "$STATE" "$OCT"
  ck_spend_tick "$STATE" $((OCT + 5 * DAY))          # a jump: the gap cap adds 900
  ck_spend_tick "$STATE" $((OCT + 1000))             # corrected: adds nothing
  ck_spend_tick "$STATE" $((OCT + 1600))             # real time again: +600
  [ "$(ck_spend_estimate_cents "$STATE" "$BIG" $((OCT + 1600)))" = 1500 ]
}

@test "a lost state file counts the holder as running since the first of the month" {
  [ "$(ck_spend_estimate_cents "$STATE" "$BIG" $((OCT + 2 * DAY)))" = $((2 * DAY)) ]
  ck_spend_tick "$STATE" $((OCT + 2 * DAY))
  [ "$(ck_spend_estimate_cents "$STATE" "$BIG" $((OCT + 2 * DAY)))" = $((2 * DAY)) ]
}

@test "a malformed state file is charged as a whole month so far, and never run as code" {
  printf 'seconds=$(touch %s/pwned)\nmonth=;\n' "$BATS_TEST_TMPDIR" > "$STATE"
  ck_spend_tick "$STATE" $((OCT + DAY))
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
  [ "$(ck_spend_estimate_cents "$STATE" "$BIG" $((OCT + DAY)))" = "$DAY" ]
}

@test "a state file with a line it does not know is not half trusted" {
  printf 'month=2026-10\nseconds=500\nlast=%d\nalerted=0\njunk=1\n' "$OCT" > "$STATE"
  [ "$(ck_spend_estimate_cents "$STATE" "$BIG" "$OCT")" = 0 ]
  printf 'month=2026-10\nseconds=500\nlast=%d\nalerted=0\njunk=1\n' "$OCT" > "$STATE"
  [ "$(ck_spend_estimate_cents "$STATE" "$BIG" $((OCT + 1000)))" = 1000 ]
}

@test "a state file missing a key is not trusted" {
  printf 'month=2026-10\nseconds=500\nlast=%d\n' "$OCT" > "$STATE"
  [ "$(ck_spend_estimate_cents "$STATE" "$BIG" $((OCT + 1000)))" = 1000 ]
}

@test "a state file whose last line has no newline is still read" {
  printf 'month=2026-10\nseconds=500\nlast=%d\nalerted=0' "$OCT" > "$STATE"
  [ "$(ck_spend_estimate_cents "$STATE" "$BIG" "$OCT")" = 500 ]
}

@test "a seconds count past the length of the month is held to the month" {
  printf 'month=2026-10\nseconds=999999999999\nlast=%d\nalerted=0\n' "$OCT" > "$STATE"
  [ "$(ck_spend_estimate_cents "$STATE" 1000 "$OCT")" = 1000 ]
}

@test "a state file is private and leaves no temp file behind" {
  ck_spend_tick "$STATE" "$OCT"
  [ "$(stat -c %a "$STATE" 2>/dev/null || stat -f %Lp "$STATE")" = 600 ]
  local left=("$STATE".*)
  [ ! -e "${left[0]}" ]
}

@test "a time that is not a whole number is refused, and writes nothing" {
  run ck_spend_tick "$STATE" ''
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ ! -e "$STATE" ]
  run ck_spend_tick "$STATE" "$OCT" abc
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ ! -e "$STATE" ]
  run ck_spend_estimate_cents "$STATE" 1000 abc
  [ "$status" -ne 0 ]
}

# ---- the month ---------------------------------------------------------------------------------

@test "the length and start of a month, across leap years and short months" {
  [ "$(ck_sp_month 950616000)" = '2000-02 29 949363200' ]    # 2000 is a leap year
  [ "$(ck_sp_month 4106376000)" = '2100-02 28 4105123200' ]  # 2100 is not
  [ "$(ck_sp_month 1707998400)" = '2024-02 29 1706745600' ]
  [ "$(ck_sp_month 1789473600)" = '2026-09 30 1788220800' ]  # a 30-day month
  [ "$(ck_sp_month 1797336000)" = '2026-12 31 1796083200' ]
  [ "$(ck_sp_month "$OCT")" = "2026-10 31 $OCT" ]
  [ "$(ck_sp_month $((NOV - 1)))" = "2026-10 31 $OCT" ]
}

# ---- the level -----------------------------------------------------------------------------------

@test "under 80% of the cap is ok, 80% is an alert, 100% is capped" {
  [ "$(ck_spend_level 399 500)" = ok ]
  [ "$(ck_spend_level 400 500)" = alert ]
  [ "$(ck_spend_level 499 500)" = alert ]
  [ "$(ck_spend_level 500 500)" = capped ]
  [ "$(ck_spend_level 9999 500)" = capped ]
}

@test "the higher of Fly's figure and the estimate decides, and the source is named" {
  run ck_spend_decide 300 450 500
  [ "$output" = "alert fly 450" ]
  run ck_spend_decide 450 300 500
  [ "$output" = "alert estimated 450" ]
}

@test "with no Fly figure, the estimate decides, marked estimated" {
  run ck_spend_decide 120 '' 500
  [ "$output" = "ok estimated 120" ]
}

@test "a failed Fly read is never read as zero spend" {
  run ck_spend_decide 450 abc 500
  [ "$output" = "alert estimated 450" ]
  run ck_spend_decide 600 -5 500
  [ "$output" = "capped estimated 600" ]
}

@test "a cap or a spend that is not a number is capped, never ok" {
  run ck_spend_level 9999 ''
  [ "$status" -ne 0 ]
  [ "$output" = capped ]
  run ck_spend_level '' 500
  [ "$output" = capped ]
  run ck_spend_decide '' '' 500
  [ "$status" -ne 0 ]
  [ "$output" = 'capped estimated 0' ]
  run ck_spend_decide 100 '' x
  [ "$output" = 'capped estimated 0' ]
}

@test "a price checked against a cap that is not a number is refused (78)" {
  run ck_spend_check_price 10 ''
  [ "$status" -eq 78 ]
  run ck_spend_check_price 10 abc
  [ "$status" -eq 78 ]
}

@test "prices with a leading zero are read as decimal, not octal" {
  [ "$(ck_spend_cents 08)" = 800 ]
  [ "$(ck_spend_cents 09.09)" = 909 ]
  [ "$(ck_spend_fmt 08)" = '$0.08' ]
  ck_spend_check_price 08 900
}

@test "a sum of money that is not a number cannot be shown" {
  run ck_spend_fmt -5
  [ "$status" -ne 0 ]
  run ck_spend_fmt ''
  [ "$status" -ne 0 ]
}

# ---- one alert a month ---------------------------------------------------------------------------

@test "80% sends one alert a month, not one per check" {
  local log="$BATS_TEST_TMPDIR/alerts"
  : > "$log"
  ck_spend_tick "$STATE" "$OCT"
  ck_spend_alert_once "$STATE" "echo alert >> $log" "$OCT"
  ck_spend_alert_once "$STATE" "echo alert >> $log" "$OCT"
  ck_spend_alert_once "$STATE" "echo alert >> $log" "$OCT"
  [ "$(wc -l < "$log" | tr -d ' ')" = 1 ]
}

@test "the alert is sent again in the next month" {
  local log="$BATS_TEST_TMPDIR/alerts"
  : > "$log"
  ck_spend_tick "$STATE" "$OCT"
  ck_spend_alert_once "$STATE" "echo alert >> $log" "$OCT"
  ck_spend_tick "$STATE" "$NOV"
  ck_spend_alert_once "$STATE" "echo alert >> $log" "$NOV"
  [ "$(wc -l < "$log" | tr -d ' ')" = 2 ]
}

@test "an alert command that fails is tried again at the next check" {
  local log="$BATS_TEST_TMPDIR/alerts"
  : > "$log"
  ck_spend_tick "$STATE" "$OCT"
  run ck_spend_alert_once "$STATE" "echo try >> $log; false" "$OCT"
  [ "$status" -ne 0 ]
  run ck_spend_alert_once "$STATE" "echo try >> $log; false" "$OCT"
  [ "$(wc -l < "$log" | tr -d ' ')" = 2 ]
}

@test "with no alert command set, nothing runs and the month is not marked as alerted" {
  ck_spend_tick "$STATE" "$OCT"
  ck_spend_alert_once "$STATE" '' "$OCT"
  run ! grep -q '^alerted=1' "$STATE"
}

@test "a state from another month is not evidence about this month's alert" {
  : > "$BATS_TEST_TMPDIR/alerts"
  ck_spend_tick "$STATE" "$OCT"
  run ck_spend_alert_once "$STATE" "echo alert >> $BATS_TEST_TMPDIR/alerts" "$NOV"
  [ "$status" -ne 0 ]
  [ ! -s "$BATS_TEST_TMPDIR/alerts" ]
}

@test "an alert for October still runs after the clock jumped into November and came back" {
  : > "$BATS_TEST_TMPDIR/alerts"
  ck_spend_tick "$STATE" "$OCT"
  ck_spend_tick "$STATE" "$NOV"
  ck_spend_alert_once "$STATE" "echo alert >> $BATS_TEST_TMPDIR/alerts" $((OCT + 700))
  [ "$(wc -l < "$BATS_TEST_TMPDIR/alerts" | tr -d ' ')" = 1 ]
}

@test "an alert with no state sends nothing and says so" {
  : > "$BATS_TEST_TMPDIR/alerts"
  run ck_spend_alert_once "$STATE" "echo alert >> $BATS_TEST_TMPDIR/alerts" "$OCT"
  [ "$status" -ne 0 ]
  [ ! -s "$BATS_TEST_TMPDIR/alerts" ]
}

@test "a time with a leading zero is read as decimal, not octal" {
  ck_spend_tick "$STATE" "0$OCT"
  grep -q "^last=$OCT$" "$STATE"
  [ "$(ck_spend_estimate_cents "$STATE" "$BIG" "0$OCT")" = 0 ]
  ck_spend_tick "$STATE" $((OCT + 600)) 0900
  [ "$(ck_spend_estimate_cents "$STATE" "$BIG" $((OCT + 600)))" = 600 ]
}

@test "a rollover charges the new month's share of the gap since the last tick" {
  printf 'month=2026-09\nseconds=500\nlast=%d\nalerted=1\n' "$((OCT - 100))" > "$STATE"
  ck_spend_tick "$STATE" $((OCT + 700))
  # 700 s of October have passed, 800 since the last tick: the new month is charged its 700
  [ "$(ck_spend_estimate_cents "$STATE" "$BIG" $((OCT + 700)))" = 700 ]
  grep -q '^alerted=0$' "$STATE"
}

@test "a rollover's share of the gap is held to the gap cap, and to the time since the last tick" {
  printf 'month=2026-09\nseconds=500\nlast=%d\nalerted=0\n' "$((OCT - 100))" > "$STATE"
  ck_spend_tick "$STATE" $((OCT + 700)) 300
  [ "$(ck_spend_estimate_cents "$STATE" "$BIG" $((OCT + 700)))" = 300 ]
  printf 'month=2026-09\nseconds=500\nlast=%d\nalerted=0\n' "$((OCT - 100))" > "$STATE"
  ck_spend_tick "$STATE" $((OCT + 50))
  [ "$(ck_spend_estimate_cents "$STATE" "$BIG" $((OCT + 50)))" = 50 ]
}

@test "a rollover after a long silence charges the gap cap, not the whole silence" {
  printf 'month=2026-09\nseconds=500\nlast=%d\nalerted=0\n' "$((OCT - 5 * DAY))" > "$STATE"
  ck_spend_tick "$STATE" $((OCT + 2 * DAY))
  [ "$(ck_spend_estimate_cents "$STATE" "$BIG" $((OCT + 2 * DAY)))" = 900 ]
}

@test "the next month's alert still goes out after the clock jumped ahead and came back" {
  : > "$BATS_TEST_TMPDIR/alerts"
  local cmd="echo alert >> $BATS_TEST_TMPDIR/alerts"
  ck_spend_tick "$STATE" "$OCT"
  ck_spend_tick "$STATE" "$NOV"                       # the clock jumps into November
  ck_spend_alert_once "$STATE" "$cmd" "$NOV"          # an alert goes out there
  ck_spend_tick "$STATE" $((OCT + 700))               # and comes back to October
  ck_spend_tick "$STATE" $((NOV + 600))               # real November arrives
  ck_spend_alert_once "$STATE" "$cmd" $((NOV + 600))
  [ "$(wc -l < "$BATS_TEST_TMPDIR/alerts" | tr -d ' ')" = 2 ]
}

@test "a clock that goes back never moves the month back or lowers the count" {
  ck_spend_tick "$STATE" "$OCT"
  ck_spend_tick "$STATE" "$NOV"
  ck_spend_tick "$STATE" $((NOV + 600)) 7200          # 600 s counted, in the month the clock jumped to
  ck_spend_tick "$STATE" $((OCT + 700))               # the clock goes back to October
  grep -q '^month=2026-11$' "$STATE"
  [ "$(ck_spend_estimate_cents "$STATE" "$BIG" $((OCT + 700)))" = 600 ]
}

@test "a clock that steps back across midnight for one tick and returns does not wipe the count" {
  local d19=$((19 * DAY))
  printf 'month=2026-11\nseconds=%d\nlast=%d\nalerted=1\n' "$d19" $((NOV + d19)) > "$STATE"
  ck_spend_tick "$STATE" $((NOV - 300))                # a wrong clock: last night, October
  ck_spend_tick "$STATE" $((NOV + d19 + 60))           # and the right one again
  [ "$(ck_spend_estimate_cents "$STATE" "$BIG" $((NOV + d19 + 60)))" -ge "$d19" ]
}

@test "the alert flag is reset on a tick that crosses a month, in either direction" {
  printf 'month=2026-11\nseconds=100\nlast=%d\nalerted=1\n' $((NOV + 100)) > "$STATE"
  ck_spend_tick "$STATE" $((NOV - 300))                # back across the boundary
  grep -q '^alerted=0$' "$STATE"
  printf 'month=2026-11\nseconds=100\nlast=%d\nalerted=1\n' $((OCT + 100)) > "$STATE"
  ck_spend_tick "$STATE" $((NOV + 100))                # forward across it, into the month the state names
  grep -q '^alerted=0$' "$STATE"
}

@test "an alert flag is kept by ticks that stay inside one month" {
  printf 'month=2026-11\nseconds=100\nlast=%d\nalerted=1\n' $((NOV + 100)) > "$STATE"
  ck_spend_tick "$STATE" $((NOV + 700))
  grep -q '^alerted=1$' "$STATE"
}

@test "a rollover from a state whose last tick is in the future charges nothing, not a negative count" {
  printf 'month=2026-09\nseconds=500\nlast=%d\nalerted=0\n' "$NOV" > "$STATE"
  ck_spend_tick "$STATE" $((OCT + 700))
  grep -q '^seconds=0$' "$STATE"
}
