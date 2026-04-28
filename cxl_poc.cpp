/**
 * cxl_poc.cpp — Minimal CXL emulation proof-of-concept for DEX
 *
 * Demonstrates that DEX's core operations (1KB node read, CAS lock,
 * write-back) can be performed via load/store on NUMA-pinned memory
 * instead of RDMA verbs. Measures latency with configurable delay
 * injection to sweep CXL-realistic latency points.
 *
 * Run on a CloudLab d6515 with NPS2 enabled (2 NUMA nodes).
 * No DEX source modifications required.
 *
 * Build:
 *   g++ -O2 -std=c++17 -o cxl_poc cxl_poc.cpp -lnuma -lpthread
 *
 * Usage:
 *   numactl --cpunodebind=0 ./cxl_poc              # defaults
 *   numactl --cpunodebind=0 ./cxl_poc --delay 70   # inject 70ns
 *   numactl --cpunodebind=0 ./cxl_poc --threads 16  # scale up
 */

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <vector>
#include <numa.h>
#include <x86intrin.h> // __rdtsc, _mm_pause

// ─── Configuration ──────────────────────────────────────────────

static constexpr size_t NODE_SIZE = 1024;        // 1KB B+-tree node
static constexpr size_t POOL_SIZE = 64ULL << 20; // 64MB memory pool
static constexpr size_t NUM_NODES = POOL_SIZE / NODE_SIZE;
static constexpr int TREE_HEIGHT = 4;         // levels to traverse
static constexpr int OPS_PER_THREAD = 200000; // operations per thread
static constexpr int WARMUP_OPS = 10000;

// ─── Simulated B+-tree node layout ──────────────────────────────
// Mirrors DEX's 1KB node: version lock + fence keys + child pointers

struct alignas(64) BTreeNode
{
    std::atomic<uint64_t> version_lock; // optimistic lock
    uint64_t fence_lo;
    uint64_t fence_hi;
    uint64_t num_keys;
    uint64_t keys[60];     // ~480 bytes of keys
    uint64_t children[61]; // child offsets (index into pool)
    char padding[NODE_SIZE - 8 - 8 - 8 - 8 - 60 * 8 - 61 * 8];
};
static_assert(sizeof(BTreeNode) == NODE_SIZE, "Node must be exactly 1KB");

// ─── Globals ────────────────────────────────────────────────────

static void *g_pool = nullptr; // memory pool on remote NUMA
static int g_local_node = 0;
static int g_remote_node = 1;
static uint64_t g_inject_ns = 0;
static uint64_t g_tsc_freq = 0; // ticks per nanosecond

// ─── TSC calibration ────────────────────────────────────────────

void calibrate_tsc()
{
    auto t0 = std::chrono::high_resolution_clock::now();
    uint64_t c0 = __rdtsc();
    usleep(50000); // 50ms
    uint64_t c1 = __rdtsc();
    auto t1 = std::chrono::high_resolution_clock::now();
    double elapsed_ns = std::chrono::duration<double, std::nano>(t1 - t0).count();
    g_tsc_freq = (uint64_t)((c1 - c0) / elapsed_ns);
    printf("  TSC freq: ~%.2f GHz\n", g_tsc_freq * 1.0);
}

// ─── Delay injection (busy-wait on rdtsc) ───────────────────────

inline void inject_delay()
{
    if (g_inject_ns == 0)
        return;
    uint64_t start = __rdtsc();
    uint64_t target = start + g_inject_ns * g_tsc_freq;
    while (__rdtsc() < target)
    {
        _mm_pause();
    }
}

// ─── CXL-emulated operations (the core of the shim) ────────────

// Equivalent of DSM::read() — RDMA READ → memcpy from NUMA pool
inline void cxl_read_node(void *local_buf, uint64_t offset)
{
    void *src = (char *)g_pool + offset;
    inject_delay();
    memcpy(local_buf, src, NODE_SIZE);
}

// Equivalent of DSM::write() — RDMA WRITE → memcpy to NUMA pool
inline void cxl_write_node(const void *local_buf, uint64_t offset)
{
    void *dst = (char *)g_pool + offset;
    inject_delay();
    memcpy(dst, local_buf, NODE_SIZE);
    std::atomic_thread_fence(std::memory_order_release);
}

// Equivalent of DSM::cas() — RDMA CAS → CPU atomic CAS
inline bool cxl_cas(uint64_t offset, uint64_t expected, uint64_t desired)
{
    auto *target = reinterpret_cast<std::atomic<uint64_t> *>(
        (char *)g_pool + offset);
    inject_delay();
    return target->compare_exchange_strong(
        expected, desired, std::memory_order_acq_rel);
}

