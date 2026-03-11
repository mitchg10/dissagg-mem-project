File structure

project/
├── profile.py                  # CloudLab geni-lib profile 
├── setup.sh                    # Node bootstrap to run on boot
├── scripts/
│   ├── verify_cluster.sh       # RDMA and network verification
│   ├── run_all_experiments.sh  # Master experiment orchestrator
│   ├── run_single.sh           # Wrapper for one experiment run
│   ├── collect_results.sh      # Gather results from all nodes
│   ├── backup_results.sh       # SCP results off-cluster before time expires
│   └── build_baselines.sh      # Build Sherman + SMART
├── configs/
│   ├── memcached.conf.template # Template (filled by setup.sh)
│   └── experiment_matrix.csv   # All experiment configurations
├── analysis/
│   ├── plot_results.py         # Generate paper-matching figures
│   ├── parse_logs.py           # Extract throughput/latency from logs
│   └── requirements.txt        # Python deps for analysis
└── docs/
    ├── experiment_log.md        # Live notes template during experiments
    └── presentation_outline.md  # Outline for Part 1 presentation