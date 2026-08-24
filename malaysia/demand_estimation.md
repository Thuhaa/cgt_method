# 2026 Population Dataset — Selangor, Kuala Lumpur, Putrajaya

A gridded 2026 population surface (100m, EPSG:4326) for the 245-mukim study area,
with full age-sex structure (18 age bands x male/female), built so that:

- **Totals** at every administrative level (state, district, mukim) match DOSM's own
  official 2026 population figures, not an independent model's guess at them.
- **Age-sex structure** also comes from DOSM's own official figures, not from
  WorldPop's/UN's demographic model.
- **Spatial pattern** — i.e. *where within a mukim* people of a given age and sex
  actually live — comes from WorldPop's gridded product, which is the only source
  available at that resolution.

Each of the three ingredients is used only where it's the most trustworthy source for
that specific thing. That division of labour is the core design decision behind this
dataset, explained below.

## Why not just use a raster product's own 2026 estimate directly?

The earlier phase of this project (see `qa_output/zonal_stats/census_worldpop_ghsl_comparison.csv`
and `outlier_mukims_both.csv`) compared WorldPop and GHSL's 2020 gridded population
estimates against the actual 2020 census at mukim level. Result: aggregate totals were
close (WorldPop +3.6%, GHSL +5.9%), but 30-35 of 221 comparable mukims (13-16%) were
off by more than 3x in either direction — concentrated in very small administrative
slivers and in large non-residential areas (e.g. the KLIA airport mukim, which both
products substantially over-populate). Two independent gridded products agreeing with
each other on *where* they diverge from census (r=0.97 correlation between their
error patterns) confirms this isn't noise in one dataset — it's a real limitation of
gridded population models at the individual small-mukim level, however good they are
in aggregate.

That means: trusting either raster's own 2026 total at face value, mukim by mukim,
would carry the same known error pattern forward into 2026. The fix isn't to pick a
"better" raster — it's to stop asking the raster for *totals* at all, and only ask it
for the one thing it's actually good at: spatial and demographic pattern within an
area whose total is independently known to be correct.

## Method

### 1. Official state-level 2026 age x sex targets (the anchor)

DOSM's "Current Population Estimates, 2026" (released July 2026) — pulled live from
`storage.dosm.gov.my/population/population_state.csv`. This gives exact 2026 totals
**and** an 18-bin age structure (0-4, 5-9, ..., 85+) by sex, for every state,
including Selangor, W.P. Kuala Lumpur and W.P. Putrajaya. Nothing here is estimated;
it's the official published figure.

State totals: Selangor 7,454,200 | W.P. Kuala Lumpur 2,082,300 | W.P. Putrajaya
121,400 (all-ages, both-sexes; the age-sex breakdown of these totals is in
`population_state.csv`).

### 2. District-level 2026 age x sex targets (trend, anchored to the state figure)

DOSM's district-level release (`population_district.csv`) has the same 18-bin age x
sex structure but currently only goes up to 2025 (the district-level release lags the
state-level one by several months each year; as of Aug 2026 the 2026 district figures
aren't out yet). For each district and each of the 36 age-sex cells, the 2020->2025
compound annual growth rate was extrapolated one more year to get a 2026 estimate,
then every district's 36 cells were rescaled (multiplicatively, so shape is preserved)
so they sum exactly to that state's official 2026 figure for that cell. This means
the *trend* (which districts are growing faster) comes from 5 years of real official
data, while the *level* is anchored to the newest official figure — better than
assuming every district grows at the same rate, and better than trusting an
unanchored extrapolation.

`district_2026_agesex_targets.csv`

### 3. Mukim-level 2026 age x sex targets (2020 census shares, anchored to the district figure)

DOSM has never published age-sex-disaggregated population figures below district
level, for any year. The only mukim-level age information available at all is the
2020 census's coarse 3-bin split (0-14 / 15-64 / 65+, no sex breakdown) already in
`Mukim 2020 Census Combined.xlsx`.

Each of DOSM's 18 age bins was mapped to its containing census bin (0-4/5-9/10-14 into
0-14; 15-19 through 60-64 into 15-64; 65-69 through 85+ into 65+). A mukim's 2026
target for a given (sex, age bin) cell = (that mukim's share of its district's 2020
census population in the containing broad bin) x (the district's 2026 target for that
cell). The same population-share weight is used for both sexes within a bin, since no
sex-specific mukim-level data exists to do better than that.

This is a real assumption (a mukim is assumed to have the same *sex ratio* as its
district within each broad age group, and the same age *composition within* a broad
bin as its district) — but it's the best available given what's actually published,
and it's a much narrower assumption than "every mukim in a district grows/ages at the
identical uniform rate," since it still lets mukims differ by their own observed 2020
age structure. By construction, mukim targets sum exactly to district targets sum
exactly to the official state targets — no drift is introduced by this step.

