#!/usr/bin/env python3
"""
parse_logs.py — Extract throughput and latency from DEX/Sherman/SMART log files.

Usage:
    python3 parse_logs.py /mydata/results/
    python3 parse_logs.py /mydata/results/ --csv output.csv
    python3 parse_logs.py /mydata/results/ --plot --plot-dir figures/

Scans all output.log files in the results directory structure and
produces a summary table.
"""

import argparse
import csv
import glob
import os
import re
import sys


def parse_experiment_tag(dirname):
    """Parse experiment metadata from directory name.

    Expected format: {system}_{workload}_{distribution}_{threads}t[_{extra}]
    Example: dex_read-only_zipfian_112t
    """
    parts = dirname.split('_')
    if len(parts) < 4:
        return None

    system = parts[0]
    # Handle multi-word systems like p-sherman
    if parts[0] in ('p',):
        system = f"{parts[0]}-{parts[1]}"
        parts = [system] + parts[2:]

    threads_str = parts[-1] if parts[-1].endswith('t') else None
    extra = ""

    if threads_str:
        threads = int(threads_str.rstrip('t'))
        # Everything between system and threads is workload + distribution
        middle = parts[1:-1]
    else:
        # Look for threads pattern in middle
        for i, p in enumerate(parts[1:], 1):
            if p.endswith('t') and p[:-1].isdigit():
                threads = int(p.rstrip('t'))
                middle = parts[1:i]
                extra = '_'.join(parts[i+1:]) if i+1 < len(parts) else ""
                break
        else:
            return None

    # Last middle element is distribution, rest is workload
    if len(middle) >= 2:
        distribution = middle[-1]
        workload = '-'.join(middle[:-1]) if len(middle) > 2 else middle[0]
        # Handle compound workload names
        if len(middle) == 2:
            workload = middle[0]
        elif len(middle) == 3:
            workload = f"{middle[0]}-{middle[1]}"
    else:
        return None

    return {
        'system': system,
        'workload': workload,
        'distribution': distribution,
        'threads': threads,
        'extra': extra,
    }


def _parse_summary_block(content):
    """Extract key=value pairs from the === RESULT SUMMARY === block."""
    result = {}
    in_block = False
    for line in content.splitlines():
        if '=== RESULT SUMMARY ===' in line:
            in_block = True
            continue
        if '=== END SUMMARY ===' in line:
            break
        if in_block:
            m = re.match(r'^\s*(\w+)\s*=\s*([^\s]+)', line)
            if m:
                result[m.group(1)] = m.group(2)
    return result


