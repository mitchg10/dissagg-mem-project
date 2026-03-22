#!/usr/bin/env python3
"""
parse_logs.py — Extract throughput and latency from DEX/Sherman/SMART log files.

Usage:
    python3 parse_logs.py /mydata/results/
    python3 parse_logs.py /mydata/results/ --csv output.csv

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
    """Scan all experiment directories and extract metrics."""
    rows = []

    for ts_dir in sorted(glob.glob(os.path.join(results_dir, "2*"))):
        for exp_dir in sorted(glob.glob(os.path.join(ts_dir, "*"))):
            dirname = os.path.basename(exp_dir)
            meta = parse_experiment_tag(dirname)
            if meta is None:
                continue

            log_path = os.path.join(exp_dir, "output.log")
            metrics = extract_metrics(log_path)

            rows.append({**meta, **metrics, 'dir': dirname})

    return rows


def _fmt(val, fmt='.2f'):
    return f"{val:{fmt}}" if val is not None else "N/A"


def main():
    parser = argparse.ArgumentParser(description='Parse DEX experiment logs')
    parser.add_argument('results_dir', help='Path to results directory')
    parser.add_argument('--csv', help='Write results to CSV file')
    args = parser.parse_args()

    rows = scan_results(args.results_dir)

    if not rows:
        print("No experiment results found.")
        print(f"Searched: {args.results_dir}/2*/<experiment>/output.log")
        print("\nExpected directory format: <system>_<workload>_<distribution>_<threads>t/")
        sys.exit(1)

    # Print summary table
    print(f"{'System':<15} {'Workload':<18} {'Dist':<10} {'Thr':>4} "
          f"{'MaxMops':>8} {'StraggMops':>10} {'P50us':>7} {'P99us':>7} "
          f"{'CacheHit':>9} {'RDMArd/op':>10} {'RDMAtot/op':>10} {'Extra':<12}")
    print("-" * 120)

    for row in sorted(rows, key=lambda r: (r['system'], r['workload'], r['distribution'], r['threads'])):
        print(
            f"{row['system']:<15} {row['workload']:<18} {row['distribution']:<10} "
            f"{row['threads']:>4} "
            f"{_fmt(row['throughput_max_mops']):>8} "
            f"{_fmt(row['throughput_straggler_mops']):>10} "
            f"{_fmt(row['latency_p50_us'], '.1f'):>7} "
            f"{_fmt(row['latency_p99_us'], '.1f'):>7} "
            f"{_fmt(row['cache_hit_rate'], '.3f'):>9} "
            f"{_fmt(row['rdma_read_per_op'], '.3f'):>10} "
            f"{_fmt(row['rdma_total_per_op'], '.3f'):>10} "
            f"{row.get('extra', ''):<12}"
        )

    print(f"\nTotal experiments: {len(rows)}")
    parsed = sum(1 for r in rows if r['throughput_straggler_mops'] is not None
                                 or r['throughput_max_mops'] is not None)
    print(f"With throughput data: {parsed}")

    # CSV output
    if args.csv:
        fieldnames = [
            'system', 'workload', 'distribution', 'threads', 'extra',
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


if __name__ == '__main__':
    main()
