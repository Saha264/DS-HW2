#!/bin/bash
#SBATCH --job-name=q3
#SBATCH --nodes=1
#SBATCH --ntasks=8
#SBATCH --time=00:30:00
#SBATCH --partition=debug
#SBATCH --output=q3_%j.out

set -e
module load hpcx-2.7.0/hpcx-ompi
cd "$SLURM_SUBMIT_DIR"
mpic++ -O2 -std=c++17 bitonic.c++ -o bitonic

echo 'Q3 correctness'
expected=$(cat tests/basic.expected)
for p in 1 2 4 8; do
    got=$(srun -n $p ./bitonic < tests/basic.in | xargs)
    [ "$got" = "$expected" ] || { echo "FAIL P=$p: $got"; exit 1; }
    echo "P=$p PASS"
done

mkdir -p data
for n in 65536 262144 1048576; do
    python3 generate.py $n 12345 > data/$n.in
done

echo 'size,p,time,baseline,speedup,efficiency' > q3_metrics.csv
for n in 65536 262144 1048576; do
    t1=''
    for p in 1 2 4 8; do
        /usr/bin/time -f '%e' -o .time srun -n $p ./bitonic < data/$n.in > /dev/null
        t=$(cat .time)
        [ $p -eq 1 ] && t1=$t
        speed=$(awk -v a=$t1 -v b=$t 'BEGIN{printf "%.4f", a/b}')
        eff=$(awk -v s=$speed -v p=$p 'BEGIN{printf "%.4f", s/p}')
        echo "$n,$p,$t,$t1,$speed,$eff" >> q3_metrics.csv
    done
done
cat q3_metrics.csv