def extract_metrics(log_path):
    """Extract throughput, latency, RDMA, and cache metrics from a log file."""
    metrics = {
        'throughput_max_mops':      None,
        'throughput_straggler_mops': None,
        'latency_p50_us':           None,
        'latency_p95_us':           None,
        'latency_p99_us':           None,
        'latency_p999_us':          None,
        'cache_hit_rate':           None,
        'write_handover_rate':      None,
        'lock_fail_rate':           None,
        'rdma_read_per_op':         None,
        'rdma_write_per_op':        None,
        'rdma_cas_per_op':          None,
        'rdma_rpc_per_op':          None,
        'rdma_total_per_op':        None,
        'rdma_read_bytes_per_op':   None,
        'rdma_write_bytes_per_op':  None,
    }

    if not os.path.exists(log_path):
        return metrics

    with open(log_path, 'r') as f:
        content = f.read()

    # ---- Structured summary block (preferred) ----
    summary = _parse_summary_block(content)
    float_keys = [
        'throughput_max_mops', 'throughput_straggler_mops',
        'rdma_read_per_op', 'rdma_write_per_op', 'rdma_cas_per_op',
        'rdma_rpc_per_op', 'rdma_total_per_op',
        'rdma_read_bytes_per_op', 'rdma_write_bytes_per_op',
    ]
    for k in float_keys:
        if k in summary:
            try:
                metrics[k] = float(summary[k])
            except ValueError:
                pass

    # ---- Throughput fallback (unstructured output) ----
    if metrics['throughput_straggler_mops'] is None:
        m = re.search(r'Final throughput\s*=\s*(\d+\.?\d*)', content)
        if m:
            metrics['throughput_straggler_mops'] = float(m.group(1))

    if metrics['throughput_max_mops'] is None:
        m = re.search(r'All CN throughput \(Max\)\s*=\s*(\d+\.?\d*)', content)
        if m:
            metrics['throughput_max_mops'] = float(m.group(1))

    if metrics['throughput_straggler_mops'] is None:
        m = re.search(r'All CN throughput \(Straggler\)\s*=\s*(\d+\.?\d*)', content)
        if m:
            metrics['throughput_straggler_mops'] = float(m.group(1))

    # ---- Latency percentiles ----
    lat_patterns = [
        ('latency_p50_us',  r'Latency p50\s*=\s*(\d+\.?\d*)\s*us'),
        ('latency_p95_us',  r'Latency p95\s*=\s*(\d+\.?\d*)\s*us'),
        ('latency_p99_us',  r'Latency p99\s*=\s*(\d+\.?\d*)\s*us'),
        ('latency_p999_us', r'Latency p99\.9\s*=\s*(\d+\.?\d*)\s*us'),
    ]
    for key, pat in lat_patterns:
        m = re.search(pat, content)
        if m:
            metrics[key] = float(m.group(1))

    # ---- Cache hit rate ----
    m = re.search(r'Cache hit rate\s*=\s*(\d+\.?\d*)', content)
    if not m:
        m = re.search(r'cache hit r(?:atio|ate)[:\s=]+(\d+\.?\d*)', content, re.IGNORECASE)
    if m:
        metrics['cache_hit_rate'] = float(m.group(1))

    # ---- Handover / lock fail rates ----
    m = re.search(r'Write handover rate\s*=\s*(\d+\.?\d*)', content)
    if m:
        metrics['write_handover_rate'] = float(m.group(1))

    m = re.search(r'Lock fail rate\s*=\s*(\d+\.?\d*)', content)
    if m:
        metrics['lock_fail_rate'] = float(m.group(1))

    # ---- RDMA fallback (unstructured output) ----
    if metrics['rdma_read_per_op'] is None:
        m = re.search(r'Avg\. rdma read / op\s*=\s*(\d+\.?\d*)', content)
        if m:
            metrics['rdma_read_per_op'] = float(m.group(1))

    if metrics['rdma_write_per_op'] is None:
        m = re.search(r'Avg\. rdma write / op\s*=\s*(\d+\.?\d*)', content)
        if m:
            metrics['rdma_write_per_op'] = float(m.group(1))

    if metrics['rdma_total_per_op'] is None:
        m = re.search(r'Avg\. all rdma / op\s*=\s*(\d+\.?\d*)', content)
        if m:
            metrics['rdma_total_per_op'] = float(m.group(1))

    if metrics['rdma_read_bytes_per_op'] is None:
        m = re.search(r'Avg\. rdma read size/ op\s*=\s*(\d+\.?\d*)', content)
        if m:
            metrics['rdma_read_bytes_per_op'] = float(m.group(1))

    if metrics['rdma_write_bytes_per_op'] is None:
        m = re.search(r'Avg\. rdma write size / op\s*=\s*(\d+\.?\d*)', content)
        if m:
            metrics['rdma_write_bytes_per_op'] = float(m.group(1))

    return metrics


def scan_results(results_dir):
    """Scan all experiment directories and extract metrics.

    Supports two structures:
      results_dir/{phase_dir}/experiments/{exp_dir}/output.log  (Phase A)
      results_dir/{phase_dir}/{exp_dir}/output.log              (Phases B/C/D)
    """
    rows = []

    for phase_dir in sorted(glob.glob(os.path.join(results_dir, "*"))):
        if not os.path.isdir(phase_dir):
            continue
        phase_name = os.path.basename(phase_dir)
        phase_letter = phase_name.split('_')[0]
        experiments_dir = os.path.join(phase_dir, "experiments")
        if not os.path.isdir(experiments_dir):
            subdirs = sorted(glob.glob(os.path.join(phase_dir, "*", "experiments")))
            if subdirs:
                experiments_dir = subdirs[-1]
            else:
                # Phases B/C/D: experiments live directly in the phase directory
                experiments_dir = phase_dir
        for exp_dir in sorted(glob.glob(os.path.join(experiments_dir, "*"))):
            if not os.path.isdir(exp_dir):
                continue
            dirname = os.path.basename(exp_dir)
            meta = parse_experiment_tag(dirname)
            if meta is None:
                continue
            meta['phase'] = phase_letter
            log_path = os.path.join(exp_dir, "output.log")
            metrics = extract_metrics(log_path)
            rows.append({**meta, **metrics, 'dir': dirname, 'path': exp_dir})

    return rows


