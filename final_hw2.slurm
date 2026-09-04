#!/bin/bash
#SBATCH --job-name=ds-hw2-final
#SBATCH --partition=debug
#SBATCH --nodes=1
#SBATCH --ntasks=8
#SBATCH --cpus-per-task=1
#SBATCH --hint=nomultithread
#SBATCH --mem=8G
#SBATCH --time=01:30:00
#SBATCH --output=ds_hw2_%j.out

set -euo pipefail

# Benchmark policy: one warm-up + 5 measured runs; report the median.
REPEATS="${REPEATS:-5}"
WARMUP_RUNS="${WARMUP_RUNS:-1}"

# -----------------------------------------------------------------------------
# Usage:
#   Put this file in the root of the homework repository and run:
#       sbatch final_hw2_fixed.slurm
#
# Expected source layout (either naming style is accepted):
#   DS_HW2_Q3/bitonic.c++              or q3/bitonic.c++
#   DS_HW2_Q6/q6_serial.cpp            or q6/q6_serial.cpp
#   DS_HW2_Q6/q6_mpi.cpp               or q6/q6_mpi.cpp
#   DS_HW2_Q7/Server_log_Seq.c++       or q7/Server_log_Seq.c++
#   DS_HW2_Q7/Server_log_MPI.c++       or q7/Server_log_MPI.c++
#
# Final results are written to:
#   $HOME/ds_hw2_results_<jobid>/
# -----------------------------------------------------------------------------

ROOT="${SLURM_SUBMIT_DIR:-$PWD}"
RESULTS="$HOME/ds_hw2_results_${SLURM_JOB_ID}"
WORK="${SLURM_TMPDIR:-/tmp/${USER}_ds_hw2_${SLURM_JOB_ID}}"
BIN="$WORK/bin"
TESTS="$WORK/tests"
DATA="$WORK/data"
MPI_TMP="$WORK/mpi-tmp"

mkdir -p "$RESULTS" "$RESULTS/tests" "$BIN" "$TESTS" "$DATA" "$MPI_TMP"
export TMPDIR="$MPI_TMP"
exec > >(tee -a "$RESULTS/job.log") 2>&1

# ---- MPI environment ---------------------------------------------------------
if ! type module >/dev/null 2>&1; then
    source /etc/profile.d/modules.sh 2>/dev/null || true
fi
module purge
module load hpcx-2.7.0/hpcx-ompi
set -Eeuo pipefail

MPI_CXX="$(command -v mpicxx || command -v mpic++ || true)"
if [[ -z "$MPI_CXX" ]]; then
    echo "ERROR: MPI compiler not found after loading hpcx-2.7.0/hpcx-ompi"
    exit 1
fi

pick_file() {
    local var="$1"; shift
    local f
    for f in "$@"; do
        if [[ -f "$f" ]]; then
            printf -v "$var" '%s' "$f"
            return 0
        fi
    done
    echo "ERROR: required source file not found. Tried: $*"
    exit 1
}

pick_file Q3_SRC \
    "$ROOT/DS_HW2_Q3/bitonic.c++" \
    "$ROOT/q3/bitonic.c++"

pick_file Q6_SERIAL_SRC \
    "$ROOT/DS_HW2_Q6/q6_serial.cpp" \
    "$ROOT/q6/q6_serial.cpp"

pick_file Q6_MPI_SRC \
    "$ROOT/DS_HW2_Q6/q6_mpi.cpp" \
    "$ROOT/q6/q6_mpi.cpp"

pick_file Q7_SERIAL_SRC \
    "$ROOT/DS_HW2_Q7/Server_log_Seq.c++" \
    "$ROOT/q7/Server_log_Seq.c++"

pick_file Q7_MPI_SRC \
    "$ROOT/DS_HW2_Q7/Server_log_MPI.c++" \
    "$ROOT/q7/Server_log_MPI.c++"

Q7_PROVIDED_INPUT=""
for f in "$ROOT/DS_HW2_Q7/input.txt" "$ROOT/q7/input.txt"; do
    [[ -f "$f" ]] && Q7_PROVIDED_INPUT="$f" && break
done

# ---- record machine/job information -----------------------------------------
{
    echo "Job ID: $SLURM_JOB_ID"
    echo "Node: $(hostname)"
    echo "Date: $(date)"
    echo "Submit dir: $ROOT"
    echo "Tasks allocated: ${SLURM_NTASKS:-unknown}"
    echo "CPUs on node allocation: ${SLURM_CPUS_ON_NODE:-unknown}"
    echo "MPI compiler: $MPI_CXX"
    echo "mpirun path: $(command -v mpirun || true)"
    mpirun --version 2>/dev/null | head -2 || true
    echo "Slurm MPI plugins:"
    srun --mpi=list 2>&1 || true
    "$MPI_CXX" --version | head -1
    echo
    lscpu | grep -E '^Model name|^CPU\(s\)|^Thread\(s\) per core|^Core\(s\) per socket|^Socket\(s\)'
} > "$RESULTS/environment.txt"
cat "$RESULTS/environment.txt"

# ---- compile ----------------------------------------------------------------
echo
echo "========== COMPILING =========="

g++      -O2 -std=c++17 "$Q6_SERIAL_SRC" -o "$BIN/q6_serial"
g++      -O2 -std=c++17 "$Q7_SERIAL_SRC" -o "$BIN/q7_serial"
"$MPI_CXX" -O2 -std=c++17 "$Q3_SRC"       -o "$BIN/q3"
"$MPI_CXX" -O2 -std=c++17 "$Q6_MPI_SRC"   -o "$BIN/q6_mpi"
"$MPI_CXX" -O2 -std=c++17 "$Q7_MPI_SRC"   -o "$BIN/q7_mpi"

echo "Compilation PASS"

# Keep a source snapshot with the measurements so the result archive is self-contained.
mkdir -p "$RESULTS/source_snapshot"
cp "$Q3_SRC"        "$RESULTS/source_snapshot/q3_bitonic.cpp"
cp "$Q6_SERIAL_SRC" "$RESULTS/source_snapshot/q6_serial.cpp"
cp "$Q6_MPI_SRC"    "$RESULTS/source_snapshot/q6_mpi.cpp"
cp "$Q7_SERIAL_SRC" "$RESULTS/source_snapshot/q7_serial.cpp"
cp "$Q7_MPI_SRC"    "$RESULTS/source_snapshot/q7_mpi.cpp"

