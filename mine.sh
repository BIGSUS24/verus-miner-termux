#!/data/data/com.termux/files/usr/bin/bash
# Verus (VRSC) miner for Android/Termux on ARM64.
# Runs natively in Termux - no proot, no Ubuntu container, no compiling.
#   ./mine.sh              start mining
#   ./mine.sh --selftest   run the thermal-guard checks
#   ./mine.sh --bench      60s hashrate benchmark, no pool
set -euo pipefail

DIR="$HOME/verus-miner"
BIN="$DIR/ccminer"
WALLET_FILE="$DIR/wallet.conf"
LOG="$DIR/miner.log"

# Darktron builds link against Bionic (/system/bin/linker64) so they run in
# plain Termux. The Oink70 ARM builds are glibc and need proot - avoided.
# Branch name = CPU core. Snapdragon 435 is Cortex-A53.
CPU="${CPU:-a53}"
BIN_URL="https://raw.githubusercontent.com/Darktron/pre-compiled/$CPU/ccminer"

POOL="${POOL:-ap.luckpool.net:3957}"     # eu. or na. also available; 3957 is the CPU port
WORKER="${WORKER:-redmi4}"
THREADS="${THREADS:-6}"                  # of 8 cores; headroom keeps heat down

HOT="${HOT:-48}"       # pause mining at or above this battery temp (C)
COOL="${COOL:-42}"     # resume below this
POLL="${POLL:-20}"     # seconds between temp checks

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxxx\033[0m %s\n' "$*" >&2; exit 1; }

# --- thermal helpers -------------------------------------------------------

# Kernels report battery temp in decidegrees (350 = 35.0C) or plain degrees.
norm_temp() {
  local v="$1"
  case "$v" in ''|*[!0-9-]*) return 1;; esac
  if [ "$v" -gt 200 ]; then echo $((v / 10)); else echo "$v"; fi
}

TEMP_SRC=""
find_temp_source() {
  local p
  for p in /sys/class/power_supply/battery/temp \
           /sys/class/power_supply/bms/temp \
           /sys/devices/virtual/power_supply/battery/temp \
           /sys/class/thermal/thermal_zone0/temp; do
    if [ -r "$p" ] && norm_temp "$(cat "$p" 2>/dev/null || echo x)" >/dev/null 2>&1; then
      TEMP_SRC="$p"; return 0
    fi
  done
  if command -v termux-battery-status >/dev/null 2>&1; then
    TEMP_SRC="api"; return 0
  fi
  return 1
}

read_temp() {
  local v
  if [ "$TEMP_SRC" = "api" ]; then
    v=$(termux-battery-status 2>/dev/null \
        | sed -n 's/.*"temperature"[: ]*\([0-9.]*\).*/\1/p' | cut -d. -f1)
    norm_temp "${v:-x}"
  else
    norm_temp "$(cat "$TEMP_SRC" 2>/dev/null || echo x)"
  fi
}

# Given current temp and whether we are currently paused, say what to do.
# Hysteresis: only pause at/above HOT, only resume below COOL.
decide() {
  local t="$1" paused="$2"
  if [ "$paused" = "1" ]; then
    [ "$t" -lt "$COOL" ] && echo resume || echo hold
  else
    [ "$t" -ge "$HOT" ] && echo pause || echo hold
  fi
}

# --- setup -----------------------------------------------------------------

verify_elf() {
  local hdr; hdr=$(od -An -tx1 -N20 "$1" 2>/dev/null | tr -d ' \n')
  case "$hdr" in 7f454c46*) ;; *) return 1;; esac   # ELF magic
  [ "${hdr:8:2}"  = "02"   ] || return 1            # 64-bit
  [ "${hdr:36:4}" = "b700" ] || return 1            # EM_AARCH64
  return 0
}

install_miner() {
  say "Installing dependencies"
  local out
  if ! out=$(pkg install -y curl libcurl openssl libjansson libc++ zlib 2>&1); then
    printf '%s\n' "$out" | tail -25 >&2
    echo >&2
    die "pkg install failed - the real error is printed above.

Common causes:
  * Termux installed from the Play Store. That build is abandoned and its
    package repos are gone. Install from F-Droid or from
    github.com/termux/termux-app instead.
  * Stale mirror. Run 'termux-change-repo', pick a main mirror, then
    'pkg update' and try again.
  * No network, or a mirror is temporarily down - retry in a few minutes."
  fi

  say "Downloading ccminer (Cortex-$CPU build)"
  curl -fL --progress-bar -o "$BIN" "$BIN_URL" \
    || die "Download failed. Verify branch $CPU exists:
       https://github.com/Darktron/pre-compiled/branches"
  chmod +x "$BIN"

  verify_elf "$BIN" || die "Downloaded file is not a 64-bit ARM binary.
       This device reports: $(uname -m)   (need aarch64)"
  say "Installed, aarch64 verified"
}

