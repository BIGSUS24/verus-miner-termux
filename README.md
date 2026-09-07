# Verus miner — Redmi 4 / Termux

One command. Downloads a prebuilt ARM binary (no compiling), asks for your
wallet once, mines with a thermal guard so the 2017 battery survives.

---

## 0. The number, once

~**0.0021 VRSC/day** ≈ ₹0.33/day ≈ **₹10/month** (merge-mining, best case).
Electricity is ~₹23/month. Read section 4 before planning on the money.

---

## 1. Wallet — get an R-address

LuckPool merge-mines **only to a native Verus R-address**. An exchange deposit
address disables merge mining and cuts earnings to roughly a third.

1. Install **Verus Mobile** — [verus.io/wallet](https://verus.io/wallet)
   (Play Store: "Verus Mobile", by Verus Coin Foundation)
2. Open it → **Create new wallet**
3. It shows a **24-word seed phrase**
4. Go to your VRSC address, tap to copy. Starts with `R`, 34 characters.

> **Write the 24 words on paper before continuing.**
> That seed is the only thing that controls your coins. Nobody — not the pool,
> not Verus, not me — can recover it for you. If the phone dies or the app is
> uninstalled and you don't have those words, every coin is gone permanently.
> Never type the seed into a website, never photograph it, never put it in
> cloud storage or a notes app. The script never asks for it and never needs
> it — it only takes your public R-address, which is safe to share.

---

## 2. Install and run

In Termux on the Redmi 4:

```bash
pkg update -y && pkg install -y git
git clone https://github.com/BIGSUS24/verus-miner-termux verus && cd verus
chmod +x mine.sh
./mine.sh
```

First run installs deps + downloads the miner, then asks for your R-address.
Every run after that goes straight to mining.

Keep it alive when the screen is off:

```bash
pkg install -y termux-api      # then install the Termux:API app too
```

### Options

```bash
./mine.sh --bench       # 60s hashrate test, tells you what this phone really does
./mine.sh --selftest    # verify the thermal guard logic
THREADS=4 ./mine.sh     # fewer threads = cooler, slower
POOL=eu.luckpool.net:3957 ./mine.sh    # Europe instead of Asia-Pacific
CPU=generic ./mine.sh                   # if the a53 build misbehaves
GUARD=on ./mine.sh                     # pause the miner when hot (off by default)
GUARD=on HOT=45 COOL=40 ./mine.sh      # stricter thresholds
```

### Thermal guard (off by default)

By default the miner runs at full speed and is never paused.

`GUARD=on` enables pausing: temperature is read every 20s, the miner is
stopped with SIGSTOP at or above 48C and resumed below 42C. The gap prevents
rapid stop/start cycling.

Temperature is read from the first readable source among the battery sysfs
paths, then `thermal_zone0`, then Termux:API. Values arrive as millidegrees
(35700), decidegrees (357) or plain degrees (35) depending on the source, and
are normalised. Note that `thermal_zone0` is CPU temperature, not battery, and
runs considerably hotter -- raise `HOT` accordingly if that is the source.

---

## 3. Watch it earn

```
https://luckpool.net/verus/miner/<your-R-address>
```

The script prints this URL at startup. Shows live hashrate, shares, balance,
payment history.

**LuckPool pays out automatically at 0.0001 VRSC** — an unusually low
threshold. You clear it roughly hourly, so coins actually land in your wallet
instead of being stuck below a minimum forever. This is the one thing Verus
does better than Monero for a phone.

---

## 4. Getting money out — read the math first

No exchange lists VRSC against INR. The chain is:

```
Verus Mobile  →  TradeOgre / SafeTrade  →  sell for USDT
              →  withdraw USDT (TRC20)  →  CoinDCX or WazirX
              →  sell for INR           →  bank account
```

Each hop costs something:

| Step | Typical cost |
|---|---|
| VRSC network send | ~0.0001 VRSC |
| Exchange trade fee | ~0.2% |
| USDT TRC20 withdrawal | ~$1 flat |
| Indian exchange trade | ~0.5% |
| INR bank withdrawal | ₹10-25 |

Flat fees are the problem, not the percentages. **A cashout below roughly $20
loses money to fees.** At 0.064 VRSC/month (~$0.026), reaching $20 takes about
**64 years** of continuous mining.

So: the mining works, the payouts work, and the coins are genuinely yours in a
wallet you control. The cashout step is where it stops. This is not a fixable
config problem — it's the flat withdrawal fee versus the earning rate.

Practical options:
- **Let it accumulate** and don't plan on cashing out. Coins are yours either way.
- **Convert inside Verus** — VerusDeFi bridges on-chain with no exchange hop.
- **Pool with other income** — cash out once alongside a larger crypto balance,
  so the flat fee is paid once for everything.

### India tax

Crypto gains are taxed at a **flat 30%**, with a **1% TDS on every
transaction**, and losses cannot be offset against other income. Applies at the
sell step. At these amounts the tax is negligible in rupees, but the
transactions are still reportable.

---

## 5. If it breaks

| Symptom | Fix |
|---|---|
| `pkg install failed` | `pkg update && pkg upgrade`, retry |
| `Binary will not run` | `uname -m` must be `aarch64` |
| `No readable battery temperature` | Install Termux:API app + `pkg install termux-api` |
| Dies when screen off | `termux-wake-lock`, and disable MIUI battery optimisation for Termux |
| Phone very hot | Lower `THREADS`, lower `HOT`, take the case off |
| Zero shares after 10 min | Wrong pool region — try `POOL=eu.luckpool.net:3957` |

Check `~/verus-miner/miner.log` for the miner's own output.

---

## What the script actually does

Downloads a prebuilt `ccminer` from
[Darktron/pre-compiled](https://github.com/Darktron/pre-compiled), branch
`a53` -- an open-source VerusHash miner, built per CPU core. The Snapdragon 435
is Cortex-A53, so that branch is the exact match.

**Why not the more commonly linked Oink70 build:** its binaries are linked
against glibc (ELF interpreter `/lib/ld-linux-aarch64.so.1`), which Android does
not have. They cannot run in plain Termux at all -- which is why nearly every
guide online wraps them in a proot-distro Ubuntu container. The Darktron builds
link against Bionic (`/system/bin/linker64`), so they run natively: no
container, no ~500 MB rootfs, no proot overhead, no compiling.

The script verifies the ELF header after download (magic, 64-bit, `EM_AARCH64`)
and refuses to continue if the file is not a 64-bit ARM binary.
