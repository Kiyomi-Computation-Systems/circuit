#!/bin/sh
# S1, a port that waits, 2026-10-25: the driver.  Starts
# s1-port-that-waits.sps on port 0, reads the port from its `listening` line,
# runs each case of the spike against it with curl, in work-list order, and
# prints what each reader reports.  Every feed names the park it is for and
# waits for the reader to be parked there, so a run does not depend on
# timing; a feed that lands anywhere else is printed as FEED FAILED.  Each
# program run is bounded by `timeout`, and the server is stopped at the end.
#
# Run from the repository's root, through the container:
#
#   scripts/guix-env sh .plans/research/spike/s1-port-that-waits.sh
#
# Scratch (pieces, the server's log, each reader's answer) lands in build/s1/.
set -eu

here=.plans/research/spike
out=build/s1
L=vendor/chez-http-server/src:vendor/chez-http-server/vendor/chez-libuv/src:vendor/chez-http-server/vendor/chez-httparse/src:vendor/chez-http-server/vendor/chez-httparse/vendor/byte-machine/src:vendor/chez-http-server/vendor/uriparse/src:build/scheme-libs

mkdir -p "$out"
log=$out/server.log
: > "$log"
: > "$out/feeds.log"
timeout 300 scheme --libdirs "$L" --program "$here/s1-port-that-waits.sps" >> "$log" 2>&1 &
server=$!
trap 'kill "$server" 2>/dev/null || true' EXIT

i=0
until grep -q '^listening ' "$log"; do
  i=$((i + 1))
  if [ "$i" -gt 400 ]; then echo "no listening line in 20 s:"; cat "$log"; exit 1; fi
  sleep 0.05
done
port=$(sed -n 's/^listening [^ ]* \([0-9][0-9]*\)$/\1/p' "$log")
U=http://127.0.0.1:$port
uname -srm
grep '^s1 env' "$log"
echo "listening on $port"

# piece ID K: the file of ID's Kth piece, 1,000 B of lines "IDK-NNNNN".
piece() {
  f=$out/$1$2.bin
  seq -f "$1$2-%05g" 0 999 | head -c 1000 > "$f"
  printf '%s' "$f"
}

# feed ID PARK [FILE]: resume ID's reader at its PARKth park with FILE's
# bytes, or with eof when no FILE is given.
feed() {
  if [ $# -ge 3 ]; then
    ans=$(curl -sS --max-time 10 --data-binary "@$3" "$U/feed?id=$1&park=$2")
  else
    ans=$(curl -sS --max-time 10 --data-binary '' "$U/feed?id=$1&park=$2")
  fi
  case $ans in
    fed*) echo "$ans" >> "$out/feeds.log" ;;
    *) echo "FEED FAILED ($1 park $2): $ans" ;;
  esac
}

# feeds ID FROM TO SHIFT: feed ID's pieces FROM..TO, piece k at park k+SHIFT.
feeds() {
  k=$2
  while [ "$k" -le "$3" ]; do
    feed "$1" $((k + $4)) "$(piece "$1" "$k")"
    k=$((k + 1))
  done
}

# reader ID CASE [OTHER]: GET /read in the background, its answer to
# $out/ID.txt; $! is its curl.
reader() {
  curl -sS --max-time 60 "$U/read?id=$1&case=$2&other=${3:-}" > "$out/$1.txt" 2>&1 &
}

# parked ID N: wait until ID's reader is parked at its Nth park.
parked() { curl -sS --max-time 10 "$U/until?id=$1&parks=$2"; }

# show ID: the reader's answer.
show() { sed 's/^/    /' "$out/$1.txt"; }

echo
echo "== 1. binary reads across parks (n): 19 pieces of 1000 B, then eof"
reader n bytes; r=$!
feeds n 1 19 0
feed n 20
wait "$r"; show n

