#!/usr/bin/env bash
# diamond.sh — control the HP Omen RTX 4080 SUPER diamond RGB on Linux.
#
# SPDX-License-Identifier: GPL-2.0-or-later
# Project: hp-omen-gpu-rgb — reverse-engineered Linux control of the HP Omen
# GPU "diamond" RGB element. Protocol reverse-engineered from HP's own OMEN
# Gaming Hub (NvidiaApi.dll / HP.Omen.Background.TuringBg.dll). See PROTOCOL.md.
#
# On-wire = 24-byte raw I2C write to the GPU's on-board controller at i2c-3 addr 0x49:
#     [06 81 f9 7e]  = HP "set lighting" command header
#   + 20-byte Rtxi2CLightingData struct:
#     [LedMode][Brightness][Speed][Monochrome]
#     [En0 R0 G0 B0][En1 R1 G1 B1][En2 R2 G2 B2][En3 R3 G3 B3]
# LedMode: 0=colorcycle 1=wave 2=blink 3=breathing 4=static 5=off.
# regAddrSize=0 (no register byte). State is NVRAM-persistent; recover from any
# unwanted state by committing a new one (PSU power-cycle does NOT reset it).
#
# Commands:
#   off                         LedMode=5
#   static  R G B [BRIGHT]      LedMode=4, all 4 zones = one color, Monochrome=1
#   zone0   R G B [BRIGHT]      LedMode=4, ONLY zone0 set, Monochrome=0 (HP's exact path)
#   mode N  R G B [BRIGHT] [SP] LedMode=N, all 4 zones = color (test any mode)
#   hold    R G B [BRIGHT]      repeat `static` at HZ (keepalive)
#   raw     <24 hex bytes>      send an explicit 24-byte payload
#
# Env: BUS=3  ADDR=0x49  HZ=5  DRY=1(print bytes, don't send)
#      REP=N (re-assert the write N times; a single write updates the controller's
#             channels only partially, so re-asserting flushes all of them to the
#             target — mirrors HP's native retry loop)  DELAY=secs between reps

set -euo pipefail
BUS="${BUS:-3}"; ADDR="${ADDR:-0x49}"; HZ="${HZ:-5}"; DRY="${DRY:-0}"; RD="${RD:-1}"  # RD=1: append 4-byte commit-read (required to latch)
REP="${REP:-8}"; DELAY="${DELAY:-0.05}"   # REP: re-assert count (8 = proven-clean channel flush); DELAY: secs between re-asserts
HDR="0x06 0x81 0xf9 0x7e"          # "set lighting" command header
VHDR="0x07 0x81 0xf8 0x7e"         # "get fw version" command header

h() { printf '0x%02x' "$(( $1 & 0xff ))"; }

# 20 struct bytes: mode bright speed mono, then 4x (enable r g b)
struct() { # mode bright speed mono  e0 r0 g0 b0 ... (pass 4 for header fields, then 16 zone)
  local mode=$1 bright=$2 speed=$3 mono=$4; shift 4
  printf '%s %s %s %s' "$(h "$mode")" "$(h "$bright")" "$(h "$speed")" "$(h "$mono")"
  local i; for i in "$@"; do printf ' %s' "$(h "$i")"; done
}

# all-4-zones one color
zones_all() { local r=$1 g=$2 b=$3; printf '1 %d %d %d 1 %d %d %d 1 %d %d %d 1 %d %d %d' "$r" "$g" "$b" "$r" "$g" "$b" "$r" "$g" "$b" "$r" "$g" "$b"; }
zones_z0()  { local r=$1 g=$2 b=$3; printf '1 %d %d %d 0 0 0 0 0 0 0 0 0 0 0 0' "$r" "$g" "$b"; }
zones_zero(){ printf '0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0'; }

build() { # echoes full 24-byte payload (header + struct)
  echo "$HDR $1"
}

# send <24-byte-payload> [header]   ; RD=1 appends a 4-byte read (write-then-read commit/poll)
send() {
  local payload hdr="${2:-$HDR}"; payload="$hdr $1"
  local n; n=$(wc -w <<<"$payload")
  if [ "$n" -ne 24 ]; then echo "BUG: built $n bytes, need 24: $payload" >&2; exit 2; fi
  local rd=""; [ "$RD" = 1 ] && rd="r4@$ADDR"
  if [ "$DRY" = 1 ]; then echo "[dry] i2ctransfer -y $BUS w24@$ADDR $payload $rd  (x$REP)"; return 0; fi
  local i
  for (( i=0; i<REP; i++ )); do
    # shellcheck disable=SC2086
    i2ctransfer -y "$BUS" "w24@$ADDR" $payload $rd
    [ $(( i+1 )) -lt "$REP" ] && sleep "$DELAY"
  done
}

cmd="${1:-}"; shift || true
case "$cmd" in
  off)    send "$(struct 5 0 0 0 $(zones_zero))" ;;
  static) send "$(struct 4 "${4:-255}" 0 1 $(zones_all "$1" "$2" "$3"))" ;;
  zone0)  send "$(struct 4 "${4:-255}" 0 0 $(zones_z0  "$1" "$2" "$3"))" ;;
  mode)   N=$1; shift; send "$(struct "$N" "${4:-255}" "${5:-3}" 1 $(zones_all "$1" "$2" "$3"))" ;;
  hold)   echo "Holding at ${HZ}Hz (Ctrl-C to stop)…" >&2
          p="$(struct 4 "${4:-255}" 0 1 $(zones_all "$1" "$2" "$3"))"
          while :; do send "$p" >/dev/null 2>&1 || true; sleep "$(awk "BEGIN{print 1/$HZ}")"; done ;;
  getver) # HP's own firmware-version query (exact 20-byte body from NvidiaI2CFwVersion disasm):
          # 04 00 01 01  01 00 00 00  01 00 00 00  01 00 00 00  01 00 00 00
          body="0x04 0x00 0x01 0x01 0x01 0x00 0x00 0x00 0x01 0x00 0x00 0x00 0x01 0x00 0x00 0x00 0x01 0x00 0x00 0x00"
          if [ "$DRY" = 1 ]; then echo "[dry] i2ctransfer -y $BUS w24@$ADDR $VHDR $body r4@$ADDR";
          else i2ctransfer -y "$BUS" "w24@$ADDR" $VHDR $body "r4@$ADDR"; fi ;;
  read)   N="${1:-4}"; if [ "$DRY" = 1 ]; then echo "[dry] i2ctransfer -y $BUS r${N}@$ADDR";
          else i2ctransfer -y "$BUS" "r${N}@$ADDR"; fi ;;
  raw)    [ $# -eq 24 ] || { echo "raw needs exactly 24 hex bytes" >&2; exit 1; }
          if [ "$DRY" = 1 ]; then echo "[dry] i2ctransfer -y $BUS w24@$ADDR $*"; else i2ctransfer -y "$BUS" "w24@$ADDR" "$@"; fi ;;
  *) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