# High-resolution external wall-clock timer.  /usr/bin/time %e only gives
# centisecond-scale output on this cluster, which is too coarse for sub-second runs.
cat > "$WORK/time_exec.py" <<'PY_TIMER'
import subprocess, sys, time
out = sys.argv[1]
cmd = sys.argv[2:]
t0 = time.perf_counter()
rc = subprocess.call(cmd)
dt = time.perf_counter() - t0
with open(out, 'w') as f:
    f.write(f"{dt:.6f}\n")
sys.exit(rc)
PY_TIMER

# PMPI interposition profiler.  It measures time spent inside common MPI calls
# without requiring changes to the homework source code.  Profiling runs are
# separate from benchmark runs so the profiler cannot contaminate reported speedups.
cat > "$WORK/mpi_profile.cpp" <<'CPP_MPI_PROFILE'
#include <mpi.h>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <vector>

static double g_start = 0.0;
static double g_mpi = 0.0;
static bool g_active = false;

static inline double tic() { return PMPI_Wtime(); }
static inline void add(double t0) { if (g_active) g_mpi += PMPI_Wtime() - t0; }

extern "C" int MPI_Init(int *argc, char ***argv) {
    int rc = PMPI_Init(argc, argv);
    if (rc == MPI_SUCCESS) { g_start = PMPI_Wtime(); g_active = true; }
    return rc;
}

extern "C" int MPI_Init_thread(int *argc, char ***argv, int required, int *provided) {
    int rc = PMPI_Init_thread(argc, argv, required, provided);
    if (rc == MPI_SUCCESS) { g_start = PMPI_Wtime(); g_active = true; }
    return rc;
}

#define WRAP_MPI(NAME, ARGS, CALLARGS) \
extern "C" int MPI_##NAME ARGS { \
    double t0 = tic(); \
    int rc = PMPI_##NAME CALLARGS; \
    add(t0); \
    return rc; \
}

WRAP_MPI(Barrier, (MPI_Comm comm), (comm))
WRAP_MPI(Bcast, (void *buffer, int count, MPI_Datatype datatype, int root, MPI_Comm comm),
         (buffer, count, datatype, root, comm))
WRAP_MPI(Scatter, (const void *sendbuf, int sendcount, MPI_Datatype sendtype,
                   void *recvbuf, int recvcount, MPI_Datatype recvtype, int root, MPI_Comm comm),
         (sendbuf, sendcount, sendtype, recvbuf, recvcount, recvtype, root, comm))
WRAP_MPI(Scatterv, (const void *sendbuf, const int sendcounts[], const int displs[], MPI_Datatype sendtype,
                    void *recvbuf, int recvcount, MPI_Datatype recvtype, int root, MPI_Comm comm),
         (sendbuf, sendcounts, displs, sendtype, recvbuf, recvcount, recvtype, root, comm))
WRAP_MPI(Gather, (const void *sendbuf, int sendcount, MPI_Datatype sendtype,
                  void *recvbuf, int recvcount, MPI_Datatype recvtype, int root, MPI_Comm comm),
         (sendbuf, sendcount, sendtype, recvbuf, recvcount, recvtype, root, comm))
WRAP_MPI(Gatherv, (const void *sendbuf, int sendcount, MPI_Datatype sendtype,
                   void *recvbuf, const int recvcounts[], const int displs[], MPI_Datatype recvtype,
                   int root, MPI_Comm comm),
         (sendbuf, sendcount, sendtype, recvbuf, recvcounts, displs, recvtype, root, comm))
WRAP_MPI(Allgather, (const void *sendbuf, int sendcount, MPI_Datatype sendtype,
                     void *recvbuf, int recvcount, MPI_Datatype recvtype, MPI_Comm comm),
         (sendbuf, sendcount, sendtype, recvbuf, recvcount, recvtype, comm))
WRAP_MPI(Allgatherv, (const void *sendbuf, int sendcount, MPI_Datatype sendtype,
                      void *recvbuf, const int recvcounts[], const int displs[], MPI_Datatype recvtype,
                      MPI_Comm comm),
         (sendbuf, sendcount, sendtype, recvbuf, recvcounts, displs, recvtype, comm))
WRAP_MPI(Alltoall, (const void *sendbuf, int sendcount, MPI_Datatype sendtype,
                    void *recvbuf, int recvcount, MPI_Datatype recvtype, MPI_Comm comm),
         (sendbuf, sendcount, sendtype, recvbuf, recvcount, recvtype, comm))
WRAP_MPI(Alltoallv, (const void *sendbuf, const int sendcounts[], const int sdispls[], MPI_Datatype sendtype,
                     void *recvbuf, const int recvcounts[], const int rdispls[], MPI_Datatype recvtype,
                     MPI_Comm comm),
         (sendbuf, sendcounts, sdispls, sendtype, recvbuf, recvcounts, rdispls, recvtype, comm))
WRAP_MPI(Reduce, (const void *sendbuf, void *recvbuf, int count, MPI_Datatype datatype,
                  MPI_Op op, int root, MPI_Comm comm),
         (sendbuf, recvbuf, count, datatype, op, root, comm))
WRAP_MPI(Allreduce, (const void *sendbuf, void *recvbuf, int count, MPI_Datatype datatype,
                     MPI_Op op, MPI_Comm comm),
         (sendbuf, recvbuf, count, datatype, op, comm))
WRAP_MPI(Send, (const void *buf, int count, MPI_Datatype datatype, int dest, int tag, MPI_Comm comm),
         (buf, count, datatype, dest, tag, comm))
WRAP_MPI(Recv, (void *buf, int count, MPI_Datatype datatype, int source, int tag, MPI_Comm comm,
                MPI_Status *status),
         (buf, count, datatype, source, tag, comm, status))
WRAP_MPI(Sendrecv, (const void *sendbuf, int sendcount, MPI_Datatype sendtype, int dest, int sendtag,
                    void *recvbuf, int recvcount, MPI_Datatype recvtype, int source, int recvtag,
                    MPI_Comm comm, MPI_Status *status),
         (sendbuf, sendcount, sendtype, dest, sendtag, recvbuf, recvcount, recvtype,
          source, recvtag, comm, status))
WRAP_MPI(Isend, (const void *buf, int count, MPI_Datatype datatype, int dest, int tag,
                 MPI_Comm comm, MPI_Request *request),
         (buf, count, datatype, dest, tag, comm, request))
