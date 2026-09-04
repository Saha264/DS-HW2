#!/bin/bash
#SBATCH --job-name=q6
#SBATCH --nodes=1
#SBATCH --ntasks=8
#SBATCH --time=00:45:00
#SBATCH --partition=debug
#SBATCH --output=q6_%j.out

set -e
module load hpcx-2.7.0/hpcx-ompi
cd "$SLURM_SUBMIT_DIR"
g++ -O2 -std=c++17 q6_serial.cpp -o q6_serial
mpic++ -O2 -std=c++17 q6_mpi.cpp -o q6_mpi

echo 'Q6 correctness'
for name in sample indirect multiple isolated; do
    ./q6_serial < tests/$name.in > .serial
    diff -u tests/$name.expected .serial
    for p in 1 2 4 8; do
        srun -n $p ./q6_mpi < tests/$name.in > .mpi
        diff -u .serial .mpi
    done
    echo "$name PASS"
done

mkdir -p data
python3 generate.py 10000 50000 12345 > data/10000.in
python3 generate.py 50000 250000 12345 > data/50000.in
python3 generate.py 100000 500000 12345 > data/100000.in

echo 'size,p,time,baseline,speedup,efficiency' > q6_metrics.csv
for n in 10000 50000 100000; do
    t1=''
    for p in 1 2 4 8; do
        /usr/bin/time -f '%e' -o .time srun -n $p ./q6_mpi < data/$n.in > /dev/null
        t=$(cat .time)
        [ $p -eq 1 ] && t1=$t
        speed=$(awk -v a=$t1 -v b=$t 'BEGIN{printf "%.4f", a/b}')
        eff=$(awk -v s=$speed -v p=$p 'BEGIN{printf "%.4f", s/p}')
        echo "$n,$p,$t,$t1,$speed,$eff" >> q6_metrics.csv
    done
done
cat q6_metrics.csv
