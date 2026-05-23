# Phase 1 — Citation Map & Architectural Justification

> **Status**: Day 1 in progress (May 21, 2026)
> **Owner**: Harsh (with Claude Code assistance)
> **Deadline**: Lock by **end of Week 2 (June 3, 2026)** — Phase 3 paper rewrite depends on this
> **Goal**: Every magic number in the COALESCE paper gets a citation OR a derivation. Zero unjustified assertions.
>
> Related: `docs/PUBLICATION_STRATEGY.md` § Weakness Inventory B and D · `ARCHITECTURE.md` · `CLAUDE.md`

---

## 0. Day 1 Minimum (Thursday May 21, 2026)

Before end of day Thursday, complete these in order:

- [x] Create directory: `coalesce_paper/citations/`
- [x] Initialize `references.bib` with first 5 BibTeX entries (Day 1 batch — § 3)
- [x] Write the DRAM-latency justification paragraph (`justifications/B1_dram_latency.md`)
- [x] Write the perceptron lineage paragraph (`justifications/B5_set_sampling.md` + D10 note)
- [x] Derive Bloom filter false-positive rate (`justifications/B7_bloom_filter_math.md`)
- [x] Skeleton for `champsim_params_used.md` filled with discovered defaults

The other items can land across Days 2–10.

---

## 1. Directory Layout

```
coalesce_paper/
├── citations/
│   ├── references.bib              ← THE master BibTeX file
│   ├── citation_map.md             ← This file
│   ├── justifications/
│   │   ├── B1_dram_latency.md      ← done Day 1
│   │   ├── B2_modified_bias.md     ← Phase 2D blocker (bias sweep)
│   │   ├── B3_sharer_bias.md       ← Phase 2D blocker
│   │   ├── B4_ghost_boost.md
│   │   ├── B5_set_sampling.md      ← done Day 1
│   │   ├── B6_confidence_theta.md
│   │   ├── B7_bloom_filter_math.md ← done Day 1
│   │   ├── B8_mesi_coding.md
│   │   ├── B9_pc_hashing.md
│   │   └── B10_mesi_protocol.md
│   └── related_work_notes/
│       ├── D1_hawkeye.md
│       ├── D2_mockingjay.md
│       ├── D3_glider.md
│       ├── D4_ship.md
│       ├── D5_drrip_srrip.md
│       ├── D6_belady.md
│       ├── D7_cuesta_coherence_deactivation.md
│       ├── D8_hardavellas_rnuca.md
│       ├── D9_sorin_primer.md
│       ├── D10_jimenez_lin_perceptron.md
│       └── D11_hennessy_patterson.md
└── champsim_params_used.md         ← Document the actual ChampSim config used
```

---

## 2. Acceptance Criteria

A justification document is "done" when:
1. It cites a peer-reviewed source (or textbook, or canonical implementation) for the value
2. It includes the **exact passage / equation / table** quoted or paraphrased from the source (paraphrased, with citation marker — no copyright violations)
3. It reconciles the cited value with the value used in COALESCE (e.g., "Hennessy & Patterson report 200–300 cycle DRAM access for DDR4-2400; we use the ChampSim default of 240 cycles which falls in this range")
4. It has a BibTeX key registered in `references.bib`

---

## 3. The BibTeX Master File — `references.bib`

Build this in priority order. **Day 1 batch first:**

### Day 1 batch (5 entries — the foundations)

