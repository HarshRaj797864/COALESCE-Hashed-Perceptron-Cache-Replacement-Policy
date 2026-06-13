#!/usr/bin/env python3
"""Generate the four figures for the COALESCE HiPC paper.

Data hardcoded from docs/results_compendium.md (commit fa1de3a).
All numbers are total execution cycles (max over CPUs of the final
100M-instruction region), shared-VMEM regime.

Run:  python3 generate_figures.py   (writes fig_*.png next to the .tex)
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

plt.rcParams.update({
    "font.size": 11,
    "axes.spines.top": False,
    "axes.spines.right": False,
    "figure.dpi": 300,
})

COALESCE_C = "#1a6faf"   # highlight colour
BASE_C = "#9bb7cc"       # baseline grey-blue
BAD_C = "#c44e52"        # for negatives

# ---------------------------------------------------------------- data
canneal = {
    # policy: (4-core cycles, 8-core cycles)
    "COALESCE":   (267_251_645, 301_945_789),
    "Hawkeye":    (286_865_528, 317_172_523),
    "SRRIP":      (287_031_501, 303_011_899),
    "SHiP":       (288_163_881, 316_393_994),
    "DRRIP":      (294_947_400, 325_848_199),
    "Mockingjay": (311_277_369, 393_934_080),
    "LRU":        (392_999_637, 392_564_736),
}

scaling = {  # canneal, COALESCE only
    "cores": [4, 8, 16],
    "cycles": [267_251_645, 301_945_789, 348_247_158],
    "bottleneck_ipc": [0.3742, 0.332, 0.294],
}

geomean = {
    # COALESCE speedup vs each baseline: (4-core %, 8-core %), both over the
    # full 4-benchmark suite (canneal, ocean, fluidanimate, barnes).
    # positive = COALESCE faster
    "LRU":        (9.7, 6.2),
    "Hawkeye":    (1.5, 1.0),
    "Mockingjay": (13.9, 17.0),
    "DRRIP":      (0.2, -0.4),
    "SHiP":       (-0.4, -1.2),
    "SRRIP":      (-0.5, -2.3),
}

ablation = {
    # label: delta % (positive = sharer feature helps = full COALESCE faster)
    "canneal 4c": -0.002,
    "canneal 8c": -0.41,
    "ocean 4c":   7.3,
    "ocean 8c":   7.2,
    "barnes 4c":  0.13,
}

# ---------------------------------------------------------- fig_canneal
def fig_canneal():
    pols = list(canneal.keys())
    x = np.arange(len(pols))
    w = 0.38
    c4 = [canneal[p][0] / 1e6 for p in pols]
    c8 = [canneal[p][1] / 1e6 for p in pols]
    fig, ax = plt.subplots(figsize=(6.4, 3.4))
    colors = [COALESCE_C if p == "COALESCE" else BASE_C for p in pols]
    ax.bar(x - w / 2, c4, w, label="4-core", color=colors, edgecolor="black", linewidth=0.4)
    ax.bar(x + w / 2, c8, w, label="8-core", color=colors, edgecolor="black",
           linewidth=0.4, hatch="//")
    ax.set_xticks(x)
    ax.set_xticklabels(pols, rotation=20, ha="right")
    ax.set_ylabel("Total cycles (millions)")
    ax.legend(frameon=False, ncol=2)
    ax.set_ylim(0, 450)
    fig.tight_layout()
    fig.savefig("fig_canneal.png")
    plt.close(fig)

# ---------------------------------------------------------- fig_scaling
def fig_scaling():
    fig, ax1 = plt.subplots(figsize=(5.0, 3.0))
    cores = scaling["cores"]
    cyc = [c / 1e6 for c in scaling["cycles"]]
    ax1.plot(cores, cyc, "o-", color=COALESCE_C, linewidth=2, label="Total cycles")
    ax1.set_xlabel("Cores")
    ax1.set_ylabel("Total cycles (millions)", color=COALESCE_C)
    ax1.tick_params(axis="y", colors=COALESCE_C)
    ax1.set_xticks(cores)
    ax1.set_ylim(0, 400)
    ax2 = ax1.twinx()
    ax2.plot(cores, scaling["bottleneck_ipc"], "s--", color=BAD_C,
             linewidth=2, label="Bottleneck IPC")
    ax2.set_ylabel("Bottleneck-core IPC", color=BAD_C)
    ax2.tick_params(axis="y", colors=BAD_C)
    ax2.set_ylim(0, 0.45)
    ax2.spines["right"].set_visible(True)
    fig.tight_layout()
    fig.savefig("fig_scaling.png")
    plt.close(fig)

# ---------------------------------------------------------- fig_geomean
def fig_geomean():
    pols = list(geomean.keys())
    x = np.arange(len(pols))
    w = 0.38
    g4 = [geomean[p][0] for p in pols]
    g8 = [geomean[p][1] for p in pols]
    fig, ax = plt.subplots(figsize=(6.4, 3.2))
    def cols(vals):
        return [COALESCE_C if v >= 0 else BAD_C for v in vals]
    ax.bar(x - w / 2, g4, w, color=cols(g4), edgecolor="black", linewidth=0.4,
           label="4-core (4 benchmarks)")
    ax.bar(x + w / 2, g8, w, color=cols(g8), edgecolor="black", linewidth=0.4,
           hatch="//", label="8-core (3 benchmarks)")
    ax.axhline(0, color="black", linewidth=0.8)
    ax.set_xticks(x)
    ax.set_xticklabels(pols, rotation=20, ha="right")
    ax.set_ylabel("Geomean speedup of\nCOALESCE (%)")
    for xi, v in zip(x - w / 2, g4):
        ax.text(xi, v + (0.5 if v >= 0 else -1.6), f"{v:+.1f}", ha="center", fontsize=8)
    for xi, v in zip(x + w / 2, g8):
        ax.text(xi, v + (0.5 if v >= 0 else -1.6), f"{v:+.1f}", ha="center", fontsize=8)
    ax.legend(frameon=False)
    fig.tight_layout()
    fig.savefig("fig_geomean.png")
    plt.close(fig)

# ---------------------------------------------------------- fig_ablation
def fig_ablation():
    labels = list(ablation.keys())
    vals = [ablation[k] for k in labels]
    x = np.arange(len(labels))
    fig, ax = plt.subplots(figsize=(5.4, 3.0))
    colors = [COALESCE_C if v >= 0 else BAD_C for v in vals]
    ax.bar(x, vals, 0.55, color=colors, edgecolor="black", linewidth=0.4)
    ax.axhline(0, color="black", linewidth=0.8)
    ax.set_xticks(x)
    ax.set_xticklabels(labels, rotation=15, ha="right")
    ax.set_ylabel("Sharer-feature contribution (%)")
    for xi, v in zip(x, vals):
        ax.text(xi, v + (0.25 if v >= 0 else -0.55), f"{v:+.2f}", ha="center", fontsize=9)
    ax.set_ylim(-1.5, 8.5)
    fig.tight_layout()
    fig.savefig("fig_ablation.png")
    plt.close(fig)

if __name__ == "__main__":
    fig_canneal()
    fig_scaling()
    fig_geomean()
    fig_ablation()
    print("wrote fig_canneal.png fig_scaling.png fig_geomean.png fig_ablation.png")