// ─── Build a fake tree in the pool ──────────────────────────────

void build_fake_tree()
{
    // Create a simple tree structure: each node points to random children
    // at the next level. Level 0 = root, level TREE_HEIGHT-1 = leaves.
    srand(42);
    BTreeNode *nodes = (BTreeNode *)g_pool;

    for (size_t i = 0; i < NUM_NODES; i++)
    {
        nodes[i].version_lock.store(0, std::memory_order_relaxed);
        nodes[i].fence_lo = 0;
        nodes[i].fence_hi = UINT64_MAX;
        nodes[i].num_keys = 10;
        for (int k = 0; k < 60; k++)
            nodes[i].keys[k] = k * 1000 + i;
        for (int c = 0; c < 61; c++)
            nodes[i].children[c] = (rand() % NUM_NODES) * NODE_SIZE;
    }
}

// ─── Benchmark: simulated tree traversal ────────────────────────

struct ThreadResult
{
    double avg_traversal_ns;
    double avg_read_ns;
    double avg_cas_ns;
    uint64_t total_ops;
};

ThreadResult run_benchmark(int thread_id, int num_ops)
{
    BTreeNode local_buf; // stack-allocated local buffer (like DEX's cache)
    uint64_t total_read_ns = 0;
    uint64_t total_cas_ns = 0;
    uint64_t total_trav_ns = 0;
    uint64_t read_count = 0;
    uint64_t cas_count = 0;

    // Pin to local NUMA node
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    // Pick a core on the local node
    struct bitmask *cpus = numa_allocate_cpumask();
    numa_node_to_cpus(g_local_node, cpus);
    int target_cpu = -1, seen = 0;
    for (int i = 0; i < numa_num_possible_cpus(); i++)
    {
        if (numa_bitmask_isbitset(cpus, i))
        {
            if (seen == thread_id % numa_num_configured_cpus())
            {
                target_cpu = i;
                break;
            }
            seen++;
        }
    }
    numa_bitmask_free(cpus);
    if (target_cpu >= 0)
    {
        CPU_SET(target_cpu, &cpuset);
        pthread_setaffinity_np(pthread_self(), sizeof(cpuset), &cpuset);
    }

    // Warmup
    for (int i = 0; i < WARMUP_OPS; i++)
    {
        uint64_t offset = (rand() % NUM_NODES) * NODE_SIZE;
        cxl_read_node(&local_buf, offset);
    }

    // Benchmark
    for (int op = 0; op < num_ops; op++)
    {
        uint64_t trav_start = __rdtsc();

        // Simulate a DEX lookup: traverse TREE_HEIGHT levels
        uint64_t cur_offset = 0; // start at root (node 0)

        for (int level = 0; level < TREE_HEIGHT; level++)
        {
            // 1. Read the node (RDMA READ equivalent)
            uint64_t t0 = __rdtsc();
            cxl_read_node(&local_buf, cur_offset);
            uint64_t t1 = __rdtsc();
            total_read_ns += (t1 - t0);
            read_count++;

            // 2. Optimistic lock check (version read — just an atomic load)
            uint64_t ver = local_buf.version_lock.load(std::memory_order_acquire);
            (void)ver;

            // 3. Search within node for next child (local computation)
            int child_idx = op % 61; // deterministic but varied
            cur_offset = local_buf.children[child_idx];
            // Clamp to valid range
            cur_offset = cur_offset % (NUM_NODES * NODE_SIZE);
        }

        // 4. At leaf: do a CAS to simulate write lock acquisition
        uint64_t t2 = __rdtsc();
        cxl_cas(cur_offset, 0, 1); // try-lock
        uint64_t t3 = __rdtsc();
        total_cas_ns += (t3 - t2);
        cas_count++;

        // 5. Unlock (write version back)
        auto *lock = reinterpret_cast<std::atomic<uint64_t> *>(
            (char *)g_pool + cur_offset);
        lock->store(0, std::memory_order_release);

        uint64_t trav_end = __rdtsc();
        total_trav_ns += (trav_end - trav_start);
    }

    double tsc_to_ns = 1.0 / g_tsc_freq;
    return {
        .avg_traversal_ns = (total_trav_ns * tsc_to_ns) / num_ops,
        .avg_read_ns = (total_read_ns * tsc_to_ns) / read_count,
        .avg_cas_ns = (total_cas_ns * tsc_to_ns) / cas_count,
        .total_ops = (uint64_t)num_ops,
    };
}