```bibtex
@inproceedings{jimenez2017multiperspective,
  author    = {Daniel A. Jiménez},
  title     = {Multiperspective Reuse Prediction},
  booktitle = {Proc. IEEE/ACM Int. Symp. Microarchitecture (MICRO)},
  pages     = {436--448},
  year      = {2017}
}

@inproceedings{jaleel2010rrip,
  author    = {Aamer Jaleel and Kevin B. Theobald and Simon C. Steely Jr. and Joel Emer},
  title     = {High Performance Cache Replacement Using Re-Reference Interval Prediction (RRIP)},
  booktitle = {Proc. Int. Symp. Computer Architecture (ISCA)},
  pages     = {60--71},
  year      = {2010}
}

@inproceedings{wu2011ship,
  author    = {Carole-Jean Wu and Aamer Jaleel and Will Hasenplaugh and Margaret Martonosi and Simon C. Steely Jr. and Joel Emer},
  title     = {{SHiP}: Signature-Based Hit Predictor for High Performance Caching},
  booktitle = {Proc. IEEE/ACM Int. Symp. Microarchitecture (MICRO)},
  pages     = {430--441},
  year      = {2011}
}

@book{sorin2011coherence,
  author    = {Daniel J. Sorin and Mark D. Hill and David A. Wood},
  title     = {A Primer on Memory Consistency and Cache Coherence},
  publisher = {Morgan \& Claypool},
  series    = {Synthesis Lectures on Computer Architecture},
  year      = {2011}
}

@book{hennessy2017quantitative,
  author    = {John L. Hennessy and David A. Patterson},
  title     = {Computer Architecture: A Quantitative Approach},
  edition   = {6},
  publisher = {Morgan Kaufmann},
  year      = {2017}
}
```

### Week 1 batch (5 more — ML cache replacement lineage)

```bibtex
@inproceedings{jain2016hawkeye,
  author    = {Akanksha Jain and Calvin Lin},
  title     = {Back to the Future: Leveraging {Belady's} Algorithm for Improved Cache Replacement},
  booktitle = {Proc. Int. Symp. Computer Architecture (ISCA)},
  pages     = {78--89},
  year      = {2016}
}

@inproceedings{shi2019glider,
  author    = {Zhan Shi and Xiangru Huang and Akanksha Jain and Calvin Lin},
  title     = {Applying Deep Learning to the Cache Replacement Problem},
  booktitle = {Proc. IEEE/ACM Int. Symp. Microarchitecture (MICRO)},
  pages     = {413--425},
  year      = {2019}
}

@inproceedings{shah2022mockingjay,
  author    = {Ishan Shah and Akanksha Jain and Calvin Lin},
  title     = {Effective Mimicry of {Belady's} {MIN} Policy},
  booktitle = {Proc. IEEE Int. Symp. High-Performance Computer Architecture (HPCA)},
  year      = {2022}
}

@inproceedings{jimenez2001perceptron,
  author    = {Daniel A. Jiménez and Calvin Lin},
  title     = {Dynamic Branch Prediction with Perceptrons},
  booktitle = {Proc. IEEE Int. Symp. High-Performance Computer Architecture (HPCA)},
  pages     = {197--206},
  year      = {2001}
}

@article{belady1966study,
  author  = {L. A. Belady},
  title   = {A Study of Replacement Algorithms for a Virtual-Storage Computer},
  journal = {IBM Systems Journal},
  volume  = {5},
  number  = {2},
  pages   = {78--101},
  year    = {1966}
}
```

### Week 2 batch (the rest — coherence + measurement + supporting)