WRAP_MPI(Irecv, (void *buf, int count, MPI_Datatype datatype, int source, int tag,
                 MPI_Comm comm, MPI_Request *request),
         (buf, count, datatype, source, tag, comm, request))
WRAP_MPI(Wait, (MPI_Request *request, MPI_Status *status), (request, status))
WRAP_MPI(Waitall, (int count, MPI_Request array_of_requests[], MPI_Status array_of_statuses[]),
         (count, array_of_requests, array_of_statuses))
WRAP_MPI(Test, (MPI_Request *request, int *flag, MPI_Status *status), (request, flag, status))
WRAP_MPI(Probe, (int source, int tag, MPI_Comm comm, MPI_Status *status), (source, tag, comm, status))

extern "C" int MPI_Finalize() {
    double total = g_active ? PMPI_Wtime() - g_start : 0.0;
    int rank = 0, size = 1;
    PMPI_Comm_rank(MPI_COMM_WORLD, &rank);
    PMPI_Comm_size(MPI_COMM_WORLD, &size);

    std::vector<double> totals, mpis;
    if (rank == 0) { totals.resize(size); mpis.resize(size); }
    PMPI_Gather(&total, 1, MPI_DOUBLE, rank == 0 ? totals.data() : nullptr, 1, MPI_DOUBLE, 0, MPI_COMM_WORLD);
    PMPI_Gather(&g_mpi, 1, MPI_DOUBLE, rank == 0 ? mpis.data() : nullptr, 1, MPI_DOUBLE, 0, MPI_COMM_WORLD);

    if (rank == 0) {
        double max_elapsed = 0.0, mean_elapsed = 0.0;
        double max_mpi = 0.0, mean_mpi = 0.0, mean_frac = 0.0;
        int critical = 0;
        for (int i = 0; i < size; ++i) {
            mean_elapsed += totals[i];
            mean_mpi += mpis[i];
            max_mpi = std::max(max_mpi, mpis[i]);
            if (totals[i] > max_elapsed) { max_elapsed = totals[i]; critical = i; }
            if (totals[i] > 0.0) mean_frac += mpis[i] / totals[i];
        }
        mean_elapsed /= size;
        mean_mpi /= size;
        mean_frac /= size;
        double mean_compute = mean_elapsed - mean_mpi;
        double crit_frac = totals[critical] > 0.0 ? mpis[critical] / totals[critical] : 0.0;
        const char *path = std::getenv("MPI_PROFILE_OUT");
        const char *tag = std::getenv("MPI_PROFILE_TAG");
        if (path && *path) {
            if (FILE *f = std::fopen(path, "a")) {
                std::fprintf(f, "%s,%d,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f\n",
                             tag ? tag : "run", size, max_elapsed, mean_elapsed,
                             mean_mpi, max_mpi, mean_compute, mean_frac,
                             1.0 - mean_frac, crit_frac);
                std::fclose(f);
            }
        }
    }

    g_active = false;
    return PMPI_Finalize();
}
CPP_MPI_PROFILE
"$MPI_CXX" -O2 -std=c++17 -fPIC -shared "$WORK/mpi_profile.cpp" -o "$BIN/libmpi_profile.so"

# ---- select and verify the MPI launcher --------------------------------------
# Open MPI 4.0.x must be launched with an explicit Slurm PMIx plugin when using
# srun.  This HPC-X release also has a known PMIx shared-datastore failure, so
# mpirun is retained only as a fallback with PMIX_MCA_gds=hash.
cat > "$WORK/mpi_probe.cpp" <<'CPP_MPI_PROBE'
#include <mpi.h>
#include <iostream>
int main(int argc, char** argv) {
    MPI_Init(&argc, &argv);
    int rank = 0, size = 0;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);
    if (rank == 0) std::cout << size << "\n";
    MPI_Finalize();
    return 0;
}
CPP_MPI_PROBE
"$MPI_CXX" -O2 -std=c++17 "$WORK/mpi_probe.cpp" -o "$BIN/mpi_probe"

MPI_LIST="$(srun --mpi=list 2>&1 || true)"
printf '%s\n' "$MPI_LIST" > "$RESULTS/slurm_mpi_plugins.txt"

LAUNCHER=""
MPI_PLUGIN=""

has_fatal_mpi_error() {
    local f="$1"
    grep -Eq 'MPI_ERRORS_ARE_FATAL|MPI_Init|PMIX ERROR: (OUT-OF-RESOURCE|NOT-FOUND|ERROR)|mpirun detected that one or more processes exited|srun: error:' "$f"
}

try_srun_plugin() {
    local plugin="$1"
    local out="$RESULTS/launcher_probe_srun_${plugin}.out"
    local err="$RESULTS/launcher_probe_srun_${plugin}.err"

    if timeout 20s srun --kill-on-bad-exit=1 --mpi="$plugin" --cpu-bind=cores -N 1 -n 2 \
            "$BIN/mpi_probe" >"$out" 2>"$err" \
       && grep -qx '2' "$out" \
       && ! has_fatal_mpi_error "$err"; then
        LAUNCHER="srun"
        MPI_PLUGIN="$plugin"
        return 0
    fi
    return 1
}

# HPC-X 2.7 / Open MPI 4.0.4 uses a PMIx 3.x client, so prefer pmix_v3.
if grep -q 'pmix_v3' <<< "$MPI_LIST" && try_srun_plugin pmix_v3; then
    :
elif grep -Eq '(^|[[:space:]])pmix($|[[:space:]])' <<< "$MPI_LIST" \
     && try_srun_plugin pmix; then
    :
else
    export PMIX_MCA_gds=hash
    if timeout 20s mpirun -np 2 --bind-to core "$BIN/mpi_probe" \
            >"$RESULTS/launcher_probe_mpirun.out" \
            2>"$RESULTS/launcher_probe_mpirun.err" \
       && grep -qx '2' "$RESULTS/launcher_probe_mpirun.out" \
       && ! has_fatal_mpi_error "$RESULTS/launcher_probe_mpirun.err"; then
        LAUNCHER="mpirun"
    elif timeout 20s mpirun -np 2 "$BIN/mpi_probe" \
            >"$RESULTS/launcher_probe_mpirun_unbound.out" \
            2>"$RESULTS/launcher_probe_mpirun_unbound.err" \
         && grep -qx '2' "$RESULTS/launcher_probe_mpirun_unbound.out" \
         && ! has_fatal_mpi_error "$RESULTS/launcher_probe_mpirun_unbound.err"; then
        LAUNCHER="mpirun-unbound"
    else
        echo "ERROR: neither Slurm PMIx nor the mpirun PMIx workaround could launch two ranks."
        echo "Slurm MPI plugins were:"
        printf '%s\n' "$MPI_LIST"
        echo "Probe logs are in $RESULTS/launcher_probe_*"
        exit 1
    fi
