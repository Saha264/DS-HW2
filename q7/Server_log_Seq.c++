#include <iostream>
#include <iomanip>
#include <vector>
#include <unordered_map>
#include <limits>
#include <algorithm>
using namespace std;

int main()
{
    ios::sync_with_stdio(false);
    cin.tie(nullptr);

    long long N, K, S;
    cin >> N >> K >> S;

    long long total = 0, succ = 0, fail = 0;
    long long bytes_total = 0;
    long long s2 = 0, s3 = 0, s4 = 0, s5 = 0;
    double rt_sum = 0.0;
    double rt_min = numeric_limits<double>::infinity();
    double rt_max = -numeric_limits<double>::infinity();

    vector<long long> srv_cnt(S, 0);
    vector<double>    srv_rtsum(S, 0.0);
    unordered_map<long long, long long> ep_cnt;
    unordered_map<long long, long long> ep_bytes;
    unordered_map<long long, long long> ivl_cnt;

    for (long long row = 0; row < N; ++row)
    {
        long long timestamp, server_id, endpoint_id, user_id, status_code, bytes_sent;
        double response_time;
        cin >> timestamp >> server_id >> endpoint_id >> user_id
            >> status_code >> response_time >> bytes_sent;

        total += 1;
        if (status_code < 400)
        {
            succ += 1;
        }
        else
        {
            fail += 1;
        }

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
    }

    double avg = (total > 0) ? (rt_sum / (double)total) : 0.0;
    if (total == 0) { rt_min = 0.0; rt_max = 0.0; }

   
    long long best_id = 0, best_cnt = 0;
    for (auto& kv : ivl_cnt) {
        long long id = kv.first, c = kv.second;
        if (c > best_cnt || (c == best_cnt && id < best_id)) {
            best_cnt = c;
            best_id = id;
        }
    }

    struct SrvRow { long long count, id; double avg_rt; };
    vector<SrvRow> srv_rows;
    for (long long i = 0; i < S; ++i) {
        if (srv_cnt[i] > 0) {
            srv_rows.push_back({ srv_cnt[i], i, srv_rtsum[i] / (double)srv_cnt[i] });
        }
    }

    struct EpRow { long long count, id, bytes; };
    vector<EpRow> ep_rows;
    for (auto& kv : ep_cnt) {
        long long id = kv.first;
        ep_rows.push_back({ kv.second, id, ep_bytes[id] });
    }

    auto cmp_srv = [](const SrvRow& a, const SrvRow& b) {
        if (a.count != b.count) return a.count > b.count;
        return a.id < b.id;
    };
    auto cmp_ep = [](const EpRow& a, const EpRow& b) {
        if (a.count != b.count) return a.count > b.count;
        return a.id < b.id;
    };
    sort(srv_rows.begin(), srv_rows.end(), cmp_srv);
    sort(ep_rows.begin(),  ep_rows.end(),  cmp_ep);

    cout << "TOTAL_REQUESTS " << total << "\n";
    cout << "SUCCESSFUL_REQUESTS " << succ << "\n";
    cout << "FAILED_REQUESTS " << fail << "\n";

    cout << fixed << setprecision(2);
    cout << "AVERAGE_RESPONSE_TIME " << avg << "\n";
    cout << "MIN_RESPONSE_TIME " << rt_min << "\n";
    cout << "MAX_RESPONSE_TIME " << rt_max << "\n";
    cout.unsetf(ios::fixed);

    cout << "TOTAL_BYTES " << bytes_total << "\n";
    cout << "STATUS_2XX " << s2 << "\n";
    cout << "STATUS_3XX " << s3 << "\n";
    cout << "STATUS_4XX " << s4 << "\n";
    cout << "STATUS_5XX " << s5 << "\n";
    cout << "BUSIEST_INTERVAL " << best_id << " " << best_cnt << "\n";

    cout << "TOP_SERVERS\n";
    for (long long i = 0; i < min(K, (long long)srv_rows.size()); ++i) {
        cout << srv_rows[i].id << " " << srv_rows[i].count << " "
             << fixed << setprecision(2) << srv_rows[i].avg_rt << "\n";
        cout.unsetf(ios::fixed);
    }

    cout << "TOP_ENDPOINTS\n";
    for (long long i = 0; i < min(K, (long long)ep_rows.size()); ++i) {
        cout << ep_rows[i].id << " " << ep_rows[i].count << " " << ep_rows[i].bytes << "\n";
    }

    return 0;
}
