#!/bin/bash
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
MODE="${1:-all}"
MPI="mpirun --oversubscribe"
PSET="1 2 4 8"

for x in g++ mpic++ mpirun python3 awk /usr/bin/time; do
    command -v "$x" >/dev/null || {
        echo "Missing: $x"
        echo "Install with: sudo apt update && sudo apt install -y build-essential openmpi-bin libopenmpi-dev python3-matplotlib"
        exit 1
    }
done

echo "Logical CPUs: $(nproc)"
echo

# ---------------- Q3 ----------------
echo "========== Q3 =========="
cd "$ROOT/q3"
mpic++ -O2 -std=c++17 bitonic.c++ -o bitonic

expected=$(xargs < tests/basic.expected)
for p in $PSET; do
    got=$($MPI -np "$p" ./bitonic < tests/basic.in | xargs)
    [ "$got" = "$expected" ] || {
        echo "Q3 FAIL P=$p"
        echo "expected: $expected"
        echo "got:      $got"
        exit 1
    }
    echo "Q3 P=$p PASS"
done

# ---------------- Q6 ----------------
echo
echo "========== Q6 =========="
cd "$ROOT/q6"
g++ -O2 -std=c++17 q6_serial.cpp -o q6_serial
mpic++ -O2 -std=c++17 q6_mpi.cpp -o q6_mpi

for name in sample indirect multiple isolated; do
    ./q6_serial < "tests/$name.in" > .serial
    diff -u "tests/$name.expected" .serial >/dev/null

    for p in $PSET; do
        $MPI -np "$p" ./q6_mpi < "tests/$name.in" > .mpi
        diff -u .serial .mpi >/dev/null || {
            echo "Q6 FAIL test=$name P=$p"
            exit 1
        }
    done
    echo "Q6 $name PASS"
done

# ---------------- Q7 ----------------
echo
echo "========== Q7 =========="
cd "$ROOT/q7"
g++ -O2 -std=c++17 Server_log_Seq.c++ -o server_seq
mpic++ -O2 -std=c++17 Server_log_MPI.c++ -o server_mpi

./server_seq < tests/basic.in > .seq
diff -u tests/basic.expected .seq >/dev/null
for p in $PSET; do
    $MPI -np "$p" ./server_mpi < tests/basic.in > .mpi
    diff -u .seq .mpi >/dev/null || {
        echo "Q7 basic FAIL P=$p"
        exit 1
    }
    echo "Q7 basic P=$p PASS"
done

./server_seq < tests/provided_500.in > .seq
for p in $PSET; do
    $MPI -np "$p" ./server_mpi < tests/provided_500.in > .mpi
    diff -u .seq .mpi >/dev/null || {
        echo "Q7 provided_500 FAIL P=$p"
        exit 1
    }
done
echo "Q7 provided_500 PASS"

echo
echo "ALL CORRECTNESS TESTS PASSED"

if [ "$MODE" = "test" ]; then
    exit 0
fi

# ---------------- Benchmarks ----------------
echo
echo "========== BENCHMARKS =========="

# Q3: baseline = MPI P=1
cd "$ROOT/q3"
mkdir -p data
for n in 65536 262144 1048576; do
    python3 generate.py "$n" 12345 > "data/$n.in"
done

echo 'size,p,time,baseline,speedup,efficiency' > q3_metrics.csv
for n in 65536 262144 1048576; do
    t1=""
    for p in $PSET; do
        /usr/bin/time -f '%e' -o .time $MPI -np "$p" ./bitonic < "data/$n.in" > /dev/null
        t=$(cat .time)
        [ "$p" -eq 1 ] && t1="$t"
        speed=$(awk -v a="$t1" -v b="$t" 'BEGIN{printf "%.4f", a/b}')
        eff=$(awk -v s="$speed" -v p="$p" 'BEGIN{printf "%.4f", s/p}')
        echo "$n,$p,$t,$t1,$speed,$eff" >> q3_metrics.csv
    done
done

echo "Q3 metrics: $ROOT/q3/q3_metrics.csv"

# Q6: baseline = MPI P=1
cd "$ROOT/q6"
mkdir -p data
python3 generate.py 10000 50000 12345 > data/10000.in
python3 generate.py 50000 250000 12345 > data/50000.in
python3 generate.py 100000 500000 12345 > data/100000.in

echo 'size,p,time,baseline,speedup,efficiency' > q6_metrics.csv
for n in 10000 50000 100000; do
    t1=""
    for p in $PSET; do
        /usr/bin/time -f '%e' -o .time $MPI -np "$p" ./q6_mpi < "data/$n.in" > /dev/null
        t=$(cat .time)
        [ "$p" -eq 1 ] && t1="$t"
        speed=$(awk -v a="$t1" -v b="$t" 'BEGIN{printf "%.4f", a/b}')
        eff=$(awk -v s="$speed" -v p="$p" 'BEGIN{printf "%.4f", s/p}')
        echo "$n,$p,$t,$t1,$speed,$eff" >> q6_metrics.csv
    done
done

echo "Q6 metrics: $ROOT/q6/q6_metrics.csv"

# Q7: baseline = sequential implementation
cd "$ROOT/q7"
mkdir -p data
for n in 100000 500000 1000000; do
    python3 generate.py "$n" 12345 > "data/$n.in"
done

echo 'size,p,time,baseline,speedup,efficiency' > q7_metrics.csv
for n in 100000 500000 1000000; do
    /usr/bin/time -f '%e' -o .time ./server_seq < "data/$n.in" > /dev/null
    seq=$(cat .time)

    for p in $PSET; do
        /usr/bin/time -f '%e' -o .time $MPI -np "$p" ./server_mpi < "data/$n.in" > /dev/null
        t=$(cat .time)
        speed=$(awk -v a="$seq" -v b="$t" 'BEGIN{printf "%.4f", a/b}')
        eff=$(awk -v s="$speed" -v p="$p" 'BEGIN{printf "%.4f", s/p}')
        echo "$n,$p,$t,$seq,$speed,$eff" >> q7_metrics.csv
    done
done

echo "Q7 metrics: $ROOT/q7/q7_metrics.csv"

# Plots
if python3 -c 'import matplotlib' >/dev/null 2>&1; then
    cd "$ROOT"
    python3 plot_metrics.py q3/q3_metrics.csv
    python3 plot_metrics.py q6/q6_metrics.csv
    python3 plot_metrics.py q7/q7_metrics.csv
    echo "Plots generated."
else
    echo "matplotlib missing; CSV files are complete. Install python3-matplotlib and run plot_metrics.py manually."
fi

echo
echo "========== DONE =========="
cat "$ROOT/q3/q3_metrics.csv"
echo
cat "$ROOT/q6/q6_metrics.csv"
echo
cat "$ROOT/q7/q7_metrics.csv"