// ─── Main ───────────────────────────────────────────────────────

void print_usage(const char *prog)
{
    printf("Usage: %s [--delay NS] [--threads N] [--ops N] [--remote-node N]\n", prog);
    printf("  --delay NS       Inject NS nanoseconds per remote access (default: 0)\n");
    printf("  --threads N      Number of compute threads (default: 1)\n");
    printf("  --ops N          Operations per thread (default: %d)\n", OPS_PER_THREAD);
    printf("  --remote-node N  NUMA node for 'CXL' memory (default: 1)\n");
}

int main(int argc, char **argv)
{
    int num_threads = 1;
    int ops = OPS_PER_THREAD;

    // Parse args
    for (int i = 1; i < argc; i++)
    {
        if (strcmp(argv[i], "--delay") == 0 && i + 1 < argc)
            g_inject_ns = atoi(argv[++i]);
        else if (strcmp(argv[i], "--threads") == 0 && i + 1 < argc)
            num_threads = atoi(argv[++i]);
        else if (strcmp(argv[i], "--ops") == 0 && i + 1 < argc)
            ops = atoi(argv[++i]);
        else if (strcmp(argv[i], "--remote-node") == 0 && i + 1 < argc)
            g_remote_node = atoi(argv[++i]);
        else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0)
        {
            print_usage(argv[0]);
            return 0;
        }
    }

    // Check NUMA
    if (numa_available() < 0)
    {
        fprintf(stderr, "ERROR: NUMA not available. Is libnuma installed?\n");
        return 1;
    }

    int max_node = numa_max_node();
    printf("╔══════════════════════════════════════════════════════════╗\n");
    printf("║  DEX CXL Emulation — Proof of Concept                  ║\n");
    printf("╚══════════════════════════════════════════════════════════╝\n\n");
    printf("NUMA topology: %d nodes detected (max node ID: %d)\n", max_node + 1, max_node);

    if (max_node < 1)
    {
        printf("WARNING: Only 1 NUMA node found.\n");
        printf("  → Enable NPS2 in BIOS for proper CXL emulation.\n");
        printf("  → Running anyway with local-only memory (no NUMA effect).\n");
        g_remote_node = 0;
    }

    // Print NUMA distances
    printf("NUMA distances:\n");
    for (int i = 0; i <= max_node; i++)
    {
        printf("  node %d →", i);
        for (int j = 0; j <= max_node; j++)
            printf(" [%d]=%d", j, numa_distance(i, j));
        printf("\n");
    }

    printf("\nConfiguration:\n");
    printf("  Local (compute) NUMA node: %d\n", g_local_node);
    printf("  Remote (CXL) NUMA node:    %d\n", g_remote_node);
    printf("  Injected delay:            %lu ns\n", g_inject_ns);
    printf("  Threads:                   %d\n", num_threads);
    printf("  Ops/thread:                %d\n", ops);
    printf("  Node size:                 %zu bytes\n", NODE_SIZE);
    printf("  Pool size:                 %zu MB\n", POOL_SIZE >> 20);
    printf("  Tree height:               %d levels\n", TREE_HEIGHT);

    // Calibrate TSC
    printf("\nCalibrating TSC...\n");
    calibrate_tsc();

    // Allocate pool on remote NUMA node
    printf("Allocating %zu MB on NUMA node %d...\n", POOL_SIZE >> 20, g_remote_node);
    g_pool = numa_alloc_onnode(POOL_SIZE, g_remote_node);
    if (!g_pool)
    {
        fprintf(stderr, "ERROR: numa_alloc_onnode failed\n");
        return 1;
    }

    // Fault pages in and build tree
    printf("Building fake B+-tree in remote memory...\n");
    build_fake_tree();

    // ── Baseline: measure raw NUMA latency with pointer chasing ──
    printf("\n── Raw NUMA Latency (pointer chase, no delay injection) ──\n");
    {
        // Simple pointer chase through the pool
        volatile uint64_t *chase = (volatile uint64_t *)g_pool;
        // Build a random chase chain
        std::vector<uint64_t> indices(NUM_NODES);
        for (size_t i = 0; i < NUM_NODES; i++)
            indices[i] = i;
        for (size_t i = NUM_NODES - 1; i > 0; i--)
        {
            size_t j = rand() % (i + 1);
            std::swap(indices[i], indices[j]);
        }
        for (size_t i = 0; i < NUM_NODES; i++)
        {
            size_t next = indices[(i + 1) % NUM_NODES];
            ((uint64_t *)g_pool)[indices[i] * (NODE_SIZE / 8)] = next * (NODE_SIZE / 8);
        }

        // Chase
        uint64_t idx = 0;
        int chase_iters = 100000;
        // warmup
        for (int i = 0; i < 10000; i++)
            idx = chase[idx];

        uint64_t t0 = __rdtsc();
        for (int i = 0; i < chase_iters; i++)
            idx = chase[idx];
        uint64_t t1 = __rdtsc();

        double ns_per_chase = (double)(t1 - t0) / g_tsc_freq / chase_iters;
        printf("  Pointer chase latency: %.1f ns (this is your baseline NUMA penalty)\n",
               ns_per_chase);
        // Prevent optimization
        if (idx == 0xDEAD)
            printf("never\n");
    }

    // ── Run the traversal benchmark ──
    printf("\n── Traversal Benchmark ──\n");

    std::vector<std::thread> threads;
    std::vector<ThreadResult> results(num_threads);

    auto wall_start = std::chrono::high_resolution_clock::now();

    for (int t = 0; t < num_threads; t++)
    {
        threads.emplace_back([&, t]()
                             { results[t] = run_benchmark(t, ops); });
    }
    for (auto &t : threads)
        t.join();

    auto wall_end = std::chrono::high_resolution_clock::now();
    double wall_ms = std::chrono::duration<double, std::milli>(wall_end - wall_start).count();

    // Aggregate results
    double sum_trav = 0, sum_read = 0, sum_cas = 0;
    uint64_t total_ops = 0;
    for (auto &r : results)
    {
        sum_trav += r.avg_traversal_ns;
        sum_read += r.avg_read_ns;
        sum_cas += r.avg_cas_ns;
        total_ops += r.total_ops;
    }

    double avg_trav = sum_trav / num_threads;
    double avg_read = sum_read / num_threads;
    double avg_cas = sum_cas / num_threads;
    double throughput_mops = (total_ops / wall_ms) / 1000.0;

    printf("\n┌────────────────────────────────┬──────────────┐\n");
    printf("│ Metric                         │ Value        │\n");
    printf("├────────────────────────────────┼──────────────┤\n");
    printf("│ Avg 1KB node read              │ %8.1f ns   │\n", avg_read);
    printf("│ Avg CAS (lock acquire)         │ %8.1f ns   │\n", avg_cas);
    printf("│ Avg full traversal (%d levels) │ %8.1f ns   │\n", TREE_HEIGHT, avg_trav);
    printf("│ Aggregate throughput           │ %8.3f Mops │\n", throughput_mops);
    printf("│ Wall time                      │ %8.1f ms   │\n", wall_ms);
    printf("└────────────────────────────────┴──────────────┘\n");

    printf("\n── Comparison Context ──\n");
    printf("  RDMA READ (1KB, ConnectX-5):    ~2000 ns\n");
    printf("  RDMA CAS (ConnectX-5):          ~2000 ns\n");
    printf("  Your CXL-emulated read:         %.0f ns\n", avg_read);
    printf("  Your CXL-emulated CAS:          %.0f ns\n", avg_cas);
    printf("  Speedup factor (read):          ~%.1fx\n", 2000.0 / avg_read);
    printf("  Speedup factor (CAS):           ~%.1fx\n", 2000.0 / avg_cas);

    printf("\n── What This Means for DEX ──\n");
    if (avg_cas < 500)
    {
        printf("  ✓ CAS is %.0fx cheaper than RDMA CAS.\n", 2000.0 / avg_cas);
        printf("    → Logical partitioning's sync-avoidance value drops sharply.\n");
        printf("    → Shared-node optimistic locking becomes cheap.\n");
    }
    if (avg_read < 500)
    {
        printf("  ✓ Node reads are %.0fx cheaper than RDMA READ.\n", 2000.0 / avg_read);
        printf("    → Cache replacement frequency drops proportionally.\n");
        printf("    → Cooling map contention may no longer be the bottleneck.\n");
        printf("    → Offloading rarely wins (load/store already fast).\n");
    }

    printf("\n── Next Steps ──\n");
    printf("  1. Run with --delay 70 to model ASIC CXL latency\n");
    printf("  2. Run with --delay 150 to model FPGA CXL prototypes\n");
    printf("  3. Sweep --threads 1,2,4,8,16,32 to test scaling\n");
    printf("  4. Compare these numbers to your RDMA reproduction results\n");

    numa_free(g_pool, POOL_SIZE);
    return 0;
}