```bibtex
@inproceedings{cuesta2011coherence,
  author    = {Blas Cuesta and Alberto Ros and María E. Gómez and Antonio Robles and José Duato},
  title     = {Increasing the Effectiveness of Directory Caches by Deactivating Coherence for Private Memory Blocks},
  booktitle = {Proc. Int. Symp. Computer Architecture (ISCA)},
  pages     = {93--104},
  year      = {2011}
}

@inproceedings{hardavellas2009rnuca,
  author    = {Nikos Hardavellas and Michael Ferdman and Babak Falsafi and Anastasia Ailamaki},
  title     = {Reactive {NUCA}: Near-Optimal Block Placement and Replication in Distributed Caches},
  booktitle = {Proc. Int. Symp. Computer Architecture (ISCA)},
  pages     = {184--195},
  year      = {2009}
}

@inproceedings{molka2009memory,
  author    = {Daniel Molka and Daniel Hackenberg and Robert Schöne and Matthias S. Müller},
  title     = {Memory Performance and Cache Coherency Effects on an {Intel} {Nehalem} Multiprocessor System},
  booktitle = {Proc. Int. Conf. Parallel Architectures and Compilation Techniques (PACT)},
  pages     = {261--270},
  year      = {2009}
}

@inproceedings{sethumurugan2021designing,
  author    = {Subhash Sethumurugan and Jieming Yin and John Sartori},
  title     = {Designing a Cost-Effective Cache Replacement Policy Using Machine Learning},
  booktitle = {Proc. IEEE Int. Symp. High-Performance Computer Architecture (HPCA)},
  pages     = {291--303},
  year      = {2021}
}

@article{souza2024rl,
  author  = {Marco A. Z. Souza and Henrique C. Freitas},
  title   = {Reinforcement Learning-Based Cache Replacement Policies for Multicore Processors},
  journal = {IEEE Access},
  volume  = {12},
  year    = {2024}
}

@inproceedings{wu2025camp,
  author    = {Yujie Wu and others},
  title     = {Concurrency-Aware Cache Miss Cost Prediction with Perceptron Learning},
  booktitle = {Proc. ACM Great Lakes Symp. VLSI (GLSVLSI)},
  year      = {2025}
}

@inproceedings{bienia2008parsec,
  author    = {Christian Bienia and Sanjeev Kumar and Jaswinder Pal Singh and Kai Li},
  title     = {The {PARSEC} Benchmark Suite: Characterization and Architectural Implications},
  booktitle = {Proc. Int. Conf. Parallel Architectures and Compilation Techniques (PACT)},
  pages     = {72--81},
  year      = {2008}
}

@misc{champsim,
  title        = {{ChampSim} Simulator},
  howpublished = {\url{https://github.com/ChampSim/ChampSim}},
  note         = {Accessed: May 2026}
}

@inproceedings{luk2005pin,
  author    = {Chi-Keung Luk and Robert Cohn and Robert Muth and Harish Patil and Artur Klauser and Geoff Lowney and Steven Wallace and Vijay Janapa Reddi and Kim Hazelwood},
  title     = {Pin: Building Customized Program Analysis Tools with Dynamic Instrumentation},
  booktitle = {Proc. ACM SIGPLAN Conf. Programming Language Design and Implementation (PLDI)},
  pages     = {190--200},
  year      = {2005}
}
```

**Claude Code task**: build this file incrementally. For each entry above, also create a one-paragraph summary note in `related_work_notes/Dx_<name>.md` with: (1) key contribution, (2) what feature(s) it uses, (3) what gap remains (relative to COALESCE), (4) how COALESCE differs.

---

## 4. Architectural Justifications (B1–B10)

For each, the deliverable is the per-item .md file in `justifications/`. Format template:

```markdown
# Bx — <Topic>

## Claim in the paper
<The exact claim or value used, with section reference>

## Cited evidence
<Quoted/paraphrased passage from the source(s), with BibTeX key>

## Reconciliation
<Why our value matches or relates to the cited evidence>

## ChampSim configuration (if relevant)
<The actual parameter values from our config>
```

### B1 — DRAM writeback latency "200+ cycles"

**Sources to use**:
- Hennessy & Patterson 6th ed., Chapter 2 (Memory Hierarchy): typical DDR4 DRAM access ≈ 200–300 cycles measured from CPU
- Intel 64 and IA-32 Architectures Optimization Reference Manual: current Skylake-family numbers (~250–300 cycles to DRAM, ~40 cycles to LLC) — search for the latest version on intel.com
- Molka et al. PACT 2009 — measured values
- ChampSim default DRAM model: tRCD, tCAS, tRP values (find these in `dram_controller.cc` or equivalent in your ChampSim checkout)

**What to write**: A paragraph that establishes 200+ cycles is well-supported, plus a sentence that documents what ChampSim's DRAM model uses in your configuration.

### B2 — Modified bias value (+150)

**Status**: This *cannot* be cited from prior work — it's our parameter. Must be empirically derived in Phase 2D bias sweep.

**What to write now**: A placeholder note explaining "the +150 value will be derived from the bias sweep in Phase 2D; the rationale is that it approximates the cycle ratio between a Modified-state writeback (≈250 cycles, see B1) and a clean miss with no coherence penalty (which still incurs the same DRAM cost on the next access but does not require the additional bus transaction for the writeback)."

**After Phase 2D**: Update with the sweep result and reframe the +150 as the empirical optimum.

### B3 — Sharer bias value (+75)

Same as B2 — empirically derived. Document the intuition now: +75 is approximately half of +150 because the cost of invalidating a Shared line is amortized across multiple re-fetches by sharing cores, but each individual core's penalty is smaller than a full writeback.

