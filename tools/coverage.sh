#!/bin/zsh
# Accumulate execution coverage of the original (reference emulator) over the
# intro and every level with random play; export entry flags to docs/code-entries.bin.
ROOT=${0:A:h}/..; cd $ROOT
OUT=work/ref/cov
swift build -c release --product nzs-ref >/dev/null
.build/release/nzs-ref "Newzealand Story.adf" $OUT --frames 3000 --every 100000 --fire-at 400 --coverage | grep coverage
# full traversal: cheat (1000 lives), then the developer HELP key skips every level up to the ending
.build/release/nzs-ref "Newzealand Story.adf" $OUT --frames 11000 --every 100000 --fire-at 400 --type MOTHERFUCKENKIWIBASTARD --skip-every 400 --coverage | grep coverage
for seed in 11 23 37; do
  for lv in $(seq 0 19); do
    .build/release/nzs-ref "Newzealand Story.adf" $OUT --frames 5000 --every 100000 --random --seed $((seed*100+lv)) --level $lv --coverage | grep coverage
  done
done
python3 -I -c "
d=open('$OUT/coverage.bin','rb').read()
with open('docs/code-entries.txt','w') as f:
    f.write('; Addresses where the original was entered by a call (2) or computed jump (4),\\n; recorded by nzs-ref --coverage (tools/coverage.sh). Addresses only, no game data.\\n')
    n=0
    for i,b in enumerate(d):
        if b & 6: f.write('%05x %d\\n'%(i*2,b & 6)); n+=1
print('entries:', n)"
