import random, sys
V = int(sys.argv[1])
E = int(sys.argv[2])
seed = int(sys.argv[3]) if len(sys.argv) > 3 else 12345
random.seed(seed)
E = min(E, V * (V - 1) // 2)
edges = set()
for v in range(1, V):
    edges.add(((v - 1) // 2, v))
while len(edges) < E:
    u = random.randrange(V)
    v = random.randrange(V)
    if u == v:
        continue
    if u > v:
        u, v = v, u
    edges.add((u, v))
adj = [[] for _ in range(V)]
for u, v in edges:
    adj[u].append(v)
    adj[v].append(u)
print(V)
for a in adj:
    print(len(a), *a)