fi

echo "Selected MPI launcher: $LAUNCHER${MPI_PLUGIN:+ --mpi=$MPI_PLUGIN}" | tee "$RESULTS/launcher.txt"

# ---- helpers ----------------------------------------------------------------
build_mpi_cmd() {
    local p="$1" exe="$2"
    if [[ "$LAUNCHER" == "srun" ]]; then
        MPI_CMD=(timeout 300s srun --kill-on-bad-exit=1 --mpi="$MPI_PLUGIN" --cpu-bind=cores -N 1 -n "$p" "$exe")
    elif [[ "$LAUNCHER" == "mpirun" ]]; then
        MPI_CMD=(timeout 300s mpirun -np "$p" --bind-to core "$exe")
    else
        MPI_CMD=(timeout 300s mpirun -np "$p" "$exe")
    fi
}

build_profile_cmd() {
    local p="$1" exe="$2" out="$3" tag="$4"
    local lib="$BIN/libmpi_profile.so"
    if [[ "$LAUNCHER" == "srun" ]]; then
        MPI_PROFILE_CMD=(timeout 300s srun --kill-on-bad-exit=1 --mpi="$MPI_PLUGIN" --cpu-bind=cores \
            --export="ALL,LD_PRELOAD=$lib,MPI_PROFILE_OUT=$out,MPI_PROFILE_TAG=$tag" \
            -N 1 -n "$p" "$exe")
    elif [[ "$LAUNCHER" == "mpirun" ]]; then
        MPI_PROFILE_CMD=(timeout 300s mpirun -np "$p" --bind-to core \
            -x "LD_PRELOAD=$lib" -x "MPI_PROFILE_OUT=$out" -x "MPI_PROFILE_TAG=$tag" "$exe")
    else
        MPI_PROFILE_CMD=(timeout 300s mpirun -np "$p" \
            -x "LD_PRELOAD=$lib" -x "MPI_PROFILE_OUT=$out" -x "MPI_PROFILE_TAG=$tag" "$exe")
    fi
}

run_mpi() {
    local p="$1" exe="$2" input="$3" output="$4"
    local err="${output}.err"
    build_mpi_cmd "$p" "$exe"

    if ! "${MPI_CMD[@]}" < "$input" > "$output" 2> "$err"; then
        echo "ERROR: MPI launch failed: P=$p executable=$exe"
        cat "$err"
        exit 1
    fi
    if has_fatal_mpi_error "$err"; then
        echo "ERROR: fatal MPI/PMIx output: P=$p executable=$exe"
        cat "$err"
        exit 1
    fi
}

