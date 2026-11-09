# shellcheck shell=bash
# spend.sh: what the registry holder costs, and when to say so. Sourced after lib/settings.sh.
#
# The holder runs on a metered host. Fly documents no hard spend limit, so the cap is an estimate
# made here: the machine's monthly price (set by its owner at creation) times the fraction of the
# month the holder has run. The holder ticks once a loop; a tick adds the time since the last one,
# at most MAXGAP seconds, so time without ticks is not counted. Money is whole cents throughout.
#
# Every doubt reads as MORE spend, never less:
#   - a missing, unreadable or malformed state file counts the holder as having run since the first
#     of the month (a well-formed file from an earlier month is a normal rollover: the new month
#     starts with its share of the gap since the last tick);
#   - a cap, a spend or a clock that is not a whole number is "capped" (or refused), never ok;
#   - a clock that goes back adds nothing and never lowers the count or moves the month back; the
#     count starts again only when the clock passes the highest month seen, and the new month is
#     charged its own share of the gap since the last tick (at most MAXGAP); a tick that crosses a
#     month boundary from the last tick resets the alert flag.
#
# The state file is key=value lines (month, seconds, last, alerted), read with fixed patterns and
# never sourced. Keep it where it survives the holder's restarts: a lost file is charged as a whole
# month so far.
#
#   ck_spend_cents USD                     print whole cents, or return 1 (a plain decimal, at most
#                                          99999.99)
#   ck_spend_fmt CENTS                     print $d.dd, or return 1
#   ck_spend_cap_cents                     registry.spend_cap_usd (default 5, user-only) in cents,
#                                          or return 1
#   ck_spend_check_price USD CAP_CENTS     0 if the monthly price fits the cap, else 78 and a message
#                                          (also 78 for a cap that is not a number)
#   ck_spend_tick FILE NOW [MAXGAP]        add the time since the last tick (default gap cap 900 s)
#   ck_spend_estimate_cents FILE PRICE_CENTS NOW   the month's estimate so far
#   ck_spend_level SPENT CAP               ok | alert (80% or more) | capped (100% or more); capped,
#                                          and return 1, for anything that is not a whole number
#   ck_spend_decide EST FLY CAP            "<level> <fly|estimated> <cents>": the higher figure
#                                          decides; a missing or bad FLY is ignored, never zero
#   ck_spend_alert_once FILE COMMAND NOW   run COMMAND once a month (for the month of NOW);
#                                          remembered only when it succeeds. The loop calls it at
#                                          both alert and capped. Tick first: with no state it
#                                          returns 1 and sends nothing. Pass the same NOW as the
#                                          tick, or the alert can wait one loop.

# ck_sp_int VALUE: 0 if VALUE is a whole number of at most 12 digits.
ck_sp_int() { [[ ${1-} =~ ^[0-9]{1,12}$ ]]; }

# ck_sp_month NOW: print "YYYY-MM DAYS START", the UTC month of NOW, its length in days and the
# epoch of its first second.
ck_sp_month() {
  local z=$(($1 / 86400 + 719468)) era doe yoe y doy mp m days ya yoe2 doy2 doe2
  era=$((z / 146097))
  doe=$((z - era * 146097))
  yoe=$(((doe - doe / 1460 + doe / 36524 - doe / 146096) / 365))
  y=$((yoe + era * 400))
  doy=$((doe - (365 * yoe + yoe / 4 - yoe / 100)))
  mp=$(((5 * doy + 2) / 153))
  m=$((mp < 10 ? mp + 3 : mp - 9))
  ((m <= 2)) && y=$((y + 1))
  case $m in
    4 | 6 | 9 | 11) days=30 ;;
    2) if ((y % 4 == 0 && (y % 100 != 0 || y % 400 == 0))); then days=29; else days=28; fi ;;
    *) days=31 ;;
  esac
  # the first of this month, as days since 1970-01-01
  ya=$y
  ((m <= 2)) && ya=$((ya - 1))
  era=$((ya / 400))
  yoe2=$((ya - era * 400))
  doy2=$(((153 * (m > 2 ? m - 3 : m + 9) + 2) / 5))
  doe2=$((yoe2 * 365 + yoe2 / 4 - yoe2 / 100 + doy2))
  printf '%04d-%02d %d %d\n' "$y" "$m" "$days" $(((era * 146097 + doe2 - 719468) * 86400))
}