echo
echo "== 2. a UTF-8 transcoded port (t): pieces split a 2-, 3- and 4-byte character"
printf 'first line, caf\303' > "$out/t1.bin"
printf '\251 au lait\nsecond: na\303' > "$out/t2.bin"
printf '\257ve, 5 \342\202' > "$out/t3.bin"
printf '\254 \360\237\215' > "$out/t4.bin"
printf '\225\nthird line, no newline' > "$out/t5.bin"
reader t text; r=$!
for k in 1 2 3 4 5; do feed t "$k" "$out/t$k.bin"; done
feed t 6
wait "$r"; show t

echo
echo "== 3. with-deadline around a read that parks (d): park 1 is the deadline's"
reader d deadline; r=$!
feeds d 1 3 1
feed d 5
wait "$r"; show d

echo
echo "== 4. the client leaves while the read is parked (c)"
curl -sS --max-time 60 "$U/read?id=c&case=closed" > "$out/c.txt" 2>&1 &
c=$!
feed c 1 "$(piece c 1)"
parked c 2
kill -KILL "$c"; wait "$c" || echo "    (curl killed: status $?)"
parked c 3
feed c 3 "$(piece c 2)"
curl -sS --max-time 20 "$U/done?id=c"
grep '^s1 c ' "$log" | sed 's/^/    /'
echo "    curl had received: $(wc -c < "$out/c.txt") B"

echo
echo "== 5. two readers parked at once (a, b), resumed b first; then (e, f), resumed e first"
reader a two b; ra=$!
reader b two a; rb=$!
parked a 1; parked b 1
curl -sS "$U/state" | grep '^parked now'
feed b 1 "$(piece b 1)"; feed a 1 "$(piece a 1)"
feed a 2 "$(piece a 2)"; feed b 2 "$(piece b 2)"
feed b 3 "$(piece b 3)"; feed a 3 "$(piece a 3)"
feed a 4; feed b 4
wait "$ra" "$rb"; show a; show b
reader e two f; re=$!
reader f two e; rf=$!
parked e 1; parked f 1
curl -sS "$U/state" | grep '^parked now'
feed e 1 "$(piece e 1)"; feed f 1 "$(piece f 1)"
feed f 2 "$(piece f 2)"; feed e 2 "$(piece e 2)"
feed e 3 "$(piece e 3)"; feed f 3 "$(piece f 3)"
feed f 4; feed e 4
wait "$re" "$rf"; show e; show f

echo
echo "== 6. a raise after a partial read: pieces 1-2, the deadline at park 3, pieces 3-4, eof"
for case in p:partial-n q:partial-big r:partial-some; do
  id=${case%%:*}
  reader "$id" "${case#*:}"; r=$!
  feeds "$id" 1 2 0
  feeds "$id" 3 4 1
  feed "$id" 6
  wait "$r"; show "$id"
done
printf '0123456789\303' > "$out/s1.bin"
printf '\251 tail' > "$out/s2.bin"
printf '0123456789' > "$out/u1.bin"
printf '\303\251 tail' > "$out/u2.bin"
seq -f "v-%05g" 0 99 | head -c 600 > "$out/v1.bin"
printf '\303' >> "$out/v1.bin"
printf '\251 tail' > "$out/v2.bin"
for case in s:text-split v:text-split-long u:text-boundary; do
  id=${case%%:*}
  reader "$id" "${case#*:}"; r=$!
  feed "$id" 1 "$out/${id}1.bin"
  feed "$id" 3 "$out/${id}2.bin"
  feed "$id" 4
  wait "$r"; show "$id"
done

echo
echo "== 7. what a park inside read! leaves held (x)"
reader x probe; r=$!
parked x 1
curl -sS "$U/probe"
curl -sS "$U/probe?control=1"
feed x 1 "$(piece x 1)"
parked x 2
curl -sS "$U/probe"
feed x 2 "$(piece x 2)"
parked x 3
echo "(x is parked in the control's read, inside a critical-section)"
curl -sS "$U/probe"
feed x 3 "$(piece x 3)"
feed x 4
wait "$r"; show x

echo
echo "== the server's own log, once stopped"
kill -TERM "$server"
wait "$server" || echo "server exit status $?"
trap - EXIT
grep -v '^s1 ' "$log" | sed 's/^/    /'
echo "feeds: $(grep -c '^fed' "$out/feeds.log") answered 'fed'"