`mukim_2026_agesex_targets.csv`

### 4. Spatial + fine-grained age pattern: WorldPop's native 2026 raster

WorldPop's "Age and Gender Structures (2015-2030)" product for Malaysia (R2025A v1,
100m, EPSG:4326, UN World Population Prospects-calibrated), downloaded from
`data.worldpop.org` via the HDX catalogue entry
`worldpop-age-and-gender-structures-2015-2030-mys`. 63 rasters: 1 grand total + 20 age
bands (00, 01, 05, 10, ..., 90) x {male, female, both} + 2 sex-only totals (T_F, T_M).
Clipped to the study area, kept at native resolution/CRS (no resampling) —
see `data/selangor/worldpop_agesex_2026/clipped_4326/`.

WorldPop's 20 age bands collapse cleanly onto DOSM's 18: WorldPop's 00 (age 0-1) + 01
(age 1-4) sum to DOSM's "0-4"; WorldPop's 85 + 90 sum to DOSM's "85+"; every other
band maps 1:1 (05->5-9, 10->10-14, ..., 80->80-84).

### 5. Rescaling: correction factors, not a redrawn map

For each of the 36 (sex x DOSM age bin) cells, a per-mukim correction factor was
computed as (mukim's official 2026 target from step 3) / (WorldPop's own native 2026
zonal sum for the matching band(s) in that mukim, measured with `exactextract`). Each
of the 36 factor surfaces was rasterized onto the population grid (`gdal_rasterize`)
and multiplied into the corresponding WorldPop band(s) with `gdal_calc.py`. This
leaves WorldPop's *relative* spatial pattern inside each mukim completely untouched —
only the *level* is corrected, cell by cell, mukim by mukim, to match DOSM.

Two of the 36 cells (0-4, 85+) map to two WorldPop bands each; the same factor is
applied to both constituent bands, which preserves WorldPop's own internal split
(e.g. how much of the 0-4 group is under 1 vs 1-4) while still hitting the combined
DOSM-anchored target exactly.

Rasterizing a polygon-based correction factor at 100m resolution has one known
failure mode: 7 of the 245 mukims are smaller than 4 pixels (one is smaller than a
single pixel), and a plain center-of-pixel rasterization can drop them to zero
coverage entirely. Fixed with a two-pass rasterize: standard center-of-pixel rule
first, falling back to an ALL_TOUCHED rasterization only where the standard pass left
a pixel unassigned — guarantees every mukim gets at least some pixels without
over-claiming boundary pixels elsewhere.

### 6. A second correction pass (iterative proportional fitting)

Rasterizing 36 independent correction-factor surfaces at 100m resolution introduces
small boundary-pixel leakage between adjacent tiny mukims (a pixel that geometrically
straddles two small polygons can only carry one factor value). Re-measuring the
achieved zonal sum after pass 1, computing a second factor = target / pass-1-achieved,
and applying it the same way (same rasterize-with-fallback + multiply) is standard
IPF-style convergence and substantially tightens the reconciliation (see Validation).
A third pass would tighten it further with diminishing returns; two passes was judged
sufficient.

### 7. Deriving the combined bands

The 20 "both sexes" bands (`mys_t_XX`) and the two sex-only totals (`mys_T_F`,
`mys_T_M`) and the grand total (`mys_pop_2026`) are **derived by summing the rescaled
male/female bands**, not independently rescaled. This guarantees female+male=both and
the grand total are exactly self-consistent by construction, rather than only
approximately consistent.

## Validation

**Age-sex structure matches DOSM almost exactly** — the core goal. Comparing this
dataset's total-across-all-245-mukims for each of the 18 age bins (both sexes)
against DOSM's own official 2026 target for that same bin: every single one matches
within **0.0-0.1%**. See `qa_output/zonal_stats/pop2026_agesex_vs_dosm_official_check.csv`.

Aggregate total reconciliation (245 mukims, measured with `exactextract`):
- Pass 1: target 9,657,900 vs achieved 9,652,482 (-0.056%)
- **Pass 2 (final): target 9,657,900 vs achieved 9,659,589 (+0.017%)**

Per-mukim precision (221 mukims with a usable 2020 census baseline; the other 24 have
no reliable 2020 figure to build a target from, see `Mukim 2020 Census Combined.xlsx`
-> `Consistency_Check_Summary` / `Source_Verification` sheets):
- Pass 1: 85/221 (38%) within 1% of target, 179/221 (81%) within 5%
- **Pass 2 (final): 124/221 (56%) within 1% of target, 206/221 (93%) within 5%**