ck_spend_cents() {
  local re='^([0-9]{1,5})(\.([0-9]{1,2}))?$' d f
  [[ ${1-} =~ $re ]] || return 1
  d=${BASH_REMATCH[1]} f=${BASH_REMATCH[3]}
  f=${f}00
  printf '%d\n' $((10#$d * 100 + 10#${f:0:2}))
}

ck_spend_fmt() {
  ck_sp_int "${1-}" || return 1
  printf '$%d.%02d\n' $((10#$1 / 100)) $((10#$1 % 100))
}

ck_spend_cap_cents() {
  local v
  v=$(crew_setting registry.spend_cap_usd 5)
  ck_spend_cents "$v"
}

ck_spend_check_price() {
  local c
  if ! ck_sp_int "${2-}"; then
    printf 'crewkit: the holder'\''s spend cap is not a number\n' >&2
    return 78
  fi
  if ! c=$(ck_spend_cents "${1-}"); then
    printf 'crewkit: the holder'\''s monthly price is not a price\n' >&2
    return 78
  fi
  if ((c == 0)); then
    printf 'crewkit: the holder'\''s monthly price is zero, which would never reach any cap\n' >&2
    return 78
  fi
  if ((c > 10#$2)); then
    printf 'crewkit: the holder'\''s monthly price is over the spend cap; raise the cap or choose a smaller machine\n' >&2
    return 78
  fi
}

# ck_sp_load FILE: set sp_ok (1 if FILE held a complete, well-formed state), sp_month, sp_seconds,
# sp_last and sp_alerted from it.
ck_sp_load() {
  local k v m='' s='' l='' a=''
  sp_ok=0 sp_month='' sp_seconds=0 sp_last=0 sp_alerted=0
  [[ -f $1 ]] || return 0
  # a last line without its newline still counts
  while IFS='=' read -r k v || [[ -n $k ]]; do
    case $k in
      month) [[ $v =~ ^[0-9]{4}-[0-9]{2}$ ]] || return 0; m=$v ;;
      seconds) ck_sp_int "$v" || return 0; s=$v ;;
      last) ck_sp_int "$v" || return 0; l=$v ;;
      alerted) [[ $v == 0 || $v == 1 ]] || return 0; a=$v ;;
      *) return 0 ;;
    esac
  done < "$1"
  [[ -n $m && -n $s && -n $l && -n $a ]] || return 0
  sp_ok=1 sp_month=$m sp_seconds=$((10#$s)) sp_last=$((10#$l)) sp_alerted=$a
}

# ck_sp_store FILE: write the sp_* variables, by a temp file (mktemp makes it mode 600) and a rename.
ck_sp_store() {
  local t
  t=$(mktemp "$1.XXXXXX") || return 1
  if printf 'month=%s\nseconds=%d\nlast=%d\nalerted=%d\n' "$sp_month" "$sp_seconds" "$sp_last" "$sp_alerted" > "$t"; then
    mv -f "$t" "$1"
  else
    rm -f "$t"
    return 1
  fi
}

ck_spend_tick() {
  local now=${2-} maxgap=${3:-900} cur start gap lastm
  ck_sp_int "$now" && ck_sp_int "$maxgap" || return 1
  now=$((10#$now)) maxgap=$((10#$maxgap))
  read -r cur _ start <<< "$(ck_sp_month "$now")"
  ck_sp_load "$1"
  if ((!sp_ok)); then
    # no state to trust: the holder is taken to have run since the first of the month
    sp_month=$cur sp_seconds=$((now - start)) sp_alerted=0
  elif [[ $cur > $sp_month ]]; then
    # a new month: it is charged its own share of the gap since the last tick (the part of the
    # gap before midnight belonged to the old month), held to MAXGAP
    gap=$((now - start))
    ((now - sp_last < gap)) && gap=$((now - sp_last))
    ((gap > maxgap)) && gap=$maxgap
    ((gap < 0)) && gap=0
    sp_month=$cur sp_seconds=$gap sp_alerted=0
  else
    # the same month, or a clock that is behind the month in the state: the month and the count
    # never move back, since a wrong clock for one tick would otherwise look like a rollover
    # when it returns and wipe the count
    if ((now > sp_last)); then
      gap=$((now - sp_last))
      ((gap > maxgap)) && gap=$maxgap
      sp_seconds=$((sp_seconds + gap))
    fi
    # a tick that crosses a month boundary from the last tick, in either direction, starts the
    # month's alert afresh: at most one extra alert, never a hidden one
    read -r lastm _ <<< "$(ck_sp_month "$sp_last")"
    [[ $lastm == "$cur" ]] || sp_alerted=0
  fi
  sp_last=$now
  ck_sp_store "$1"
}

ck_spend_estimate_cents() {
  local now=${3-} cur days start secs
  ck_sp_int "${2-}" && ck_sp_int "$now" || return 1
  now=$((10#$now))
  read -r cur days start <<< "$(ck_sp_month "$now")"
  ck_sp_load "$1"
  if ((!sp_ok)); then
    secs=$((now - start))
  elif [[ $cur > $sp_month ]]; then
    secs=0   # a new month that has not ticked yet (its tick will charge its share of the gap)
  else
    secs=$sp_seconds
  fi
  ((secs > days * 86400)) && secs=$((days * 86400))
  printf '%d\n' $((10#$2 * secs / (days * 86400)))
}

ck_spend_level() {
  if ! ck_sp_int "${1-}" || ! ck_sp_int "${2-}"; then
    printf 'capped\n'
    return 1
  fi
  if ((10#$1 >= 10#$2)); then
    printf 'capped\n'
  elif ((10#$1 * 100 >= 10#$2 * 80)); then
    printf 'alert\n'
  else
    printf 'ok\n'
  fi
}

ck_spend_decide() {
  local est=${1-} fly=${2-} cap=${3-} src=estimated spent lvl rc=0
  if ! ck_sp_int "$est" || ! ck_sp_int "$cap"; then
    printf 'capped estimated 0\n'
    return 1
  fi
  spent=$((10#$est))
  if ck_sp_int "$fly" && ((10#$fly > spent)); then
    spent=$((10#$fly))
    src=fly
  fi
  lvl=$(ck_spend_level "$spent" "$cap") || rc=1
  printf '%s %s %d\n' "$lvl" "$src" "$spent"
  return "$rc"
}

ck_spend_alert_once() {
  local cmd=${2-} now=${3-} cur
  ck_sp_int "$now" || return 1
  now=$((10#$now))
  cur=$(ck_sp_month "$now")
  cur=${cur%% *}
  ck_sp_load "$1"
  # a state from an earlier month is not evidence about this month's alert (a later one, after a
  # clock that jumped forward and came back, is this month's count carried on)
  ((sp_ok)) && ! [[ $cur > $sp_month ]] || return 1
  ((sp_alerted == 0)) || return 0
  [[ -n $cmd ]] || return 0
  bash -c "$cmd" < /dev/null || return 1
  sp_alerted=1
  ck_sp_store "$1"
}