# ---------------------------------------------------------------------------
# Plotting helpers
# ---------------------------------------------------------------------------

def _parse_cluster_timeseries(log_path):
    """Return list of floats from 'cluster throughput X.XX' lines (one per second)."""
    series = []
    if not os.path.exists(log_path):
        return series
    with open(log_path) as f:
        for line in f:
            m = re.match(r'cluster throughput\s+(\d+\.?\d*)', line)
            if m:
                series.append(float(m.group(1)))
    return series

_ABLATION_ORDER = ['dex-onesided', 'dex-partitioning', 'dex-cache', 'dex-full']
_ABLATION_LABELS = {
    'dex-onesided':    'One-sided',
    'dex-partitioning': '+Partitioning',
    'dex-cache':       '+Cache',
    'dex-full':        '+Offload',
}
_ABLATION_MARKERS = {
    'dex-onesided':    'o',
    'dex-partitioning': '^',
    'dex-cache':       's',
    'dex-full':        'P',
}

_CACHE_DESIGN_ORDER = ['dex-baseline-cache', 'dex-cooling-map', 'dex-leaf-admission']
_CACHE_DESIGN_LABELS = {
    'dex-baseline-cache':   'Baseline',
    'dex-cooling-map':      '+ Scalable cooling map',
    'dex-leaf-admission':   '+ Leaf admission control',
}


def _throughput(row):
    v = row.get('throughput_straggler_mops')
    if v is None:
        v = row.get('throughput_max_mops')
    return v


def plot_phase_B(rows, out_dir):
    """Reproduce Figure 8: ablation study on write-intensive workloads."""
    import matplotlib.pyplot as plt

    data = [r for r in rows if r['phase'] == 'B' and r['workload'] == 'write-intensive']
    if not data:
        print("  [warn] No Phase B data found for Figure 8.")
        return

    fig, axes = plt.subplots(1, 2, figsize=(10, 4), sharey=False)
    dist_map = [('zipfian', 'Skewed'), ('uniform', 'Uniform')]

    for ax, (dist, dist_label) in zip(axes, dist_map):
        subset = [r for r in data if r['distribution'] == dist]
        for sys_name in _ABLATION_ORDER:
            sys_rows = sorted(
                [r for r in subset if r['system'] == sys_name and _throughput(r) is not None],
                key=lambda r: r['threads'],
            )
            if not sys_rows:
                continue
            xs = [r['threads'] for r in sys_rows]
            ys = [_throughput(r) for r in sys_rows]
            ax.plot(
                xs, ys,
                marker=_ABLATION_MARKERS[sys_name],
                label=_ABLATION_LABELS[sys_name],
                linewidth=1.5,
                markersize=5,
            )
        ax.set_xlabel('Number of threads')
        ax.set_ylabel('Million ops/second')
        ax.set_title(f'({chr(ord("a") + dist_map.index((dist, dist_label)))}) {dist_label}')
        ax.legend(fontsize=8)
        ax.grid(True, linestyle='--', alpha=0.4)

    fig.suptitle('Fig. 8 Reproduction — Ablation Study (Write-Intensive)', fontsize=11)
    fig.tight_layout()
    out_path = os.path.join(out_dir, 'fig_B_fig8_ablation.pdf')
    fig.savefig(out_path, bbox_inches='tight')
    plt.close(fig)
    print(f"  Saved: {out_path}")