setup_wallet() {
  [ -f "$WALLET_FILE" ] && return 0
  echo
  echo "Need a Verus R-address to be paid to."
  echo "Get one from the Verus Mobile app. Must start with R."
  echo "An exchange deposit address will NOT merge-mine - use a wallet address."
  echo
  local addr confirm
  read -r -p "Verus R-address: " addr
  echo "$addr" | grep -Eq '^R[1-9A-HJ-NP-Za-km-z]{33}$' \
    || die "Not a valid Verus R-address (expect R followed by 33 base58 chars)."

  # A format-valid but mistyped address mines into an address nobody controls,
  # with no way to recover the coins. Make the user eyeball it once.
  echo
  echo "    $addr"
  echo
  read -r -p "Does this match your wallet EXACTLY? Type yes to confirm: " confirm
  [ "$confirm" = "yes" ] || die "Not confirmed. Nothing saved - run again."

  echo "$addr" > "$WALLET_FILE"
  say "Wallet saved to $WALLET_FILE"
}

# --- run -------------------------------------------------------------------

MINER_PID=""
cleanup() {
  if [ -n "$MINER_PID" ]; then
    # A SIGSTOPped process will not act on SIGTERM until it is resumed first.
    kill -CONT "$MINER_PID" 2>/dev/null || true
    kill "$MINER_PID" 2>/dev/null || true
  fi
  command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock 2>/dev/null || true
  echo
  say "Stopped."
}
trap cleanup EXIT INT TERM

run() {
  local wallet; wallet=$(cat "$WALLET_FILE")

  find_temp_source || die "No readable battery temperature on this device.
The thermal guard is the only thing protecting a 2017 battery from sustained
full-load heat. Install the Termux:API app plus 'pkg install termux-api',
or re-run with HOT=999 to mine without a guard at your own risk."

  command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock 2>/dev/null || true

  say "Pool     $POOL"
  say "Wallet   $wallet"
  say "Threads  $THREADS of $(nproc)"
  say "Thermal  pause >= ${HOT}C, resume < ${COOL}C  (source: $TEMP_SRC)"
  say "Log      $LOG"
  say "Stats    https://luckpool.net/verus/miner/$wallet"
  echo

  "$BIN" -a verus -o "stratum+tcp://$POOL" -u "$wallet.$WORKER" -p x -t "$THREADS" \
    >> "$LOG" 2>&1 &
  MINER_PID=$!

  local paused=0 t action
  while kill -0 "$MINER_PID" 2>/dev/null; do
    if t=$(read_temp) && [ -n "$t" ]; then
      action=$(decide "$t" "$paused")
      case "$action" in
        pause)  kill -STOP "$MINER_PID"; paused=1; warn "${t}C - too hot, paused";;
        resume) kill -CONT "$MINER_PID"; paused=0; say  "${t}C - cooled, resumed";;
      esac
    fi
    sleep "$POLL"
  done
  MINER_PID=""
  warn "Miner exited. Last lines of $LOG:"
  tail -5 "$LOG" 2>/dev/null || true
}

# --- selftest --------------------------------------------------------------

selftest() {
  local f=0
  check() { # expected actual label
    if [ "$1" = "$2" ]; then echo "  ok   $3"
    else echo "  FAIL $3 (expected '$1', got '$2')"; f=1; fi
  }
  echo "norm_temp:"
  check 35 "$(norm_temp 350)" "350 decidegrees -> 35C"
  check 35 "$(norm_temp 35)"  "35 degrees -> 35C"
  check 52 "$(norm_temp 520)" "520 decidegrees -> 52C"
  norm_temp "abc" >/dev/null 2>&1 && { echo "  FAIL rejects junk"; f=1; } || echo "  ok   rejects junk"
  norm_temp ""    >/dev/null 2>&1 && { echo "  FAIL rejects empty"; f=1; } || echo "  ok   rejects empty"

  echo "decide (HOT=$HOT COOL=$COOL):"
  check hold   "$(decide 40 0)" "running, 40C -> keep going"
  check pause  "$(decide 48 0)" "running, at HOT -> pause"
  check pause  "$(decide 55 0)" "running, 55C -> pause"
  check hold   "$(decide 45 1)" "paused, 45C still above COOL -> stay paused"
  check resume "$(decide 41 1)" "paused, below COOL -> resume"
  check hold   "$(decide 47 0)" "running, just under HOT -> keep going"

  echo "wallet regex:"
  wt() { if echo "$1" | grep -Eq '^R[1-9A-HJ-NP-Za-km-z]{33}$'; then echo accept; else echo reject; fi; }
  check accept "$(wt RQVsJRf98RDCJi8W4KtnbUW2vCpq1qGuAJ)"  "valid 34-char R-address"
  check reject "$(wt RQVsJRf98RDCJi8W4KtnbUW2vCpq1qGuA)"   "too short"
  check reject "$(wt R0VsJRf98RDCJi8W4KtnbUW2vCpq1qGuAJ)"  "contains 0 (not base58)"
  check reject "$(wt 1QVsJRf98RDCJi8W4KtnbUW2vCpq1qGuAJ)"  "bitcoin address"
  check reject "$(wt '')"                                   "empty"

  [ "$f" = 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
}

# --- main ------------------------------------------------------------------

case "${1:-}" in
  --selftest) selftest; exit 0;;
esac

mkdir -p "$DIR"
[ -x "$BIN" ] || install_miner

case "${1:-}" in
  --bench)
    say "60s benchmark on $THREADS threads, no pool"
    timeout 60 "$BIN" -a verus --benchmark -t "$THREADS" 2>&1 | tail -20 || true
    exit 0;;
esac

setup_wallet
run
