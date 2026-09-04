import csv, sys
import matplotlib.pyplot as plt

path = sys.argv[1]
base = path.rsplit('.', 1)[0]
rows = list(csv.DictReader(open(path)))
sizes = sorted({int(r['size']) for r in rows})

for metric in ['speedup', 'efficiency']:
    plt.figure()
    for size in sizes:
        r = [x for x in rows if int(x['size']) == size]
        r.sort(key=lambda x: int(x['p']))
        plt.plot([int(x['p']) for x in r], [float(x[metric]) for x in r], marker='o', label=str(size))
    plt.xlabel('Processes')
    plt.ylabel(metric.capitalize())
    plt.xticks([1, 2, 4, 8])
    plt.legend(title='Input size')
    plt.tight_layout()
    plt.savefig(f'{base}_{metric}.png', dpi=160)
