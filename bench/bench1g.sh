#!/usr/bin/env bash
# 1 GB run: zlib baseline, then all four ports in parallel (each single-threaded; the model is
# memory-latency bound with ~70 MB tables, far beyond L3, so parallel runs barely interfere).
set -u
cd "$(dirname "$0")/.."
IN=testdata/mixed_1gb.tar
O=out1g; mkdir -p $O
python3 bench/zlib_bench.py $IN | tee $O/zlib.txt
declare -A RUN=([c]="c/fm" [bpl]="bpl/fm" [bun]="bun js/fm.mjs" [node]="node --max-old-space-size=8192 js/fm.mjs")
for p in c bpl bun node; do
  ( /usr/bin/time -f "%e %M" -o $O/$p.te ${RUN[$p]} enc bytes $IN $O/$p.frc &&
    /usr/bin/time -f "%e %M" -o $O/$p.td ${RUN[$p]} dec $O/$p.frc $O/$p.out ) 2>$O/$p.err &
done
wait
size=$(stat -c%s $IN)
for p in c bpl bun node; do
  read -r te me <$O/$p.te; read -r td md <$O/$p.td
  out=$(stat -c%s $O/$p.frc)
  printf "%-5s %11d %11d %7.3f enc=%8.1fs dec=%8.1fs %6.2f MB/s peak=%dMB %s %s\n" $p $size $out \
    "$(echo "$out/$size" | bc -l)" $te $td "$(echo "$size/1000000/$te" | bc -l)" $(( (me > md ? me : md) / 1024 )) \
    "$(cmp -s $IN $O/$p.out && echo rt-ok || echo RT-FAIL)" "$(cmp -s $O/c.frc $O/$p.frc && echo same-as-c || echo DIFF)"
done | tee $O/ports.txt
rm -f $O/*.out