mpi_time_once() {
    local p="$1" exe="$2" input="$3"
    local tf="$WORK/time_mpi_${p}_$$.txt"
    local err="$WORK/time_mpi_${p}_$$.err"
    local t
    build_mpi_cmd "$p" "$exe"

    if ! python3 "$WORK/time_exec.py" "$tf" "${MPI_CMD[@]}" < "$input" > /dev/null 2> "$err"; then
        echo "ERROR: timed MPI launch failed: P=$p executable=$exe" >&2
        cat "$err" >&2
        return 1
    fi
    if has_fatal_mpi_error "$err"; then
        echo "ERROR: fatal MPI/PMIx output during timing: P=$p executable=$exe" >&2
        cat "$err" >&2
        return 1
    fi
    t="$(tail -n 1 "$tf")"
    [[ "$t" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "ERROR: invalid timing '$t'" >&2; return 1; }
    printf '%s\n' "$t"
}

serial_time_once() {
    local exe="$1" input="$2"
    local tf="$WORK/time_serial_$$.txt"
    local err="$WORK/time_serial_$$.err"
    local t

    if ! python3 "$WORK/time_exec.py" "$tf" "$exe" < "$input" > /dev/null 2> "$err"; then
        echo "ERROR: timed serial run failed: executable=$exe" >&2
        cat "$err" >&2
        return 1
    fi
    t="$(tail -n 1 "$tf")"
    [[ "$t" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "ERROR: invalid serial timing '$t'" >&2; return 1; }
    printf '%s\n' "$t"
}

median_values() {
    python3 - "$@" <<'PY_MEDIAN'
import statistics, sys
x = [float(v) for v in sys.argv[1:]]
print(f"{statistics.median(x):.6f}")
PY_MEDIAN
}

benchmark_mpi() {
    local label="$1" p="$2" exe="$3" input="$4" samples_csv="$5"
    local rep t
    local vals=()
    for ((rep=1; rep<=WARMUP_RUNS; ++rep)); do
        mpi_time_once "$p" "$exe" "$input" >/dev/null
    done
    for ((rep=1; rep<=REPEATS; ++rep)); do
        t="$(mpi_time_once "$p" "$exe" "$input")"
        vals+=("$t")
        printf '%s,%d,%d,%.6f\n' "$label" "$p" "$rep" "$t" >> "$samples_csv"
    done
    median_values "${vals[@]}"
}

benchmark_serial() {
    local label="$1" exe="$2" input="$3" samples_csv="$4"
    local rep t
    local vals=()
    for ((rep=1; rep<=WARMUP_RUNS; ++rep)); do
        serial_time_once "$exe" "$input" >/dev/null
    done
    for ((rep=1; rep<=REPEATS; ++rep)); do
        t="$(serial_time_once "$exe" "$input")"
        vals+=("$t")
        printf '%s,%d,%.6f\n' "$label" "$rep" "$t" >> "$samples_csv"
    done
    median_values "${vals[@]}"
}

profile_mpi() {
    local tag="$1" p="$2" exe="$3" input="$4" out="$5"
    local err="$WORK/profile_${p}_$$.err"
    local before after
    before="$(wc -l < "$out")"
    build_profile_cmd "$p" "$exe" "$out" "$tag"
    if ! "${MPI_PROFILE_CMD[@]}" < "$input" > /dev/null 2> "$err"; then
        echo "ERROR: MPI profiling run failed: tag=$tag P=$p executable=$exe" >&2
        cat "$err" >&2
        return 1
    fi
    if has_fatal_mpi_error "$err" || grep -Eq 'cannot be preloaded|ERROR: ld.so' "$err"; then
        echo "ERROR: fatal MPI/PMIx/profiler output during profiling: tag=$tag P=$p" >&2
        cat "$err" >&2
        return 1
    fi
    after="$(wc -l < "$out")"
    if (( after <= before )); then
        echo "ERROR: PMPI profiler produced no CSV row: tag=$tag P=$p" >&2
        cat "$err" >&2
        return 1
    fi
}

compare_outputs() {
    local expected="$1" actual="$2" label="$3"
    if ! diff -w "$expected" "$actual" > "$RESULTS/tests/${label}.diff"; then
        echo "ERROR: $label produced incorrect output"
        echo "Expected:"
        cat "$expected"
        echo "Actual:"
        cat "$actual"
        exit 1
    fi
    rm -f "$RESULTS/tests/${label}.diff"
}

metric_row() {
    local size="$1" p="$2" t="$3" base="$4"
    if [[ ! "$t" =~ ^[0-9]+([.][0-9]+)?$ ]] \
       || [[ ! "$base" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        echo "ERROR: refusing invalid metric values: time='$t' baseline='$base'" >&2
        exit 1
    fi
    awk -v s="$size" -v p="$p" -v t="$t" -v b="$base" \
        'BEGIN { if (t <= 0 || b <= 0) exit 2; sp=b/t; ef=sp/p; printf "%s,%d,%.6f,%.6f,%.6f,%.6f\n", s,p,t,b,sp,ef }'
}

# =============================================================================
# CORRECTNESS TESTS
# =============================================================================
echo
echo "========== CORRECTNESS TESTS =========="
CORRECT="$RESULTS/correctness.txt"
: > "$CORRECT"

# ---- Q3 ----------------------------------------------------------------------
cat > "$TESTS/q3.txt" <<'EOF_Q3'
8
5 -1 5 3 0 -7 2 2
EOF_Q3

echo "-7 -1 0 2 2 3 5 5" > "$TESTS/q3_expected.txt"
for p in 1 2 4 8; do
    run_mpi "$p" "$BIN/q3" "$TESTS/q3.txt" "$TESTS/q3_p${p}.out"
    compare_outputs "$TESTS/q3_expected.txt" "$TESTS/q3_p${p}.out" "q3_p${p}"
    echo "Q3 P=$p PASS" | tee -a "$CORRECT"
done

# ---- Q6 ----------------------------------------------------------------------
cat > "$TESTS/q6_sample.txt" <<'EOF_Q6A'
5
1 1
1 0
2 3 4
1 2
1 2
EOF_Q6A

cat > "$TESTS/q6_indirect.txt" <<'EOF_Q6B'
5
1 2
1 2
2 0 1
0
0
EOF_Q6B

cat > "$TESTS/q6_multiple.txt" <<'EOF_Q6C'
8
1 7
1 6
1 5
1 7
1 5
2 2 4
1 1
2 0 3
EOF_Q6C

cat > "$TESTS/q6_isolated.txt" <<'EOF_Q6D'
6
0
0
0
0
0
0
EOF_Q6D

for name in sample indirect multiple isolated; do
    "$BIN/q6_serial" < "$TESTS/q6_${name}.txt" > "$TESTS/q6_${name}_expected.out"
    for p in 1 2 4 8; do
        run_mpi "$p" "$BIN/q6_mpi" "$TESTS/q6_${name}.txt" "$TESTS/q6_${name}_p${p}.out"
        compare_outputs "$TESTS/q6_${name}_expected.out" "$TESTS/q6_${name}_p${p}.out" "q6_${name}_p${p}"
        echo "Q6 $name P=$p PASS" | tee -a "$CORRECT"
    done
done

# ---- Q7 ----------------------------------------------------------------------
cat > "$TESTS/q7_hand.txt" <<'EOF_Q7'
8 2 4
1   2 5 100 200 1.0 100
10  1 7 101 201 2.0 200
61  2 5 102 404 3.0 300
62  1 7 103 500 4.0 400
120 3 9 104 302 5.0 500
121 3 9 105 399 6.0 600
180 0 5 106 400 7.0 700
181 0 7 107 503 8.0 800
EOF_Q7

cat > "$TESTS/q7_hand_expected.txt" <<'EOF_Q7E'
TOTAL_REQUESTS 8
SUCCESSFUL_REQUESTS 4
FAILED_REQUESTS 4
AVERAGE_RESPONSE_TIME 4.50
MIN_RESPONSE_TIME 1.00
MAX_RESPONSE_TIME 8.00
TOTAL_BYTES 3600
STATUS_2XX 2
STATUS_3XX 2
STATUS_4XX 2
STATUS_5XX 2
BUSIEST_INTERVAL 0 2
TOP_SERVERS
0 2 7.50
1 2 3.00
TOP_ENDPOINTS
5 3 1100
7 3 1400
EOF_Q7E

"$BIN/q7_serial" < "$TESTS/q7_hand.txt" > "$TESTS/q7_seq.out"
compare_outputs "$TESTS/q7_hand_expected.txt" "$TESTS/q7_seq.out" "q7_serial_hand"
echo "Q7 sequential hand test PASS" | tee -a "$CORRECT"

for p in 1 2 4 8; do
    run_mpi "$p" "$BIN/q7_mpi" "$TESTS/q7_hand.txt" "$TESTS/q7_p${p}.out"
    compare_outputs "$TESTS/q7_hand_expected.txt" "$TESTS/q7_p${p}.out" "q7_hand_p${p}"
    echo "Q7 hand P=$p PASS" | tee -a "$CORRECT"
done

if [[ -n "$Q7_PROVIDED_INPUT" ]]; then
    "$BIN/q7_serial" < "$Q7_PROVIDED_INPUT" > "$TESTS/q7_provided_expected.out"
    for p in 1 2 4 8; do
        run_mpi "$p" "$BIN/q7_mpi" "$Q7_PROVIDED_INPUT" "$TESTS/q7_provided_p${p}.out"
        compare_outputs "$TESTS/q7_provided_expected.out" "$TESTS/q7_provided_p${p}.out" "q7_provided_p${p}"
        echo "Q7 provided-input P=$p PASS" | tee -a "$CORRECT"
    done
fi

cp "$TESTS"/*.txt "$RESULTS/tests/"
cp "$TESTS"/*expected* "$RESULTS/tests/" 2>/dev/null || true

echo "ALL CORRECTNESS TESTS PASSED" | tee -a "$CORRECT"

# =============================================================================
# REPRODUCIBLE GENERATORS
# =============================================================================
cat > "$RESULTS/q7_generator.py" <<'PY_Q7GEN'
#!/usr/bin/env python3
import random, sys

N = int(sys.argv[1])
out = sys.argv[2]
seed = 12345 + N
K, S = 5, 64
r = random.Random(seed)
statuses = [200, 201, 204, 301, 302, 400, 404, 500, 503]

with open(out, "w") as f:
    f.write(f"{N} {K} {S}\n")
    for i in range(N):
        timestamp = i + r.randrange(30)
        server = r.randrange(S)
        endpoint = r.randrange(256)
        user = r.randrange(1_000_000)
        status = r.choice(statuses)
        response = r.uniform(0.1, 2000.0)
        sent = r.randrange(100, 1_000_001)
        f.write(f"{timestamp} {server} {endpoint} {user} {status} {response:.3f} {sent}\n")
PY_Q7GEN
chmod +x "$RESULTS/q7_generator.py"

cat > "$RESULTS/q6_generator.py" <<'PY_Q6GEN'
#!/usr/bin/env python3
import random, sys

V, E, seed, out = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
r = random.Random(seed)
edges = set()

# A deterministic connected backbone, followed by random undirected edges.
for v in range(1, V):
    u = r.randrange(v)
    edges.add((u, v) if u < v else (v, u))

while len(edges) < E:
    u = r.randrange(V)
    v = r.randrange(V)
    if u == v:
        continue
    if u > v:
        u, v = v, u
    edges.add((u, v))

adj = [[] for _ in range(V)]
for u, v in edges:
    adj[u].append(v)
    adj[v].append(u)

with open(out, "w") as f:
    f.write(f"{V}\n")
    for a in adj:
        f.write(str(len(a)))
        if a:
            f.write(" " + " ".join(map(str, a)))
        f.write("\n")
PY_Q6GEN

# =============================================================================
# BENCHMARKS
# =============================================================================
echo
echo "========== BENCHMARKS =========="

echo "repeats=$REPEATS" > "$RESULTS/benchmark_config.txt"
echo "warmup_runs=$WARMUP_RUNS" >> "$RESULTS/benchmark_config.txt"
echo "timing=median wall-clock seconds from Python time.perf_counter() around the launched process" >> "$RESULTS/benchmark_config.txt"
echo "q3_seed=12345+N" >> "$RESULTS/benchmark_config.txt"
echo "q6_seed=12345+V; generator first creates a connected backbone then adds random undirected edges" >> "$RESULTS/benchmark_config.txt"
echo "q7_seed=12345+N; K=5; S=64" >> "$RESULTS/benchmark_config.txt"
echo "profiling=separate PMPI run on largest benchmark input; MPI_Init/Finalize excluded" >> "$RESULTS/benchmark_config.txt"

Q3_CSV="$RESULTS/q3_metrics.csv"
Q6_CSV="$RESULTS/q6_metrics.csv"
Q7_CSV="$RESULTS/q7_metrics.csv"
Q7_SERIAL_CSV="$RESULTS/q7_serial_comparison.csv"
Q3_SAMPLES="$RESULTS/q3_samples.csv"
Q6_SAMPLES="$RESULTS/q6_samples.csv"
Q7_SAMPLES="$RESULTS/q7_samples.csv"
Q7_SERIAL_SAMPLES="$RESULTS/q7_serial_samples.csv"
Q3_COMM="$RESULTS/q3_comm_compute.csv"
Q6_COMM="$RESULTS/q6_comm_compute.csv"
Q7_COMM="$RESULTS/q7_comm_compute.csv"

echo "size,p,time,baseline,speedup,efficiency" > "$Q3_CSV"
echo "size,p,time,baseline,speedup,efficiency" > "$Q6_CSV"
echo "size,p,time,baseline,speedup,efficiency" > "$Q7_CSV"
echo "size,serial_time,p,mpi_time,mpi_speedup_vs_serial,mpi_slowdown_vs_serial" > "$Q7_SERIAL_CSV"
echo "size,p,rep,time" > "$Q3_SAMPLES"
echo "size,p,rep,time" > "$Q6_SAMPLES"
echo "size,p,rep,time" > "$Q7_SAMPLES"
echo "size,rep,time" > "$Q7_SERIAL_SAMPLES"
COMM_HEADER="size,p,max_rank_elapsed,mean_rank_elapsed,mean_mpi_time,max_mpi_time,mean_compute_time,mean_mpi_fraction,mean_compute_fraction,critical_rank_mpi_fraction"
echo "$COMM_HEADER" > "$Q3_COMM"
echo "$COMM_HEADER" > "$Q6_COMM"
echo "$COMM_HEADER" > "$Q7_COMM"

# ---- Q3: bitonic sort --------------------------------------------------------
for N in 262144 1048576 4194304; do
    INPUT="$DATA/q3_${N}.txt"
    python3 - "$N" "$INPUT" <<'PY_Q3GEN'
import random, sys
n, out = int(sys.argv[1]), sys.argv[2]
r = random.Random(12345 + n)
with open(out, "w") as f:
    f.write(str(n) + "\n")
    f.write(" ".join(str(r.randint(-1_000_000, 1_000_000)) for _ in range(n)))
    f.write("\n")
PY_Q3GEN

    BASE=""
    for p in 1 2 4 8; do
        T="$(benchmark_mpi "$N" "$p" "$BIN/q3" "$INPUT" "$Q3_SAMPLES")"
        [[ "$p" -eq 1 ]] && BASE="$T"
        metric_row "$N" "$p" "$T" "$BASE" >> "$Q3_CSV"
        echo "Q3 N=$N P=$p median=$T"
    done

    if [[ "$N" -eq 4194304 ]]; then
        for p in 1 2 4 8; do
            profile_mpi "$N" "$p" "$BIN/q3" "$INPUT" "$Q3_COMM"
        done
    fi
    rm -f "$INPUT"
done

# ---- Q6: connected components -----------------------------------------------
for spec in "10000 50000" "50000 250000" "100000 500000"; do
    read -r V E <<< "$spec"
    LABEL="V${V}_E${E}"
    INPUT="$DATA/q6_${V}_${E}.txt"
    SEED="$((12345 + V))"
    python3 "$RESULTS/q6_generator.py" "$V" "$E" "$SEED" "$INPUT"
    echo "$LABEL seed=$SEED" >> "$RESULTS/benchmark_config.txt"

    BASE=""
    for p in 1 2 4 8; do
        T="$(benchmark_mpi "$LABEL" "$p" "$BIN/q6_mpi" "$INPUT" "$Q6_SAMPLES")"
        [[ "$p" -eq 1 ]] && BASE="$T"
        metric_row "$LABEL" "$p" "$T" "$BASE" >> "$Q6_CSV"
        echo "Q6 V=$V E=$E P=$p median=$T"
    done

    if [[ "$V" -eq 100000 && "$E" -eq 500000 ]]; then
        for p in 1 2 4 8; do
            profile_mpi "$LABEL" "$p" "$BIN/q6_mpi" "$INPUT" "$Q6_COMM"
        done
    fi
    rm -f "$INPUT"
done

# ---- Q7: sequential comparison + MPI strong scaling -------------------------
# IMPORTANT: speedup/efficiency use MPI P=1 as the baseline, exactly as
# S(P)=T_MPI(1)/T_MPI(P).  The separate sequential program is reported in its
# own comparison table and is NOT used as the strong-scaling baseline.
for N in 100000 500000 1000000; do
    INPUT="$DATA/q7_${N}.txt"
    python3 "$RESULTS/q7_generator.py" "$N" "$INPUT"

    SEQ="$(benchmark_serial "$N" "$BIN/q7_serial" "$INPUT" "$Q7_SERIAL_SAMPLES")"
    echo "Q7 N=$N sequential median=$SEQ"

    MPI_BASE=""
    for p in 1 2 4 8; do
        T="$(benchmark_mpi "$N" "$p" "$BIN/q7_mpi" "$INPUT" "$Q7_SAMPLES")"
        [[ "$p" -eq 1 ]] && MPI_BASE="$T"
        metric_row "$N" "$p" "$T" "$MPI_BASE" >> "$Q7_CSV"
        awk -v n="$N" -v s="$SEQ" -v p="$p" -v t="$T" \
            'BEGIN { printf "%s,%.6f,%d,%.6f,%.6f,%.6f\n", n,s,p,t,s/t,t/s }' >> "$Q7_SERIAL_CSV"
        echo "Q7 N=$N P=$p median=$T"
    done

    if [[ "$N" -eq 1000000 ]]; then
        for p in 1 2 4 8; do
            profile_mpi "$N" "$p" "$BIN/q7_mpi" "$INPUT" "$Q7_COMM"
        done
    fi
    rm -f "$INPUT"
done

# =============================================================================
# SIMPLE SVG PLOTS (Python standard library only)
# =============================================================================
cat > "$WORK/make_plots.py" <<'PY_PLOT'
import csv, re, sys
from collections import defaultdict

csv_path, prefix = sys.argv[1], sys.argv[2]
rows = list(csv.DictReader(open(csv_path)))

def natural_key(s):
    return tuple(int(x) for x in re.findall(r'\d+', s)) or (0,)

def plot(metric, ylabel, out):
    groups = defaultdict(list)
    for r in rows:
        groups[r['size']].append((int(r['p']), float(r[metric])))
    for g in groups.values():
        g.sort()

    W,H,L,R,T,B = 820,500,78,30,35,68
    iw,ih = W-L-R,H-T-B
    ps = [1,2,4,8]
    ymax_data = max(v for g in groups.values() for _,v in g)
    if metric == 'speedup':
        # Zoom on measured scaling; S=1 is shown as the no-speedup reference.
        ymax = max(1.10, ymax_data * 1.12)
        ref = 1.0
        ref_label = 'No speedup (S=1)'
    else:
        ymax = max(1.05, ymax_data * 1.08)
        ref = 1.0
        ref_label = 'Ideal efficiency (E=1)'

    x = lambda p: L + ps.index(p)*iw/(len(ps)-1)
    y = lambda v: T + ih*(1-v/ymax)
    palette = ['#1f77b4','#d62728','#2ca02c','#9467bd','#ff7f0e']
    s=[f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">',
       '<rect width="100%" height="100%" fill="white"/>',
       f'<line x1="{L}" y1="{T+ih}" x2="{L+iw}" y2="{T+ih}" stroke="black"/>',
       f'<line x1="{L}" y1="{T}" x2="{L}" y2="{T+ih}" stroke="black"/>']

    for i in range(6):
        val=ymax*i/5
        yy=y(val)
        s.append(f'<line x1="{L}" y1="{yy:.1f}" x2="{L+iw}" y2="{yy:.1f}" stroke="#dddddd"/>')
        s.append(f'<text x="{L-8}" y="{yy+4:.1f}" text-anchor="end" font-size="12">{val:.2f}</text>')
    for p in ps:
        xx=x(p)
        s.append(f'<text x="{xx:.1f}" y="{T+ih+22}" text-anchor="middle" font-size="13">{p}</text>')

    yy=y(ref)
    s.append(f'<line x1="{L}" y1="{yy:.1f}" x2="{L+iw}" y2="{yy:.1f}" stroke="#777" stroke-dasharray="6,5"/>')

    ordered = sorted(groups.items(), key=lambda kv: natural_key(kv[0]))
    for idx,(name,g) in enumerate(ordered):
        c=palette[idx%len(palette)]
        pts=' '.join(f'{x(p):.1f},{y(v):.1f}' for p,v in g)
        s.append(f'<polyline points="{pts}" fill="none" stroke="{c}" stroke-width="2"/>')
        for p,v in g:
            s.append(f'<circle cx="{x(p):.1f}" cy="{y(v):.1f}" r="3" fill="{c}"/>')

    # Compact legend, including the reference line.
    lx=L+iw-190; ly=T+16
    s.append(f'<line x1="{lx}" y1="{ly}" x2="{lx+22}" y2="{ly}" stroke="#777" stroke-dasharray="6,5"/>')
    s.append(f'<text x="{lx+28}" y="{ly+4}" font-size="11">{ref_label}</text>')
    for idx,(name,_) in enumerate(ordered, start=1):
        c=palette[(idx-1)%len(palette)]
        yy=ly+18*idx
        s.append(f'<line x1="{lx}" y1="{yy}" x2="{lx+22}" y2="{yy}" stroke="{c}" stroke-width="2"/>')
        s.append(f'<text x="{lx+28}" y="{yy+4}" font-size="11">{name}</text>')

    s.append(f'<text x="{L+iw/2}" y="{H-18}" text-anchor="middle" font-size="14">MPI processes P</text>')
    s.append(f'<text x="18" y="{T+ih/2}" text-anchor="middle" font-size="14" transform="rotate(-90 18 {T+ih/2})">{ylabel}</text>')
    s.append('</svg>')
    open(out,'w').write('\n'.join(s))

plot('speedup','Speedup',prefix+'_speedup.svg')
plot('efficiency','Efficiency',prefix+'_efficiency.svg')
PY_PLOT

python3 "$WORK/make_plots.py" "$Q3_CSV" "$RESULTS/q3"
python3 "$WORK/make_plots.py" "$Q6_CSV" "$RESULTS/q6"
python3 "$WORK/make_plots.py" "$Q7_CSV" "$RESULTS/q7"

# ---- report-ready Markdown tables -------------------------------------------
cat > "$WORK/make_report_tables.py" <<'PY_REPORT'
import csv, sys
from collections import defaultdict

out, q3, q6, q7, q7s, q3c, q6c, q7c = sys.argv[1:]

def read(path): return list(csv.DictReader(open(path)))

def pivot(rows, field, digits=3):
    order=[]; d=defaultdict(dict)
    for r in rows:
        s=r['size']
        if s not in order: order.append(s)
        d[s][int(r['p'])]=float(r[field])
    lines=['| Input size | P=1 | P=2 | P=4 | P=8 |','|---|---:|---:|---:|---:|']
    for s in order:
        vals=[d[s].get(p, float('nan')) for p in (1,2,4,8)]
        lines.append('| '+s+' | '+' | '.join(f'{v:.{digits}f}' for v in vals)+' |')
    return '\n'.join(lines)

def comm_table(path):
    rows=read(path)
    lines=['| Input | P | Mean MPI-call time (s) | Mean compute time (s) | MPI-call fraction | Compute fraction |',
           '|---|---:|---:|---:|---:|---:|']
    for r in rows:
        lines.append(f"| {r['size']} | {r['p']} | {float(r['mean_mpi_time']):.4f} | {float(r['mean_compute_time']):.4f} | {100*float(r['mean_mpi_fraction']):.1f}% | {100*float(r['mean_compute_fraction']):.1f}% |")
    return '\n'.join(lines)

q3r,q6r,q7r=read(q3),read(q6),read(q7)
qs=read(q7s)
lines=['# Report-ready benchmark tables','',
       'Speedup uses **S(P)=T_MPI(1)/T_MPI(P)** and efficiency uses **E(P)=S(P)/P**. Timings are medians of repeated wall-clock runs.','']
for name, rows in [('Q3 Bitonic Sort',q3r),('Q6 Connected Components',q6r),('Q7 Server Log Analytics',q7r)]:
    lines += [f'## {name}','', '### Runtime (s)','',pivot(rows,'time',6),'',
              '### Speedup','',pivot(rows,'speedup',3),'', '### Efficiency','',pivot(rows,'efficiency',3),'']

lines += ['## Q7 sequential vs MPI','',
          '| Input size | Sequential (s) | P | MPI (s) | T_seq/T_mpi | T_mpi/T_seq |',
          '|---|---:|---:|---:|---:|---:|']
for r in qs:
    lines.append(f"| {r['size']} | {float(r['serial_time']):.6f} | {r['p']} | {float(r['mpi_time']):.6f} | {float(r['mpi_speedup_vs_serial']):.3f} | {float(r['mpi_slowdown_vs_serial']):.3f} |")

lines += ['', '## Communication vs computation (largest input only)', '',
          'These profiling runs are separate from the benchmark timings. “MPI-call time” is wall time spent inside wrapped MPI calls; it can include synchronization/waiting, so it is not pure network-transfer time.', '',
          '### Q3','',comm_table(q3c),'','### Q6','',comm_table(q6c),'','### Q7','',comm_table(q7c),'']
open(out,'w').write('\n'.join(lines)+'\n')
PY_REPORT

python3 "$WORK/make_report_tables.py" \
    "$RESULTS/report_tables.md" "$Q3_CSV" "$Q6_CSV" "$Q7_CSV" "$Q7_SERIAL_CSV" \
    "$Q3_COMM" "$Q6_COMM" "$Q7_COMM"

# ---- final summary -----------------------------------------------------------
{
    echo "DS HW2 final run"
    echo "Job: $SLURM_JOB_ID"
    echo "Node: $(hostname)"
    echo "MPI launcher: $LAUNCHER${MPI_PLUGIN:+ --mpi=$MPI_PLUGIN}"
    echo "Benchmark repetitions: $REPEATS measured + $WARMUP_RUNS warm-up per configuration"
    echo
    echo "Correctness: ALL PASS"
    echo
    echo "Q3 metrics: $Q3_CSV"
    cat "$Q3_CSV"
    echo
    echo "Q6 metrics: $Q6_CSV"
    cat "$Q6_CSV"
    echo
    echo "Q7 strong-scaling metrics (MPI P=1 baseline): $Q7_CSV"
    cat "$Q7_CSV"
    echo
    echo "Q7 sequential comparison: $Q7_SERIAL_CSV"
    cat "$Q7_SERIAL_CSV"
    echo
    echo "Communication/computation profiling:"
    echo "  $Q3_COMM"
    echo "  $Q6_COMM"
    echo "  $Q7_COMM"
    echo
    echo "Report-ready tables: $RESULTS/report_tables.md"
    echo "Plots: q3_speedup.svg q3_efficiency.svg q6_speedup.svg q6_efficiency.svg q7_speedup.svg q7_efficiency.svg"
    echo "Raw timing samples: q3_samples.csv q6_samples.csv q7_samples.csv q7_serial_samples.csv"
    echo "Reproducible generators: q6_generator.py q7_generator.py"
    echo "Benchmark config: benchmark_config.txt"
    echo "Source snapshot: source_snapshot/"
} > "$RESULTS/summary.txt"

echo
echo "========== DONE =========="
echo "All outputs are in: $RESULTS"
echo "Summary: $RESULTS/summary.txt"
echo "Report tables: $RESULTS/report_tables.md"

rm -rf "$WORK"