This per-mukim precision is a little noisier than an earlier, simpler version of this
pipeline that applied one uniform total-population factor per mukim across all age
bands (that version reached 201/221 within 1%) — expected, since this method runs 36
independent factor-rasterization operations instead of 1, each with its own small
boundary leakage that doesn't fully cancel when the bands are summed back up. That
simpler version was discarded specifically because it silently inherited WorldPop's
own age-sex structure instead of DOSM's, which was the actual problem being solved
here; the age-structure accuracy this method achieves was judged more important than
the small loss of per-mukim total precision.

Residual per-mukim error after pass 2 is concentrated in the same handful of very
small (<3km2, some only a few hectares) administrative slivers identified throughout
this project's earlier census-vs-raster QA work (Pekan Batu, Pekan Batu 23 Sungai
Lalang, Pekan Sungai Buloh, Bandar Balakong, etc.) — a structural limit of
rasterizing a correction factor for a polygon near or below the size of a handful of
100m pixels, not specific to this raster, this method, or this age-sex refinement.

Final age-sex totals for the whole study area: **9,661,656** (Female 4,497,789 / Male
5,163,868). Full breakdown in `qa_output/zonal_stats/pop2026_agesex_dosm_aware_pivot.csv`.

## Files

```
data/selangor/pop2026/
  README_2026_population_dataset.md      this file
  population_state.csv                   DOSM source: state x age x sex, 1970-2026
  population_district.csv                DOSM source: district x age x sex, 2020-2025
  district_2026_targets.csv              step 2 output (totals only)
  district_2026_agesex_targets.csv       step 2 output (18 bins x 2 sexes)
  mukim_2026_targets.csv                 step 3 output (totals only)
  mukim_2026_agesex_targets.csv          step 3 output (18 bins x 2 sexes)
  agesex_colname_mapping.csv             (sex, DOSM age bin) <-> factor column name lookup
  mukim_agesex_factors.csv               step 5 pass-1 correction factors, one row per
                                          (mukim x sex x age bin), for audit/reproducibility
  admin_units_agesex_factors_pass2.fgb   admin units + all 36 pass-2 correction factors
                                          as attribute columns (openable in QGIS to see
                                          factor magnitude by mukim)
  agesex_2026_dosm_rescaled_pass2/       *** the deliverable ***: 63 rasters, 100m,
                                          EPSG:4326, totals + age-sex structure both
                                          reconciled to official DOSM 2026 figures

data/selangor/worldpop_agesex_2026/
  clipped_4326/                          raw WorldPop 2026 age-sex bands, clipped to
                                          the study area, untouched/unscaled (the
                                          direct input to step 5)

qa_output/zonal_stats/
  pop2026_agesex_dosm_aware_pivot.csv          final age-sex summary table
  pop2026_agesex_vs_dosm_official_check.csv    the age-structure validation check
  pop2026_dosm_agesex_pass2_zonal_check.csv    per-mukim total reconciliation, pass 2
  worldpop_native2026_sum.csv                  WorldPop's own unadjusted 2026 zonal
                                                sums, for reference/comparison
```

Earlier intermediate artifacts (pass-1-only rasters, the 36 per-cell factor-raster
grids used to build the final output, a discarded GHSL-ensemble experiment, and a
discarded simpler "one uniform factor per mukim" version) were removed after
producing and validating the final pass-2 output. Everything needed to regenerate
them exactly is documented above and in the raw target/factor CSVs that were kept.

## Known limitations

- Mukim-level age-sex disaggregation (step 3) assumes each mukim shares its
  district's sex ratio within each broad age group, and its district's fine age
  composition within a broad bin — a reasonable assumption given what's published,
  but not independently verified locally, since no finer official data exists.
- District-level 2026 figures (step 2) are DOSM's own trend extrapolated one year
  past their latest published (2025) figure, not an official 2026 district release
  (which doesn't exist yet as of this writing). State-level 2026 figures are exact/
  official; mukim and district figures inherit that anchor but aren't independently
  official at their own level.
- Delivered in native EPSG:4326 (WorldPop's own CRS), not reprojected to GDM2000 or
  any other CRS — this differs from the earlier census-vs-raster comparison work in
  this project, which used EPSG:3375 (GDM2000 / Peninsula RSO) throughout.
- 24 of 245 mukims have no reliable 2020 census baseline (see
  `Mukim 2020 Census Combined.xlsx` -> `Source_Verification`) and so have no 2026
  target of their own; their 2020 population is understood to already be folded into
  a neighbouring mukim's census figure, so assigning them population here would
  double-count. Their pixels are zeroed out in the final output rather than
  estimated.
