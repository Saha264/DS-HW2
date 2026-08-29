#include <mpi.h>
#include <algorithm>
#include <iostream>
#include <numeric>
#include <vector>

using graph_t = std::vector<std::vector<int>>;

int main(int argc, char** argv) {
    MPI_Init(&argc, &argv);

    int rank, P;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &P);

    int V = 0;
    graph_t G;

    if (rank == 0) {
        std::cin >> V;
        G.resize(V);
        for (int v = 0; v < V; ++v) {
            int k;
            std::cin >> k;
            G[v].resize(k);
            for (int& u : G[v]) std::cin >> u;
        }
    }

    MPI_Bcast(&V, 1, MPI_INT, 0, MPI_COMM_WORLD);

    std::vector<int> counts(P), displs(P);
    for (int p = 0; p < P; ++p) {
        counts[p] = V / P + (p < V % P);
        displs[p] = p * (V / P) + std::min(p, V % P);
    }

    int local_n = counts[rank];
    int start = displs[rank];

    std::vector<int> packed, sendcounts(P), senddispls(P);
    if (rank == 0) {
        for (int p = 0; p < P; ++p) {
            for (int i = 0; i < counts[p]; ++i) {
                int v = displs[p] + i;
                sendcounts[p] += 1 + (int)G[v].size();
            }
        }
        for (int p = 1; p < P; ++p)
            senddispls[p] = senddispls[p - 1] + sendcounts[p - 1];

        packed.resize(std::accumulate(sendcounts.begin(), sendcounts.end(), 0));
        for (int p = 0; p < P; ++p) {
            int pos = senddispls[p];
            for (int i = 0; i < counts[p]; ++i) {
                int v = displs[p] + i;
                packed[pos++] = (int)G[v].size();
                for (int u : G[v]) packed[pos++] = u;
            }
        }
    }

    int recvcount = 0;
    MPI_Scatter(sendcounts.data(), 1, MPI_INT,
                &recvcount, 1, MPI_INT, 0, MPI_COMM_WORLD);

    std::vector<int> recvbuf(recvcount);
    MPI_Scatterv(packed.data(), sendcounts.data(), senddispls.data(), MPI_INT,
                 recvbuf.data(), recvcount, MPI_INT, 0, MPI_COMM_WORLD);

    graph_t local_G(local_n);
    int pos = 0;
    for (int i = 0; i < local_n; ++i) {
        int k = recvbuf[pos++];
        local_G[i].resize(k);
        for (int& u : local_G[i]) u = recvbuf[pos++];
    }

    std::vector<int> labels(V);
    std::iota(labels.begin(), labels.end(), 0);
    std::vector<int> next(local_n);

    while (true) {
        int changed = 0;

        for (int i = 0; i < local_n; ++i) {
            int v = start + i;
            int best = labels[v];
            for (int u : local_G[i])
                best = std::min(best, labels[u]);
            next[i] = best;
            if (best != labels[v]) changed = 1;
        }

        MPI_Allgatherv(next.data(), local_n, MPI_INT,
                       labels.data(), counts.data(), displs.data(), MPI_INT,
                       MPI_COMM_WORLD);

        int any_changed = 0;
        MPI_Allreduce(&changed, &any_changed, 1, MPI_INT, MPI_MAX, MPI_COMM_WORLD);
        if (!any_changed) break;
    }

    if (rank == 0) {
        for (int v = 0; v < V; ++v)
            std::cout << v << ' ' << labels[v] << '\n';
    }

    MPI_Finalize();
}
