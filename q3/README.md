# Parallel Bitonic Sort (MPI)

Sorts a sequence of `N` integers across `P` MPI processes using bitonic sort.
Each process sorts its own chunk locally, then over `log₂P · (log₂P + 1) / 2`
stages pairs of processes exchange chunks and each keeps its correct half.
The chunks are gathered in rank order to form the sorted output.


## Compile

```bash
mpic++ -Wall -O2 -o bitonic bitonic.c++
```

## Input format

The program reads from **stdin**:

```
N
a₁ a₂ a₃ ... a_N
```

The first number is the element count `N`; the remaining `N` numbers are the
elements. Whitespace and newlines are interchangeable, so everything can go on
one line.

### Constraints

- `N` and `P` must both be powers of two
- `N` must be divisible by `P`
- Elements are integers (negatives are fine)

Violating any of these prints an error to stderr and exits with status 1.

## Run

```bash
mpirun -np <P> ./bitonic
```

### Interactive

```
$ mpirun -np 2 ./bitonic
4
4 1 3 2
1 2 3 4
```

### One-liner

```bash
echo "4  4 1 3 2" | mpirun -np 2 ./bitonic
# -> 1 2 3 4
```

### From a file

```bash
printf '8\n10 30 20 5 40 15 25 35\n' > in.txt
mpirun -np 4 ./bitonic < in.txt
# -> 5 10 15 20 25 30 35 40
```

### Large generated input

```bash
python3 -c "
import random
n = 1<<20
print(n); print(' '.join(str(random.randint(-10**9,10**9)) for _ in range(n)))
" > big.txt

mpirun -np 8 ./bitonic < big.txt > out.txt
```

Add `--oversubscribe` if `P` exceeds `nproc`.

## Running on SLURM

```bash
#!/bin/bash
#SBATCH --job-name=bitonic
#SBATCH --output=bitonic-%j.out
#SBATCH --nodes=1
#SBATCH --ntasks=8
#SBATCH --time=00:30:00

module load gcc openmpi
mpic++ -Wall -O2 -o bitonic bitonic.c++
srun --ntasks=4 ./bitonic < in.txt
```

## Correctness and benchmark

```bash
sbatch q3.slurm
```

The job checks the same N=8 case at P=1,2,4,8, then benchmarks N=65536, 262144, 1048576. The generator uses Python `random` with seed 12345. Results are written to `q3_metrics.csv`.
