# Q6 Connected Components

`q6_serial.cpp` is the sequential DFS reference. `q6_mpi.cpp` distributes contiguous groups of vertices and adjacency lists. Each vertex begins with its own ID as a label; in each synchronous round it takes the minimum label among itself and its neighbors. `MPI_Allgatherv` shares the new labels and the algorithm stops when `MPI_Allreduce` reports no change.

## Compile

```bash
g++ -O2 -std=c++17 q6_serial.cpp -o q6_serial
mpic++ -O2 -std=c++17 q6_mpi.cpp -o q6_mpi
```

## Run

```bash
./q6_serial < tests/sample.in
mpirun -np 4 ./q6_mpi < tests/sample.in
```

## Correctness and benchmark

```bash
sbatch q6.slurm
```

The job checks four small graphs for P=1,2,4,8. Benchmark graphs use V=10000, 50000, 100000 and E=5V, with a binary-tree backbone plus fixed-seed random edges (seed 12345). Results are written to `q6_metrics.csv`.
