#include <iostream>
#include <vector>

using graph_t = std::vector<std::vector<int>>;
using list_t = std::vector<int>;

void compute_components_serial(const graph_t& G, list_t& output) {
    for (int v = 0; v < (int)G.size(); ++v) {
        if (output[v] != -1) continue;

        std::vector<int> stack = {v};
        output[v] = v;

        while (!stack.empty()) {
            int u = stack.back();
            stack.pop_back();

            for (int w : G[u]) {
                if (output[w] == -1) {
                    output[w] = v;
                    stack.push_back(w);
                }
            }
        }
    }
}

int main() {
    int V;
    std::cin >> V;

    graph_t G(V);
    for (int i = 0; i < V; ++i) {
        int k;
        std::cin >> k;
        G[i].resize(k);
        for (int& v : G[i]) std::cin >> v;
    }

    list_t output(V, -1);
    compute_components_serial(G, output);

    for (int v = 0; v < V; ++v)
        std::cout << v << ' ' << output[v] << '\n';
}