def plot_phase_C_fig9(rows, out_dir):
    """Reproduce Figure 9: cache design choices bar chart."""
    import matplotlib.pyplot as plt
    import numpy as np

    data = [
        r for r in rows
        if r['phase'] == 'C'
        and r['workload'] == 'read-intensive'
        and r['distribution'] == 'zipfian'
        and r['system'] in _CACHE_DESIGN_ORDER
        and _throughput(r) is not None
    ]
    if not data:
        print("  [warn] No Phase C cache-design data found for Figure 9.")
        return

    def _cache_mb(extra):
        m = re.search(r'cache(\d+)mb', extra)
        return int(m.group(1)) if m else None

    cache_sizes = sorted({_cache_mb(r['extra']) for r in data if _cache_mb(r['extra']) is not None})
    n_systems = len(_CACHE_DESIGN_ORDER)
    width = 0.22
    x = np.arange(len(cache_sizes))

    fig, ax = plt.subplots(figsize=(7, 4))
    colors = ['#4878d0', '#ee854a', '#6acc65']

    for i, sys_name in enumerate(_CACHE_DESIGN_ORDER):
        vals = []
        for cs in cache_sizes:
            match = [r for r in data if r['system'] == sys_name and _cache_mb(r['extra']) == cs]
            vals.append(_throughput(match[0]) if match else 0.0)
        bars = ax.bar(
            x + (i - 1) * width, vals, width,
            label=_CACHE_DESIGN_LABELS[sys_name],
            color=colors[i],
        )
        for bar, val in zip(bars, vals):
            ax.text(
                bar.get_x() + bar.get_width() / 2,
                bar.get_height() + 0.3,
                f'{val:.1f}',
                ha='center', va='bottom', fontsize=7,
            )

    ax.set_xticks(x)
    ax.set_xticklabels([f'{cs} MB' for cs in cache_sizes])
    ax.set_xlabel('Cache size (MB) per compute server')
    ax.set_ylabel('Million ops/second')
    ax.set_title('Fig. 9 Reproduction — Cache Design Choices\n(Read-Intensive, 84 threads, Zipfian)')
    ax.legend(fontsize=8)
    ax.grid(True, axis='y', linestyle='--', alpha=0.4)

    fig.tight_layout()
    out_path = os.path.join(out_dir, 'fig_C_fig9_cache_design.pdf')
    fig.savefig(out_path, bbox_inches='tight')
    plt.close(fig)
    print(f"  Saved: {out_path}")


def plot_phase_C_fig11(rows, out_dir):
    """Reproduce Figure 11: throughput vs cache size percentage."""
    import matplotlib.pyplot as plt

    def _cachepct(extra):
        m = re.search(r'cachepct(\d+)', extra)
        return int(m.group(1)) if m else None

    data = [
        r for r in rows
        if r['phase'] == 'C'
        and r['system'] == 'dex'
        and _cachepct(r.get('extra', '')) is not None
        and _throughput(r) is not None
    ]
    if not data:
        print("  [warn] No Phase C cachepct data found for Figure 11.")
        return

    workloads = [('read-intensive', '(a) Read-intensive'), ('write-intensive', '(b) Write-intensive')]
    fig, axes = plt.subplots(1, 2, figsize=(10, 4))

    for ax, (wl, wl_label) in zip(axes, workloads):
        subset = sorted(
            [r for r in data if r['workload'] == wl],
            key=lambda r: _cachepct(r['extra']),
        )
        if not subset:
            ax.set_title(wl_label)
            continue
        xs = [_cachepct(r['extra']) for r in subset]
        ys = [_throughput(r) for r in subset]
        ax.plot(xs, ys, marker='o', color='#4878d0', linewidth=1.5, markersize=5, label='DEX')
        ax.set_xscale('log', base=2)
        ax.set_xticks(xs)
        ax.set_xticklabels([f'{x}%' for x in xs], fontsize=8)
        ax.set_xlabel('Cache size / Dataset size (%)')
        ax.set_ylabel('Million ops/second')
        ax.set_title(wl_label)
        ax.legend(fontsize=8)
        ax.grid(True, linestyle='--', alpha=0.4)

    fig.suptitle(
        'Fig. 11 Reproduction — Throughput vs Cache Size\n(DEX only; Sherman/SMART not rerun)',
        fontsize=10,
    )
    fig.tight_layout()
    out_path = os.path.join(out_dir, 'fig_C_fig11_cache_size.pdf')
    fig.savefig(out_path, bbox_inches='tight')
    plt.close(fig)
    print(f"  Saved: {out_path}")


