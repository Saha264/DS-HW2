#!/bin/bash
#SBATCH --job-name=q7
#SBATCH --nodes=1
#SBATCH --ntasks=8
#SBATCH --time=01:00:00
#SBATCH --partition=debug
#SBATCH --output=q7_%j.out

set -e
module load hpcx-2.7.0/hpcx-ompi
cd "$SLURM_SUBMIT_DIR"
g++ -O2 -std=c++17 Server_log_Seq.c++ -o server_seq
mpic++ -O2 -std=c++17 Server_log_MPI.c++ -o server_mpi

echo 'Q7 correctness'
./server_seq < tests/basic.in > .seq
diff -u tests/basic.expected .seq
for p in 1 2 4 8; do
    srun -n $p ./server_mpi < tests/basic.in > .mpi
    diff -u .seq .mpi
done
./server_seq < tests/provided_500.in > .seq
for p in 1 2 4 8; do
    srun -n $p ./server_mpi < tests/provided_500.in > .mpi
    diff -u .seq .mpi
done
echo 'PASS'

mkdir -p data
for n in 100000 500000 1000000; do
    python3 generate.py $n 12345 > data/$n.in
done

echo 'size,p,time,baseline,speedup,efficiency' > q7_metrics.csv
for n in 100000 500000 1000000; do
    /usr/bin/time -f '%e' -o .time ./server_seq < data/$n.in > /dev/null
    seq=$(cat .time)
    for p in 1 2 4 8; do
        /usr/bin/time -f '%e' -o .time srun -n $p ./server_mpi < data/$n.in > /dev/null
        t=$(cat .time)
        speed=$(awk -v a=$seq -v b=$t 'BEGIN{printf "%.4f", a/b}')
        eff=$(awk -v s=$speed -v p=$p 'BEGIN{printf "%.4f", s/p}')
        echo "$n,$p,$t,$seq,$speed,$eff" >> q7_metrics.csv
    done
done
cat q7_metrics.csv
