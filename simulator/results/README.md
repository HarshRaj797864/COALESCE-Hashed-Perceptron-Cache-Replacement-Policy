# Experimental results

Results are organised by **regime** (private vs shared VMEM) and **workload**
(canneal, fluidanimate, ...) to avoid any cross-contamination between the
two paper regimes.

```
results/
├── regime1_private_vmem/      # Default ChampSim VMEM. Each CPU has its own
│   │                            address space. Sharer-count is always 1;
│   │                            coherence features are dormant.
│   └── canneal/
│       ├── 4core_50M_v0/      # V0 config (SAMPLING=16, GHOST=256). Per-policy
│       │                       files final_<POLICY>_50M.txt.
│       ├── 8core_100M_v0/     # V0 config, COALESCE + SRRIP only.
│       ├── 8core_100M_v2/     # V2 config (SAMPLING=32, GHOST=128 +
│       │                       Bloom-reset). RESULTS_*.md + CSV.
│       └── 16core_100M_v2/    # V2 config. Logs in logs/. The "trace
│                               truncation" reading earlier in the project
│                               was a misread — see saga1_plan.md § 1.
│
├── regime2_shared_vmem/       # VMEM overlay enabled. Identical VAs across
│   │                            cores alias on the same physical page.
│   │                            Sharer counts > 1 happen; +20×sharer bias
│   │                            and coherence machinery fire.
│   ├── canneal/
│   │   ├── 4core/             # 1 policy so far (coalesce). Sharer bin[2+]
│   │   │                       = 1.45 %, INVALIDATIONS = 106 K.
│   │   └── 8core/             # 1 policy so far (coalesce). Sharer bin[2+]
│   │                           = 25.6 %, INVALIDATIONS = 6.9 M, max_cycles
│   │                           27 % lower than regime1 V2 same length.
│   └── fluidanimate/
│       └── 4core/             # All 7 policies. Sharing barely fires
│                               (bin[2+] = 0.3 %, INVALIDATIONS = 0).
│                               COALESCE is last (+5.0 % vs DRRIP). 4-core
│                               fluidanimate is outside the policy's
│                               sweet spot.
└── README.md                  # This file.
```

## Quick reference: regime → workload → headline number

### Regime 1 (private VMEM, capacity-pressure)

| workload | cores | sim/core | COALESCE vs best baseline |
|---|---|---|---|
| canneal | 4 | 50 M | −24.2 % LRU; +1.8 % behind SHiP (A1 weakness) |
| canneal | 8 | 100 M | **+33 % over SRRIP** (headline) |
| canneal | 16 | 100 M | **+31.6 % over RRIP family**, +21.6 % over LRU |

### Regime 2 (shared VMEM, true-sharing)

| workload | cores | sim/core | result |
|---|---|---|---|
| canneal | 4 | 100 M | COALESCE fires: sharer bin[2..4] = 1.45 %, INV = 106 K |
| canneal | 8 | 100 M | **COALESCE 27 % faster than its regime-1 self**; sharer bin[2..8] = 25.6 %, INV = 6.9 M |
| canneal | 16 | – | (in progress) |
| fluidanimate | 4 | – | COALESCE last (+5 % vs DRRIP). Read-only sharing → INV = 0 |
| fluidanimate | 8 | – | (in progress) |

## Compatibility with older docs

Older docs (SESSION_CONTEXT.md, coherence_aware.md, saga1_plan.md) reference
the legacy paths. The mapping is:

| legacy path | current path |
|---|---|
| `canneal_4core_50M/`            | `regime1_private_vmem/canneal/4core_50M_v0/` |
| `canneal_8core_100M/`           | `regime1_private_vmem/canneal/8core_100M_v0/` |
| `phase2a_8core_canneal_V2/`     | `regime1_private_vmem/canneal/8core_100M_v2/` |
| `phase2b_16core_canneal_V2/`    | `regime1_private_vmem/canneal/16core_100M_v2/` |
| `phase2_canneal_shared/logs/coalesce_4core.log`   | `regime2_shared_vmem/canneal/4core/coalesce.log` |
| `phase2_canneal_shared/logs/coalesce_8core.log`   | `regime2_shared_vmem/canneal/8core/coalesce.log` |
| `phase2_fluidanimate_shared/logs/<pol>_4core.log` | `regime2_shared_vmem/fluidanimate/4core/<pol>.log` |

Doc updates can wait — server-side scripts have not been changed and should
just write to the new paths going forward.