### B4 — 5× ghost-hit weight boost

**Sources**: Jiménez 2017 multiperspective uses similar boost factors. Check the paper for the exact training rule.

**Fallback**: If no exact prior art, frame it as a hyperparameter chosen by light tuning; mention it could be set 3× or 7× without changing the qualitative result. Phase 2D ablation can add a quick sweep here if time permits.

### B5 — 6.25% set sampling

**Source**: Jiménez 2017 § Set Sampling. The 1/16 = 6.25% rate is the standard in MICRO-class perceptron predictors since Jiménez & Lin 2001.

**Cite**: `jimenez2017multiperspective` and `jimenez2001perceptron`. Add a sentence: "Set sampling at 1-in-16 (6.25%) follows established practice in perceptron-based predictors [jimenez2017multiperspective], reducing write-port pressure on the weight tables with negligible accuracy loss."

### B6 — Confidence threshold θ

**What to write**: First, find the actual θ value in the COALESCE source code. If it's not explicitly tunable, document the implicit threshold (e.g., "training only triggers when |vote| ≤ 16 in our 8-bit saturating counter design"). Justify by comparing to Jiménez 2017's training threshold values.

### B7 — Bloom filter parameters (1024-bit, 3 hashes)

See § 5 below for the full derivation. This file should contain just the result and reference § 5.

### B8 — MESI state coding (2 bits)

**What to write**: Trivial — 4 states = 2 bits. Cite Sorin/Hill/Wood for the canonical MESI definition. Note the 2 bits are *part of the cache block's coherence state field* and not additional overhead introduced by COALESCE.

### B9 — PC hashing function H0, H1

**What to write**: Document the exact hash functions used. From the paper, H0 = hash(PC ⊕ MESI_state), H1 = hash(PC ⊕ Sharer_count). Specify the hash: typically XOR-fold + truncation to log2(table_size) bits. For 2048-entry tables, that's 11 bits.

Write the exact bit-level operation: e.g., `index = ((PC >> 2) ^ (PC >> 13) ^ (state_or_count << 8)) & 0x7FF`.

### B10 — MESI protocol reference

**Source**: Sorin/Hill/Wood § MSI/MESI/MOESI. Cite once in Background section, with explicit invalidation cost discussion.

---

## 5. Bloom Filter Math Derivation (B7)

For a Bloom filter with m bits, n inserted elements, and k hash functions, the false-positive rate is approximately:

$$P_{FP} = \left(1 - \left(1 - \frac{1}{m}\right)^{kn}\right)^k \approx \left(1 - e^{-kn/m}\right)^k$$

The optimal number of hash functions for given m and n is:

$$k^* = \frac{m}{n} \ln 2$$

**Our parameters**: m = 1024 bits, k = 3 hash functions.

**Step 1**: Solve for the n that makes k = 3 optimal:
$$3 = \frac{1024}{n} \ln 2 \implies n = \frac{1024 \ln 2}{3} \approx 237 \text{ entries}$$

**Step 2**: Compute the FP rate at this design point:
$$P_{FP} = \left(1 - e^{-3 \cdot 237 / 1024}\right)^3 = \left(1 - e^{-0.694}\right)^3 \approx (0.500)^3 = 0.125$$

So at the design occupancy (~237 evictions tracked), the FP rate is ~12.5%.

**Step 3**: Compute the FP rate at half-occupancy (~118 entries):
$$P_{FP} = \left(1 - e^{-3 \cdot 118 / 1024}\right)^3 \approx (0.293)^3 \approx 0.025$$

So at half-occupancy, FP rate is ~2.5%.

**Interpretation paragraph for the paper**:
> "The 1024-bit Bloom filter with k=3 hash functions is dimensioned for an expected occupancy of approximately 237 evicted addresses per sampled set, at which the false-positive rate is 12.5%. In practice, the filter is reset periodically (every N evictions in our implementation; specify N), keeping average occupancy below 150 entries and the effective FP rate below 5%. A false positive in the ghost buffer triggers a spurious training event, which causes only mild noise in the perceptron weights since training updates are bounded by saturating counters."

