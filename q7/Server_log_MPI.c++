#include "mpi.h"
#include <iostream>
#include <iomanip>
#include <vector>
#include <string>
#include <unordered_map>
#include <limits>
#include <algorithm>
#include <cstdlib>
using namespace std;

static inline void skip_ws(const char*& q, const char* e) {
    while (q < e && (unsigned char)*q <= ' ') ++q;
}
static inline long long parse_int(const char*& q, const char* e) {
    skip_ws(q, e);
    bool neg = false;
    if (q < e && (*q == '-' || *q == '+')) { neg = (*q == '-'); ++q; }
    long long v = 0;
    while (q < e && *q >= '0' && *q <= '9') { v = v * 10 + (*q - '0'); ++q; }
    return neg ? -v : v;
}
static inline double parse_dbl(const char*& q, const char* e) {
    skip_ws(q, e);
    char* end;
    double v = strtod(q, &end);
    q = end;
    return v;
}

int main(int argc, char* argv[])
{
    ios::sync_with_stdio(false);
    cin.tie(nullptr);

    MPI_Init(&argc, &argv);

    int rank,p;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD,&p);

    const char* path = (argc > 1) ? argv[1] : nullptr;

    int N,K,S;

    long long total=0, succ=0,fail=0;
    long long bytes_total=0;
    long long s2=0,s3=0,s4=0,s5=0;
    double rt_sum=0.0;
    double rt_min= std::numeric_limits<double>::infinity();
    double rt_max = -std::numeric_limits<double>::infinity();
    vector<long long> srv_cnt;
    vector<double> srv_rtsum;
    unordered_map<long long, long long> ep_cnt;
    unordered_map<long long, long long> ep_bytes;
    unordered_map<long long, long long> ivl_cnt;

    auto accumulate = [&](long long timestamp, long long server_id, long long endpoint_id,
                          long long status_code, double response_time, long long bytes_sent)
    {
        total += 1;
        if (status_code < 400) { succ += 1; } else { fail += 1; }
        rt_sum += response_time;
        rt_min  = min(rt_min, response_time);
        rt_max  = max(rt_max, response_time);
        bytes_total += bytes_sent;
        switch (status_code / 100) {
            case 2: s2 += 1; break;
            case 3: s3 += 1; break;
            case 4: s4 += 1; break;
            case 5: s5 += 1; break;
        }
        if (server_id >= 0 && server_id < S) {
            srv_cnt[server_id]   += 1;
            srv_rtsum[server_id] += response_time;
        }
        ep_cnt[endpoint_id]     += 1;
        ep_bytes[endpoint_id]   += bytes_sent;
        ivl_cnt[timestamp / 60] += 1;
    };

    if (path)
    {
        MPI_File fh;
        if (MPI_File_open(MPI_COMM_WORLD, path, MPI_MODE_RDONLY, MPI_INFO_NULL, &fh) != MPI_SUCCESS) {
            if (rank == 0) cerr << "cannot open " << path << "\n";
            MPI_Abort(MPI_COMM_WORLD, 1);
        }
        MPI_Offset fsize;
        MPI_File_get_size(fh, &fsize);

        char hdr[256];
        MPI_Offset hdr_n = std::min<MPI_Offset>(sizeof(hdr) - 1, fsize);
        MPI_File_read_at_all(fh, 0, hdr, (int)hdr_n, MPI_CHAR, MPI_STATUS_IGNORE);
        hdr[hdr_n] = '\0';

        MPI_Offset data_start = 0;
        while (data_start < hdr_n && hdr[data_start] != '\n') ++data_start;
        ++data_start;

        {
            const char* q = hdr; const char* e = hdr + hdr_n;
            N = (int)parse_int(q, e);
            K = (int)parse_int(q, e);
            S = (int)parse_int(q, e);
        }
        srv_cnt.assign(S, 0);
        srv_rtsum.assign(S, 0.0);

        MPI_Offset len = (fsize > data_start) ? fsize - data_start : 0;
        MPI_Offset lo  = data_start + (MPI_Offset)((len * (long long)rank)     / p);
        MPI_Offset hi  = data_start + (MPI_Offset)((len * (long long)(rank+1)) / p);

        const MPI_Offset SLACK = 512;
        MPI_Offset rlo = (rank == 0) ? lo : lo - 1;
        MPI_Offset rhi = std::min<MPI_Offset>(fsize, hi + SLACK);
        MPI_Offset rn  = (rhi > rlo) ? rhi - rlo : 0;

        vector<char> buf((size_t)rn + 1);
        {
            const MPI_Offset STEP = 1 << 28;
            MPI_Offset maxrn = 0;
            MPI_Allreduce(&rn, &maxrn, 1, MPI_OFFSET, MPI_MAX, MPI_COMM_WORLD);
            for (MPI_Offset off = 0; off < maxrn; off += STEP) {
                MPI_Offset c = std::min<MPI_Offset>(STEP, (rn > off) ? rn - off : 0);
                MPI_File_read_at_all(fh, rlo + off, buf.data() + off, (int)c, MPI_CHAR, MPI_STATUS_IGNORE);
            }
        }
        buf[(size_t)rn] = '\0';
        MPI_File_close(&fh);

        const char* base = buf.data();
        const char* e    = buf.data() + rn;
        const char* q    = base;
        if (rank != 0) {
            while (q < e && *q != '\n') ++q;
            if (q < e) ++q;
        }

        while (true) {
            skip_ws(q, e);
            if (q >= e) break;
            if (rlo + (MPI_Offset)(q - base) >= hi) break;
            long long timestamp   = parse_int(q, e);
            long long server_id   = parse_int(q, e);
            long long endpoint_id = parse_int(q, e);
            parse_int(q, e);
            long long status_code = parse_int(q, e);
            double    response_time = parse_dbl(q, e);
            long long bytes_sent  = parse_int(q, e);
            accumulate(timestamp, server_id, endpoint_id, status_code, response_time, bytes_sent);
        }
    }
    else
    {
        if(rank==0)
        {
            cin >> N >> K >> S;
        }
        MPI_Bcast(&N,1,MPI_INT,0,MPI_COMM_WORLD);
        MPI_Bcast(&K,1,MPI_INT,0,MPI_COMM_WORLD);
        MPI_Bcast(&S,1,MPI_INT,0,MPI_COMM_WORLD);
        srv_cnt.assign(S, 0);
        srv_rtsum.assign(S, 0.0);

        const long long CHUNK = 1'000'000;
        long long done = 0;

        vector<long long> rank_row_counts(p), rank_row_offsets(p);
        vector<long long> chunk_ints;
        vector<double>    chunk_response_times;

        while(done<N)
        {
            long long int m= min(CHUNK, (long long)N-done);

            for(int k=0;k<p;k++)
            {
                rank_row_counts[k]=m/p + (k<m%p ? 1:0);
            }
            rank_row_offsets[0]=0;
            for(int k=1;k<p;k++)
            {
                rank_row_offsets[k]=rank_row_offsets[k-1]+ rank_row_counts[k-1];
            }
            long long rows_this_rank=rank_row_counts[rank];

            if(rank==0){
                chunk_ints.assign(m*6,0);
                chunk_response_times.assign(m,0.0);

                for(long long row=0; row<m; row++)
                {
                    long long timestamp,server_id,endpoint_id,user_id,status_code,bytes_sent;
                    double response_time;
                    cin >> timestamp >> server_id >> endpoint_id >> user_id >> status_code >> response_time >> bytes_sent;

                    chunk_ints[row*6+0] = timestamp;
                    chunk_ints[row*6+1] = server_id;
                    chunk_ints[row*6+2] = endpoint_id;
                    chunk_ints[row*6+3] = user_id;
                    chunk_ints[row*6+4] = status_code;
                    chunk_ints[row*6+5] = bytes_sent;
                    chunk_response_times[row] = response_time;
                }
            }

            vector<int> ints_send_counts(p),ints_send_offsets(p),rts_send_counts(p),rts_send_offsets(p);
            for(int k=0;k<p;k++)
            {
                ints_send_counts[k]= (int)(rank_row_counts[k]*6);
                ints_send_offsets[k]= (int)(rank_row_offsets[k]*6);
                rts_send_counts[k]= (int)(rank_row_counts[k]);
                rts_send_offsets[k]= (int)(rank_row_offsets[k]);
            }

            vector<long long> my_ints(rows_this_rank * 6);
            vector<double>    my_response_times(rows_this_rank);

            MPI_Scatterv(rank == 0 ? chunk_ints.data() : nullptr, ints_send_counts.data(), ints_send_offsets.data(), MPI_LONG_LONG, my_ints.data(), (int)(rows_this_rank * 6), MPI_LONG_LONG, 0, MPI_COMM_WORLD);
            MPI_Scatterv(rank == 0 ? chunk_response_times.data() : nullptr, rts_send_counts.data(), rts_send_offsets.data(), MPI_DOUBLE,
                     my_response_times.data(), (int)rows_this_rank, MPI_DOUBLE, 0, MPI_COMM_WORLD);

            for (long long row = 0; row < rows_this_rank; ++row) {
                accumulate(my_ints[row*6 + 0], my_ints[row*6 + 1], my_ints[row*6 + 2],
                           my_ints[row*6 + 4], my_response_times[row], my_ints[row*6 + 5]);
            }
            done += m;
        }
    }

    //general stats
    long long loc[8] = { total, succ, fail, bytes_total, s2, s3, s4, s5 };
    long long final_totals[8] = {0};
    MPI_Reduce(loc, final_totals, 8, MPI_LONG_LONG, MPI_SUM, 0, MPI_COMM_WORLD);

    //response times
    double final_rtsum = 0.0, final_rtmin = 0.0, final_rtmax = 0.0;
    MPI_Reduce(&rt_sum, &final_rtsum, 1, MPI_DOUBLE, MPI_SUM, 0, MPI_COMM_WORLD);
    MPI_Reduce(&rt_min, &final_rtmin, 1, MPI_DOUBLE, MPI_MIN, 0, MPI_COMM_WORLD);
    MPI_Reduce(&rt_max, &final_rtmax, 1, MPI_DOUBLE, MPI_MAX, 0, MPI_COMM_WORLD);

    //server stats
    vector<long long> final_srv_cnt(S, 0);
    vector<double>    final_srv_rtsum(S, 0.0);
    MPI_Reduce(srv_cnt.data(),   final_srv_cnt.data(),   (int)S, MPI_LONG_LONG, MPI_SUM, 0, MPI_COMM_WORLD);
    MPI_Reduce(srv_rtsum.data(), final_srv_rtsum.data(), (int)S, MPI_DOUBLE,    MPI_SUM, 0, MPI_COMM_WORLD);

    //endpoints
    vector<long long> local_ep_flat;
    local_ep_flat.reserve(ep_cnt.size() * 3);
    for (auto& kv : ep_cnt) {
        long long id = kv.first;
        local_ep_flat.push_back(id);
        local_ep_flat.push_back(kv.second);         
        local_ep_flat.push_back(ep_bytes[id]);       
    }
    int local_ep_n = (int)local_ep_flat.size();     
    vector<int> ep_recv_counts(p);
    MPI_Gather(&local_ep_n, 1, MPI_INT, ep_recv_counts.data(), 1, MPI_INT, 0, MPI_COMM_WORLD);

    vector<int> ep_recv_offsets(p, 0);
    int ep_total_n = 0;
    if (rank == 0) {
        for (int k = 0; k < p; ++k) {
            ep_recv_offsets[k] = ep_total_n;
            ep_total_n += ep_recv_counts[k];
        }
    }
    vector<long long> all_ep_flat(rank == 0 ? ep_total_n : 0);
    MPI_Gatherv(local_ep_flat.data(), local_ep_n, MPI_LONG_LONG,
                all_ep_flat.data(), ep_recv_counts.data(), ep_recv_offsets.data(), MPI_LONG_LONG,
                0, MPI_COMM_WORLD);

    unordered_map<long long, long long> final_ep_cnt;
    unordered_map<long long, long long> final_ep_bytes;
    if (rank == 0) {
        for (int i = 0; i < ep_total_n; i += 3) {
            long long id = all_ep_flat[i];
            final_ep_cnt[id]   += all_ep_flat[i + 1];
            final_ep_bytes[id] += all_ep_flat[i + 2];
        }
    }

    //intervals
    vector<long long> local_ivl_flat;
    local_ivl_flat.reserve(ivl_cnt.size() * 2);
    for (auto& kv : ivl_cnt) {
        local_ivl_flat.push_back(kv.first);
        local_ivl_flat.push_back(kv.second);
    }
    int local_ivl_n = (int)local_ivl_flat.size();

    vector<int> ivl_recv_counts(p);
    MPI_Gather(&local_ivl_n, 1, MPI_INT, ivl_recv_counts.data(), 1, MPI_INT, 0, MPI_COMM_WORLD);

    vector<int> ivl_recv_offsets(p, 0);
    int ivl_total_n = 0;
    if (rank == 0) {
        for (int k = 0; k < p; ++k) {
            ivl_recv_offsets[k] = ivl_total_n;
            ivl_total_n += ivl_recv_counts[k];
        }
    }
    vector<long long> all_ivl_flat(rank == 0 ? ivl_total_n : 0);
    MPI_Gatherv(local_ivl_flat.data(), local_ivl_n, MPI_LONG_LONG,
                all_ivl_flat.data(), ivl_recv_counts.data(), ivl_recv_offsets.data(), MPI_LONG_LONG,
                0, MPI_COMM_WORLD);

    unordered_map<long long, long long> final_ivl_cnt;
    if (rank == 0) {
        for (int i = 0; i < ivl_total_n; i += 2) {
            final_ivl_cnt[all_ivl_flat[i]] += all_ivl_flat[i + 1];
        }
    }

    if (rank == 0) {
        long long T = final_totals[0];  
        double avg = (T > 0) ? (final_rtsum / (double)T) : 0.0;
        if (T == 0) { final_rtmin = 0.0; final_rtmax = 0.0; }  

        //busiest interval
        long long best_id = 0, best_cnt = 0;
        for (auto& kv : final_ivl_cnt) {
            long long id = kv.first, c = kv.second;
            if (c > best_cnt || (c == best_cnt && id < best_id)) {
                best_cnt = c;
                best_id = id;
            }
        }

        
        struct SrvRow { long long count, id; double avg_rt; };
        std::vector<SrvRow> srv_rows;
        for (long long i = 0; i < S; ++i) {
            if (final_srv_cnt[i] > 0) {
                srv_rows.push_back({ final_srv_cnt[i], i, final_srv_rtsum[i] / (double)final_srv_cnt[i] });
            }
        }

        
        struct EpRow { long long count, id, bytes; };
        std::vector<EpRow> ep_rows;
        for (auto& kv : final_ep_cnt) {
            long long id = kv.first;
            ep_rows.push_back({ kv.second, id, final_ep_bytes[id] });
        }

       
        auto cmp_srv = [](const SrvRow& a, const SrvRow& b) {
            if (a.count != b.count) return a.count > b.count;
            return a.id < b.id;
        };
        auto cmp_ep = [](const EpRow& a, const EpRow& b) {
            if (a.count != b.count) return a.count > b.count;
            return a.id < b.id;
        };
        std::sort(srv_rows.begin(), srv_rows.end(), cmp_srv);
        std::sort(ep_rows.begin(),  ep_rows.end(),  cmp_ep);

  
        std::cout << "TOTAL_REQUESTS " << final_totals[0] << "\n";
        std::cout << "SUCCESSFUL_REQUESTS " << final_totals[1] << "\n";
        std::cout << "FAILED_REQUESTS " << final_totals[2] << "\n";

        std::cout << std::fixed << std::setprecision(2);
        std::cout << "AVERAGE_RESPONSE_TIME " << avg << "\n";
        std::cout << "MIN_RESPONSE_TIME " << final_rtmin << "\n";
        std::cout << "MAX_RESPONSE_TIME " << final_rtmax << "\n";
        std::cout.unsetf(std::ios::fixed);

        std::cout << "TOTAL_BYTES " << final_totals[3] << "\n";
        std::cout << "STATUS_2XX " << final_totals[4] << "\n";
        std::cout << "STATUS_3XX " << final_totals[5] << "\n";
        std::cout << "STATUS_4XX " << final_totals[6] << "\n";
        std::cout << "STATUS_5XX " << final_totals[7] << "\n";
        std::cout << "BUSIEST_INTERVAL " << best_id << " " << best_cnt << "\n";

        std::cout << "TOP_SERVERS\n";
        for (long long i = 0; i < std::min((long long)K, (long long)srv_rows.size()); ++i) {
            std::cout << srv_rows[i].id << " " << srv_rows[i].count << " "
                    << std::fixed << std::setprecision(2) << srv_rows[i].avg_rt << "\n";
            std::cout.unsetf(std::ios::fixed);
        }

        std::cout << "TOP_ENDPOINTS\n";
        for (long long i = 0; i < std::min((long long)K, (long long)ep_rows.size()); ++i) {
            std::cout << ep_rows[i].id << " " << ep_rows[i].count << " " << ep_rows[i].bytes << "\n";
        }
    }

    MPI_Finalize();
}
