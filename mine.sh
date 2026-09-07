#!/data/data/com.termux/files/usr/bin/bash
# Verus (VRSC) miner for Android/Termux on ARM64.
# Runs natively in Termux - no proot, no Ubuntu container, no compiling.
#   ./mine.sh              start mining
#   ./mine.sh --bench      hashrate benchmark, no pool, up to 120s
#   ./mine.sh --selftest   run the address-validation checks
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
THREADS="${THREADS:-$(nproc)}"           # every core, full speed

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxxx\033[0m %s\n' "$*" >&2; exit 1; }

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
  # A failure here is often apt being unable to UPGRADE a package that is
  # already installed and working (a stale mirror serving a 404). That does
  # not mean the miner cannot run, so warn rather than abort. What actually
  # matters is whether the binary links, which is checked below.
  local out
  if ! out=$(pkg install -y curl libcurl openssl libjansson libc++ zlib 2>&1); then
    printf '%s\n' "$out" | tail -15 >&2
    echo >&2
    warn "Some packages did not install (output above). Continuing anyway -"
    warn "the real test is whether the miner runs. If it does not, try:"
    warn "  termux-change-repo   (pick a different main mirror), then pkg update"
  fi

  say "Downloading ccminer (Cortex-$CPU build)"
  curl -fL --progress-bar -o "$BIN" "$BIN_URL" \
    || die "Download failed. Verify branch $CPU exists:
       https://github.com/Darktron/pre-compiled/branches"
  chmod +x "$BIN"

  verify_elf "$BIN" || die "Downloaded file is not a 64-bit ARM binary.
       This device reports: $(uname -m)   (need aarch64)"

  # Confirm the dynamic linker can actually resolve every shared library.
  local probe=""
  probe=$("$BIN" --help 2>&1 | head -20) || true
  if printf '%s' "$probe" | grep -qiE 'cannot link|library .* not found|CANNOT LINK'; then
    printf '%s\n' "$probe" | head -8 >&2
    echo >&2
    # Map the missing soname to the Termux package that provides it. A naive
    # strip of the .so suffix is wrong for several of these: libcrypto.so.3
    # comes from openssl, not from a package called libcrypto.
    local miss pkgname
    miss=$(printf '%s' "$probe" | sed -n 's/.*library "\([^"]*\)" not found.*/\1/p' | head -1)
    case "$miss" in
      libjansson*)         pkgname=libjansson ;;
      libcurl*)            pkgname=libcurl ;;
      libcrypto*|libssl*)  pkgname=openssl ;;
      libc++*)             pkgname=libc++ ;;
      libz*)               pkgname=zlib ;;
      *)                   pkgname="" ;;
    esac
    if [ -n "$pkgname" ]; then
      die "The miner cannot load $miss (see above). Install it with:

    pkg install -y $pkgname

Installing that package on its own avoids any unrelated upgrade that may be
404ing on a stale mirror. If it 404s too, run 'termux-change-repo', pick a
different main mirror, then 'pkg update', then run this script again."
    fi
    die "The miner downloaded but cannot load a shared library (see above).
Install the package that provides it with 'pkg install <name>'. If apt 404s
on it, switch mirrors: termux-change-repo, then pkg update."
  fi

  say "Installed, aarch64 verified, libraries resolve"
}

setup_wallet() {
  [ -f "$WALLET_FILE" ] && return 0
  echo
  echo "Need a Verus R-address to be paid to."
  echo "Get one from Verus Desktop or Verus Mobile. Must start with R."
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

cleanup() {
  command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock 2>/dev/null || true
}
trap cleanup EXIT INT TERM

run() {
  local wallet; wallet=$(cat "$WALLET_FILE")

  command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock 2>/dev/null || true

  say "Pool     $POOL"
  say "Wallet   $wallet"
  say "Threads  $THREADS of $(nproc)  (full speed)"
  say "Log      $LOG"
  say "Stats    https://luckpool.net/verus/miner/$wallet"
  say "Ctrl+C to stop."
  echo

  # Foreground with tee: hashrate is visible live here and still written to
  # the log, so no second Termux session is needed to watch it.
  "$BIN" -a verus -o "stratum+tcp://$POOL" -u "$wallet.$WORKER" -p x -t "$THREADS" \
    2>&1 | tee -a "$LOG"
}

# --- selftest --------------------------------------------------------------

selftest() {
  local f=0
  check() { # expected actual label
    if [ "$1" = "$2" ]; then echo "  ok   $3"
    else echo "  FAIL $3 (expected '$1', got '$2')"; f=1; fi
  }
  echo "wallet regex:"
  wt() { if echo "$1" | grep -Eq '^R[1-9A-HJ-NP-Za-km-z]{33}$'; then echo accept; else echo reject; fi; }
  check accept "$(wt RTPkQa2PPdhNBGXMDDNpqAH8KZrfJZFyn4)"  "valid 34-char R-address"
  check reject "$(wt RTPkQa2PPdhNBGXMDDNpqAH8KZrfJZFyn)"   "33 chars, too short"
  check reject "$(wt RTPkQa2PPdhNBGXMDDNpqAH8KZrfJZFyn44)" "35 chars, too long"
  check reject "$(wt R0PkQa2PPdhNBGXMDDNpqAH8KZrfJZFyn4)"  "contains 0, not base58"
  check reject "$(wt ROPkQa2PPdhNBGXMDDNpqAH8KZrfJZFyn4)"  "contains O, not base58"
  check reject "$(wt UsX7yGJtSwQNFpGsMUwrTVjjJ1zYwNnMq8dZTbyrfbcktnknBPLk)" "private key, not an address"
  check reject "$(wt 1PkQa2PPdhNBGXMDDNpqAH8KZrfJZFyn4A)"  "bitcoin address"
  check reject "$(wt '')"                                   "empty"

  echo "elf verifier:"
  printf '\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x03\x00\xb7\x00' > /tmp/_ok.bin
  printf 'not an elf file at all here ok' > /tmp/_bad.bin
  verify_elf /tmp/_ok.bin  && echo "  ok   accepts aarch64 ELF" || { echo "  FAIL accepts aarch64 ELF"; f=1; }
  verify_elf /tmp/_bad.bin && { echo "  FAIL rejects non-ELF"; f=1; } || echo "  ok   rejects non-ELF"
  rm -f /tmp/_ok.bin /tmp/_bad.bin

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
    say "Benchmark on $THREADS threads, no pool. Runs up to 120s."
    say "Ctrl+C to stop early."
    echo
    timeout 120 "$BIN" -a verus --benchmark -t "$THREADS" 2>&1 || true
    exit 0;;
esac

setup_wallet
run
