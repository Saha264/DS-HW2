import random, sys
N = int(sys.argv[1])
seed = int(sys.argv[2]) if len(sys.argv) > 2 else 12345
K, S, endpoints = 5, 64, 256
random.seed(seed)
print(N, K, S)
statuses = [200, 201, 204, 301, 302, 400, 404, 500, 503]
for i in range(N):
    timestamp = i + random.randrange(30)
    server = random.randrange(S)
    endpoint = random.randrange(endpoints)
    user = random.randrange(1_000_000)
    status = random.choice(statuses)
    response = random.uniform(1.0, 1000.0)
    bytes_sent = random.randrange(100, 100000)
    print(timestamp, server, endpoint, user, status, f"{response:.2f}", bytes_sent)