**Claude Code task**: verify the exact filter reset behavior in the COALESCE source code, update the N above, and recompute the operating-point FP rate.

---

## 6. Related Work Expansion (D1–D11)

For each entry in § 3, write a per-paper note (in `related_work_notes/`) and a 1–2 sentence summary that will appear in the paper's Related Work section.

**Sub-categorize Related Work into:**
1. **Classical replacement policies** — Belady (D6), LRU (textbook), RRIP/DRRIP (D5)
2. **ML-based replacement** — SHiP (D4), Hawkeye (D1), Glider (D3), Mockingjay (D2), Sethumurugan HPCA 2021 (already in bib), Wu 2025 CAMP (in bib)
3. **Perceptron predictors** — Jiménez & Lin 2001 (D10), Jiménez 2017 multiperspective
4. **Coherence-aware optimization** — Cuesta 2011 (D7), Hardavellas R-NUCA (D8), Souza 2024 (in bib)
5. **Background references** — Sorin/Hill/Wood (D9), Hennessy & Patterson (D11)

The paper's Related Work section is then organized in **these 5 subsections** rather than a flat list. Reviewers love structured related work.

---

## 7. Documenting the ChampSim Config (`champsim_params_used.md`)

This file documents what we actually ran with. See `coalesce_paper/champsim_params_used.md` for the live version — Day 1 fills it with the defaults discovered from `simulator/config/parse.py` and `btp_config.json`.

---

## 8. Deliverables Checklist

End of Week 1 (May 27):
- [ ] `references.bib` has Day 1 + Week 1 batches (10 entries)
- [ ] B1, B5, B7, B8, B10 justifications written
- [ ] D1, D4, D5, D6, D9, D10, D11 related-work notes written
- [ ] `champsim_params_used.md` template filled in

End of Week 2 (June 3):
- [ ] `references.bib` complete (all 16+ entries)
- [ ] All B1–B10 justifications written (B2, B3 marked as "awaiting Phase 2D")
- [ ] All D1–D11 related-work notes complete
- [ ] Related Work section draft text written (~1000 words for the paper)

After Phase 2D completes (~June 10):
- [ ] B2, B3 updated with empirical sweep results
- [ ] B4 updated if ablation done

---

## 9. Instructions to Claude Code

When opening this in Claude Code:

1. **First**: read this file fully and create the directory structure in § 1
2. **Second**: create `references.bib` with the Day 1 batch in § 3
3. **Third**: for each B and D item, create a stub file in the appropriate subdirectory using the template in § 4
4. **Then**: web_search for any missing details (e.g., latest Intel optimization manual numbers, Mockingjay paper PDF, etc.) and fill in the justifications
5. **Don't fabricate**: if a number can't be verified, mark it `[TODO: verify]` and add to the open-questions list
6. **Commit incrementally**: after each justification file is complete, git commit it with a clear message

**Verification rule**: every BibTeX entry should be cross-checked against a known database (DBLP, ACM Digital Library, IEEE Xplore) for accurate volume/page numbers. Don't ship a paper with a fabricated reference.

---

## 10. Open questions discovered while executing Day 1

- **Bloom filter never resets in code** (see `simulator/replacement/coalesce/coalesce.cc` — `BloomFilter::insert` only sets bits; the `bit_array` is never cleared after construction). Implication: under long simulations the bit_array saturates and the FP rate grows toward 100%. The `ghost_tags` array (256 entries per sampled set) is bounded via overwrite-on-collision but the bit array is not. Either:
  - (a) Add a periodic reset (simplest fix), or
  - (b) Re-derive B7 around the actual ghost-tag capacity (256) since that is the *effective* size of the filter, and treat the bit_array as an early-rejection optimization layer.
  Decision deferred; flagged in `justifications/B7_bloom_filter_math.md` and in the strategy doc as a new low-severity weakness.
- **Confidence threshold θ in the code is `THRESHOLD = 35`** (not `16` as the plan's B6 example assumes). Documented in `CLAUDE.md`; B6 doc when written should justify 35 specifically.
- **Paper's +150/+75 bias values do not match code's +40/+20×s** — flagged in B2/B3 stubs; deferred to Phase 2D sweep.
