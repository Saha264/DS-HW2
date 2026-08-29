import random, sys
n = int(sys.argv[1])
seed = int(sys.argv[2]) if len(sys.argv) > 2 else 12345
random.seed(seed)
print(n)
print(*[random.randint(-10**9, 10**9) for _ in range(n)])
