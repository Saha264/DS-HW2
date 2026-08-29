# Q7 — Large-Scale Server Log Analytics



## Files

| File | Purpose |
|---|---|
| `Server_log_MPI.c++` | Parallel source (MPI) |
| `Server_log_Seq.c++` | Sequential source (plain C++) |
| `input.txt` | Sample input (500 records, K=3, S=6) |


Both programs read the same input and produce identical output.



## Build

Parallel version:

```bash
mpic++ -std=c++17 -O2 -o Server_log_MPI Server_log_MPI.c++
```

Sequential version:

```bash
g++ -std=c++17 -O2 -o Server_log_Seq Server_log_Seq.c++
```

## Run locally

Both programs read from **stdin**.

Sequential:

```bash
./Server_log_Seq < input.txt
```

Parallel, on 4 processes:

```bash
mpirun -np 4 ./Server_log_MPI < input.txt
```

If you request more processes than your machine has cores, add
`--oversubscribe`:

```bash
mpirun --oversubscribe -np 8 ./Server_log_MPI < input.txt
```

To save the output:

```bash
mpirun -np 4 ./Server_log_MPI < input.txt > output.txt
```

## Input format

```
N K S
timestamp server_id endpoint_id user_id status_code response_time bytes_sent
... (N lines)
```

- `N` — number of log records
- `K` — how many rows to show in each top-K list
- `S` — number of servers (IDs are `0 .. S-1`)

A request is successful if `status_code < 400`. Interval IDs are
`timestamp / 60`.

## Output format

```
TOTAL_REQUESTS <value>
SUCCESSFUL_REQUESTS <value>
FAILED_REQUESTS <value>
AVERAGE_RESPONSE_TIME <value>
MIN_RESPONSE_TIME <value>
MAX_RESPONSE_TIME <value>
TOTAL_BYTES <value>
STATUS_2XX <value>
STATUS_3XX <value>
STATUS_4XX <value>
STATUS_5XX <value>
BUSIEST_INTERVAL <interval_id> <count>
TOP_SERVERS
<server_id> <request_count> <average_response_time>
...
TOP_ENDPOINTS
<endpoint_id> <request_count> <total_bytes>
...
```

Top-K lists are sorted by decreasing count, then increasing ID.
Response times print with 2 decimal places.

## Verifying correctness

Output must be identical regardless of the number of processes. Use an odd
count so the records do not divide evenly:

```bash
mpirun --oversubscribe -np 1 ./Server_log_MPI < input.txt > a.txt
mpirun --oversubscribe -np 3 ./Server_log_MPI < input.txt > b.txt
mpirun --oversubscribe -np 7 ./Server_log_MPI < input.txt > c.txt
diff a.txt b.txt && diff a.txt c.txt && echo "OK"
```

Any difference indicates a bug in the reduction step, not in the arithmetic.

The sequential version is a useful reference for the same reason — it computes
the identical result without any of the MPI machinery:

```bash
./Server_log_Seq < input.txt > seq.txt
mpirun -np 4 ./Server_log_MPI < input.txt > par.txt
diff seq.txt par.txt && echo "OK"
```


## Notes

- Records are read and scattered in chunks of 1,000,000 so rank 0 never holds the entire input in memory.
- Server counts use a dense array of length `S`, reduced in a single
  `MPI_Reduce`. Endpoint and interval tables are sparse, so they are gathered with `MPI_Gatherv` and merged on rank 0.
- Top-K selection happens only after the global tables are assembled 

## Dataset generation and benchmark

`generate.py N [seed]` produces a reproducible synthetic log dataset. The benchmark uses seed 12345, K=5, S=64 and 256 endpoint IDs.

```bash
python3 generate.py 100000 12345 > data/100000.in
sbatch q7.slurm
```

The SLURM job verifies the sequential and MPI outputs, then benchmarks N=100000, 500000, 1000000 at P=1,2,4,8. `q7_metrics.csv` uses the sequential runtime as the speedup baseline.