def plot_phase_D(rows, out_dir):
    """Reproduce Figure 12: memory server thread impact (throughput + RDMA)."""
    import matplotlib.pyplot as plt
    import numpy as np

    def _memthreads(extra):
        m = re.search(r'memthreads(\d+)', extra)
        return int(m.group(1)) if m else None

    data = [
        r for r in rows
        if r['phase'] == 'D'
        and r['threads'] == 84
        and r['distribution'] == 'zipfian'
        and _memthreads(r.get('extra', '')) is not None
    ]
    if not data:
        print("  [warn] No Phase D data at 84 threads found for Figure 12.")
        return

    workloads = [('read-intensive', '(a) Read-intensive'), ('write-intensive', '(b) Write-intensive')]
    fig, axes = plt.subplots(1, 2, figsize=(11, 4))

    for ax, (wl, wl_label) in zip(axes, workloads):
        subset = sorted(
            [r for r in data if r['workload'] == wl],
            key=lambda r: _memthreads(r['extra']),
        )
        if not subset:
            ax.set_title(wl_label)
            continue

        xs = [_memthreads(r['extra']) for r in subset]
        throughputs = [_throughput(r) for r in subset]

        one_sided = [
            (r['rdma_read_per_op'] or 0) + (r['rdma_write_per_op'] or 0) + (r['rdma_cas_per_op'] or 0)
            for r in subset
        ]
        two_sided = [r['rdma_rpc_per_op'] or 0 for r in subset]

        ax2 = ax.twinx()
        bar_width = 0.6
        x_idx = np.arange(len(xs))

        ax2.bar(x_idx, one_sided, bar_width, label='One-sided', color='#ee854a', alpha=0.7)
        ax2.bar(x_idx, two_sided, bar_width, bottom=one_sided, label='Two-sided', color='#6acc65', alpha=0.7)
        ax2.set_ylabel('RDMA / op', color='grey')
        ax2.tick_params(axis='y', labelcolor='grey')

        valid = [(xi, t) for xi, t in zip(x_idx, throughputs) if t is not None]
        if valid:
            vx, vy = zip(*valid)
            ax.plot(list(vx), list(vy), marker='o', color='#4878d0', linewidth=2,
                    markersize=6, zorder=5, label='Throughput')

        ax.set_xticks(x_idx)
        ax.set_xticklabels(xs)
        ax.set_xlabel('Number of threads in a MS')
        ax.set_ylabel('Million ops/second', color='#4878d0')
        ax.tick_params(axis='y', labelcolor='#4878d0')
        ax.set_title(wl_label)

        lines1, labels1 = ax.get_legend_handles_labels()
        lines2, labels2 = ax2.get_legend_handles_labels()
        ax.legend(lines1 + lines2, labels1 + labels2, fontsize=8, loc='upper left')
        ax.grid(True, linestyle='--', alpha=0.3)

    fig.suptitle('Fig. 12 Reproduction — Memory Server Thread Impact (84 compute threads)', fontsize=11)
    fig.tight_layout()
    out_path = os.path.join(out_dir, 'fig_D_fig12_memthreads.pdf')
    fig.savefig(out_path, bbox_inches='tight')
    plt.close(fig)
    print(f"  Saved: {out_path}")


def plot_phase_E(rows, out_dir):
    """Reproduce Figure 10: throughput during logical repartitioning."""
    import matplotlib.pyplot as plt

    def _cache_mb(extra):
        m = re.search(r'cache(\d+)mb', extra)
        return int(m.group(1)) if m else None

    data = sorted(
        [r for r in rows
         if r['phase'] == 'E'
         and r['system'] == 'dex'
         and _cache_mb(r.get('extra', '')) is not None],
        key=lambda r: _cache_mb(r['extra']) or 0,
    )
    if not data:
        print("  [warn] No Phase E data found for Figure 10.")
        return

    colors  = ['#4878d0', '#ee854a', '#6acc65']
    markers = ['o', '^', 's']
    fig, ax = plt.subplots(figsize=(7, 4))

    for row, color, marker in zip(data, colors, markers):
        cache_mb = _cache_mb(row['extra'])
        log_path = os.path.join(row['path'], 'output.log')
        ys = _parse_cluster_timeseries(log_path)
        if not ys:
            print(f"  [warn] No time-series data in {log_path}")
            continue
        xs = list(range(1, len(ys) + 1))
        ax.plot(xs, ys, marker=marker, color=color,
                linewidth=1.8, markersize=6, label=f'{cache_mb} MB')

        # Shade the repartitioning region (contiguous zeros after first non-zero)
        in_repart = False
        repart_start = repart_end = None
        for i, y in enumerate(ys):
            if not in_repart and y == 0.0:
                in_repart = True
                repart_start = xs[i] - 0.5
            elif in_repart and y != 0.0:
                repart_end = xs[i] - 0.5
                break
        if repart_start is not None and repart_end is None:
            repart_end = xs[-1] + 0.5
        if repart_start is not None and repart_end is not None:
            ax.axvspan(repart_start, repart_end, alpha=0.08, color=color)

    ax.axvline(x=2, color='darkorange', linestyle='--', linewidth=1.2,
               label='Repartitioning start (t=2s)')
    ax.set_xlabel('Seconds')
    ax.set_ylabel('Million ops/second')
    ax.set_title('Fig. 10 Reproduction — Throughput During Repartitioning\n'
                 '(Write-Intensive, Zipfian, 84 threads)')
    ax.legend(fontsize=8)
    ax.grid(True, linestyle='--', alpha=0.4)
    fig.tight_layout()
    out_path = os.path.join(out_dir, 'fig_E_fig10_repartitioning.pdf')
    fig.savefig(out_path, bbox_inches='tight')
    plt.close(fig)
    print(f"  Saved: {out_path}")


def plot_figures(rows, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    print(f"\nGenerating figures in: {out_dir}")
    plot_phase_B(rows, out_dir)
    plot_phase_C_fig9(rows, out_dir)
    plot_phase_C_fig11(rows, out_dir)
    plot_phase_D(rows, out_dir)
    plot_phase_E(rows, out_dir)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _fmt(val, fmt='.2f'):
    return f"{val:{fmt}}" if val is not None else "N/A"


def main():
    parser = argparse.ArgumentParser(description='Parse DEX experiment logs')
    parser.add_argument('results_dir', help='Path to results directory')
    parser.add_argument('--csv', help='Write results to CSV file')
    parser.add_argument('--plot', action='store_true', help='Generate comparison figures')
    parser.add_argument('--plot-dir', default='figures', help='Output directory for figures (default: figures/)')
    args = parser.parse_args()

    rows = scan_results(args.results_dir)

    if not rows:
        print("No experiment results found.")
        print(f"Searched: {args.results_dir}/<phase>/experiments/<experiment>/output.log")
        print("\nExpected directory format: <system>_<workload>_<distribution>_<threads>t/")
        sys.exit(1)

    # Print summary table
    print(f"{'Phase':<6} {'System':<20} {'Workload':<18} {'Dist':<10} {'Thr':>4} "
          f"{'MaxMops':>8} {'StraggMops':>10} {'P50us':>7} {'P99us':>7} "
          f"{'CacheHit':>9} {'RDMArd/op':>10} {'RDMAtot/op':>10} {'Extra':<20}")
    print("-" * 140)

    for row in sorted(rows, key=lambda r: (r['phase'], r['system'], r['workload'], r['distribution'], r['threads'])):
        print(
            f"{row['phase']:<6} {row['system']:<20} {row['workload']:<18} {row['distribution']:<10} "
            f"{row['threads']:>4} "
            f"{_fmt(row['throughput_max_mops']):>8} "
            f"{_fmt(row['throughput_straggler_mops']):>10} "
            f"{_fmt(row['latency_p50_us'], '.1f'):>7} "
            f"{_fmt(row['latency_p99_us'], '.1f'):>7} "
            f"{_fmt(row['cache_hit_rate'], '.3f'):>9} "
            f"{_fmt(row['rdma_read_per_op'], '.3f'):>10} "
            f"{_fmt(row['rdma_total_per_op'], '.3f'):>10} "
            f"{row.get('extra', ''):<20}"
        )

    print(f"\nTotal experiments: {len(rows)}")
    parsed = sum(1 for r in rows if r['throughput_straggler_mops'] is not None
                                 or r['throughput_max_mops'] is not None)
    print(f"With throughput data: {parsed}")

    # CSV output
    if args.csv:
        fieldnames = [
            'phase', 'system', 'workload', 'distribution', 'threads', 'extra',
            'throughput_max_mops', 'throughput_straggler_mops',
            'latency_p50_us', 'latency_p95_us', 'latency_p99_us', 'latency_p999_us',
            'cache_hit_rate', 'write_handover_rate', 'lock_fail_rate',
            'rdma_read_per_op', 'rdma_write_per_op', 'rdma_cas_per_op',
            'rdma_rpc_per_op', 'rdma_total_per_op',
            'rdma_read_bytes_per_op', 'rdma_write_bytes_per_op',
            'dir',
        ]
        with open(args.csv, 'w', newline='') as f:
            writer = csv.DictWriter(f, fieldnames=fieldnames)
            writer.writeheader()
            writer.writerows(rows)
        print(f"\nCSV written to: {args.csv}")

    if args.plot:
        plot_figures(rows, args.plot_dir)


if __name__ == '__main__':
    main()
