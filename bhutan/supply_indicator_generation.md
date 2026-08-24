# Care Georeferencing Tool: Bhutan Analysis Plan and Methodology Annex

**Study area:** Thimphu Thromde
**Supply dataset:** `CGT_survey_190826.fgb`, 76 point features, EPSG:4326
**Analysis grid:** 250 m hexagons
**Reporting units:** Local Area Plan (LAP), Thromde
**Care groups:** children, older persons, persons with disability (PWD)

---

## 1. Scope and units

| Layer | Unit | Purpose |
|---|---|---|
| Facility | point | supply inventory, quality, resilience |
| Facility × care group | point × group | capacity attribution, group-specific supply |
| Hexagon | 250 m hex | reachability surfaces, composite indices, scenario modelling |
| Local Area Plan | polygon | reporting, coverage ratios, unmet demand headcounts |
| Thromde | polygon | headline figures |

Two directions of aggregation. Reachability is computed on the hex grid and summarised up to LAP as demand-weighted means. Coverage and unmet demand are computed directly at LAP from summed capacity and summed demand, not averaged from hexes.

Notation used throughout: `j` facility, `i` hexagon, `a` administrative unit, `g` care group, `t_ij` travel time in minutes, `C_j` capacity, `D_i` demand population.

---

## 2. Data preparation rules

These must be settled before any indicator is computed, because every downstream number depends on them.

### 2.1 Coordinate reconciliation

Three coordinate sources exist in the schema:

| Source | Fields |
|---|---|
| Device GPS | `_a_gps_location_latitude`, `_a_gps_location_longitude`, `_a_gps_location_precision` |
| Enumerator-updated | `updated_longitude`, `updated_latitude` |
| Manually entered | `a10_longitude`, `a11_latitude` |

**Rule (in order of precedence):**

1. Use `updated_*` where populated, since it represents a deliberate correction.
2. Otherwise use `_a_gps_location_*` where `_a_gps_location_precision <= 20` m.
3. Otherwise use `a10/a11`.
4. Otherwise flag for follow-up and exclude from reachability computation while retaining in facility counts.

Record the source and precision in `geom_source` and `geom_precision_m`. Any facility with precision worse than 50 m should be flagged, because at 250 m hex resolution a 50 m error can shift a facility across a cell boundary. Cross-check the final point against `a8_local_area_plan` and flag disagreements.

### 2.2 Operating status filter

Filter on `a12_operating_status`. Build three sets:

- **Active set:** operational facilities. Basis for all supply, coverage and reachability indicators.
- **Temporarily closed set:** retained separately using `a13_reopen_date`. Reported as latent capacity, not counted in current supply.
- **Permanently closed set:** excluded from supply but retained for the attrition narrative alongside `a14_year_established`.

Every published figure states which set it uses.

### 2.3 Care group assignment and the capacity problem

`a15_target_group` is multi-select, expanded into `a15_target_group/children`, `/older_persons`, `/pwd`. A facility can therefore serve more than one group, but `d1_total_capacity` is a **single undifferentiated number**. There is no per-group capacity split in the instrument.

This is the most consequential limitation in the dataset and it needs an explicit, documented convention.

**Primary convention (attributable capacity):** for each group `g` that a facility serves, `C_jg = C_j`. This answers "how much capacity is available to this group", which is the correct framing for reachability. It double counts capacity across groups, so group-level capacity totals must never be summed to a facility total.

**Sensitivity convention (partitioned capacity):** `C_jg = C_j / n_j`, where `n_j` is the count of groups served. This preserves additivity at the cost of assuming equal split.

Both are computed. The primary convention drives published reachability and coverage figures. The sensitivity convention is reported in the annex as a robustness check, with the difference between the two stated for any LAP where multi-group facilities exceed 25% of local capacity.

Report `n_multigroup` (count of facilities with more than one group flagged) prominently, since it bounds how much the conventions can diverge.

### 2.4 Capacity construction

| Derived field | Formula | Source fields |
|---|---|---|
| `capacity_day` | `d1_total_capacity` | `d1_total_capacity` |
| `capacity_residential` | `d5_residential_beds` | `d5_residential_beds` |
| `enrolment_day` | `d2_current_enrolment` | `d2_current_enrolment` |
| `occupancy_residential` | `d6_residential_occupancy` | `d6_residential_occupancy` |
| `capacity_total` | `capacity_day + capacity_residential` | as above |
| `spare_capacity` | `max(0, capacity_total − enrolment_day − occupancy_residential)` | as above |
| `utilisation` | `(enrolment_day + occupancy_residential) / capacity_total` | as above |

Day and residential capacity are kept separate throughout, because they answer different questions. Residential beds do not relieve daily care burden on a household in the same way, and they are not subject to the same travel-time logic (a resident does not commute). Reachability indicators use `capacity_day` only. Residential capacity is reported as a distinct supply stratum.

Where `capacity_total` is null but `enrolment_day` is populated, impute `capacity_total = enrolment_day` and set `capacity_imputed = TRUE`. Where both are null, the facility contributes to counts but not to capacity-weighted indicators, and this must be stated as a coverage figure ("capacity known for X of 76 facilities").

**Utilisation above 1.0 is expected and is signal, not error.** Flag as `oversubscribed = TRUE` rather than clipping.

### 2.5 Effective capacity (opening-hours adjustment)

A half-day facility does not release a carer into paid work. Section D8 supports a full-day equivalence adjustment.

For each weekday `d` in Monday to Friday where `d8_operating_days/{d} = 1`:

```
hours_d = d8_{d}_close − d8_{d}_open
```

Then:

```
mean_weekday_hours = mean(hours_d over open weekdays)
w_hours = min(1, mean_weekday_hours / 8)
w_days  = (count of open weekdays) / 5
C*_j    = capacity_day × w_hours × w_days
```

Facilities with `d7_24hr_care = TRUE` take `w_hours = 1`.

`C*_j` is labelled **full-day equivalent capacity**. Both `C_j` and `C*_j` are carried forward. The gap between coverage computed on each is itself a headline finding, since it quantifies how much nominal supply is not usable by a full-time working carer. Weekend availability is reported separately rather than folded into the weight, because it serves a different need (shift work, informal sector).

Parsing note: `d8_*_open` and `d8_*_close` are strings. Normalise to 24-hour decimal, handle any facility where close precedes open by flagging rather than assuming an overnight shift, and record parse failures explicitly.

### 2.6 Age band eligibility

`d3_age_childcare/age_0` through `/age_5` are **eligibility flags, not enrolment counts**. They indicate which single-year ages a facility accepts. Same for `d3_age_disability/*` (age brackets served) and `d4_disability_types/*` (impairment types served).

Two derived fields:

```
age_band_breadth   = count of d3_age_childcare/age_* flags set
serves_under_3     = TRUE if any of age_0, age_1, age_2 set
```

`serves_under_3` matters disproportionately. Under-3 provision is the binding constraint on maternal labour force participation in almost every context, and it is typically the scarcest. Coverage for the 0 to 2 cohort should be computed against only those facilities where `serves_under_3 = TRUE`, otherwise the figure is inflated by preschool places a two-year-old cannot take.

`d3_age_oldage` is typed Real and appears to be a minimum age threshold rather than a flag set. Confirm its coding with the consulting firm before using it as an eligibility filter.

### 2.7 Demand surface

From the dasymetric surface (DHS building footprints and residential unit counts, weighted against NSB Enumeration Area microdata), summed to hex:

| Cohort | Definition | Used for |
|---|---|---|
| `pop_0_2` | children under 3 | childcare, under-3 constraint |
| `pop_3_5` | children 3 to 5 | childcare, preschool |
| `pop_0_5` | children under 6 | childcare headline |
| `pop_65p` | 65 and over | older persons |
| `pop_80p` | 80 and over | older persons, high-dependency |
| `pop_pwd` | persons with disability | **held pending prevalence validation** |
| `fem_15_64` | women of working age | carer denominator |
| `pop_total` | all persons | density normalisation |

The PWD cohort is specified here but not published until the prevalence definition underlying the national consultant's 2017-rates-carried-forward layer is confirmed. All PWD indicators are built and run, then withheld from release. Every table has the column; the value is null until validation clears.

### 2.8 Consistency checks to run before analysis

| Check | Fields | Action on failure |
|---|---|---|
| Staff totals agree | `d10_total_staff` vs `f4_staff_total` vs `f9_staff_total` | flag, use `d10_total_staff` as canonical, report disagreement rate |
| Trained staff not exceeding total | `d9_trained_staff <= d10_total_staff` | flag |
| Sex disaggregation sums | `f4_staff_female + f4_staff_male + f4_staff_others = f4_staff_total` | flag |
| Enrolment plausibility | `d2_current_enrolment` vs `d1_total_capacity` | flag oversubscription, do not clip |
| Admin agreement | point-in-polygon LAP vs `a8_local_area_plan` | flag, resolve manually |
| Duplicate detection | `a1_facility_name`, `a5_registration_number`, proximity under 50 m | manual review |
| Registration coverage | `a5_registration_number` null rate | reported as informal or unregistered provider share |
| Collection method | `h4_collection_method` | stratify quality checks; desk-collected records get a lower confidence flag |
| Validation status | `_validation_status`, `_status` | exclude non-approved submissions or state their inclusion |

`a5_registration_number` null rate is worth surfacing as a finding in its own right. Unregistered providers are outside inspection and safeguarding regimes, and their share is a governance indicator.

---

## 3. Indicator specifications

### Tier 1: supply and demand balance

No routing required. Computed at LAP and Thromde.

---

**I-01 Coverage ratio**

Places per 100 people in the care cohort.

```
Cov(a,g) = 100 × Σ_{j ∈ a, g} C_jg / P_ag
```

| | |
|---|---|
| Inputs | `d1_total_capacity`, `a15_target_group/*`, LAP polygon, demand cohort |
| Output | `cov_pct` per LAP × group |
| Variants | `cov_pct_fde` using `C*_j`; `cov_pct_under3` restricted to `serves_under_3` facilities and `pop_0_2` |
| Caveat | capacity attribution convention applies (2.3) |

---

**I-02 Unmet demand headcount**

```
UD(a,g) = max(0, P_ag − Σ_{j ∈ a, g} C_jg)
```

Absolute persons, not a rate. This is the figure that appears in the executive summary, because "N children without a place" moves budget lines in a way that a ratio does not.

Also compute `UD_fde` on full-day equivalent capacity, and report the difference as **functionally unmet demand**.

| | |
|---|---|
| Inputs | as I-01 |
| Output | `unmet_headcount`, `unmet_headcount_fde` per LAP × group |
| Caveat | assumes all cohort members want a formal place; state as a supply-side gap, not measured demand |

---

**I-03 Utilisation and saturation**

```
Util(a,g)     = Σ enrolment / Σ capacity
Saturation(a) = share of facilities with waitlist_exists OR utilisation ≥ 0.95
```

| | |
|---|---|
| Inputs | `d2_current_enrolment`, `d1_total_capacity`, `d11_waitlist_exists`, `d6_residential_occupancy`, `d5_residential_beds` |
| Output | `utilisation`, `saturation_share`, `oversubscribed_count` |
| Caveat | `d11_waitlist_exists` is Boolean. Waitlist length was not captured, so the intensity of excess demand is unmeasurable from this instrument. Recommend adding waitlist count to the instrument for Malaysia and Sri Lanka. |

---

**I-04 Provision density**

```
Dens_pop(a,g)  = 1000 × N_ag / P_a_total
Dens_area(a,g) = N_ag / area_km2(a)
```

Both are reported. Population-normalised density answers equity; area-normalised density answers spatial thinness and correlates with the reachability tier.

---

**I-05 Sector and affordability profile**

| Sub-indicator | Formula | Fields |
|---|---|---|
| Sector mix | share of facilities and of capacity by operator type | `a4_operator_type`, `d1_total_capacity` |
| Free-at-point share | share of capacity where cost is free or nominal | `c1_cost_to_user`, `d1_total_capacity` |
| Median fee | median `c2_monthly_fee` among fee-charging facilities | `c2_monthly_fee` |
| Fee burden | `c2_monthly_fee` / median household monthly income | `c2_monthly_fee` + external income data |
| Subsidised share | share of capacity with subsidy available | `c3_subsidy_available`, `c4_subsidy_provider` |
| **Affordable capacity** | capacity where free, subsidised, or fee below the 25th percentile | `c1`, `c2`, `c3`, `d1` |

**Affordable capacity is the key derived quantity.** Every reachability indicator should be run twice, once on all capacity and once on affordable capacity only. A facility that is physically reachable but costs a third of household income is not accessible in any meaningful sense, and the divergence between the two surfaces is one of the most policy-relevant maps in the study.

Fee burden requires an external income figure. If LAP-level or Thromde-level income is unavailable from NSB, use a single Thimphu median and state it as a constant.

---

**I-06 Care intensity ratio**

```
CIR(a) = (P_0_5 + P_65p) / fem_15_64
```

Dependants per working-age woman. Computable entirely from the demand surface, no supply data required, so it can be produced immediately and is not blocked by any of the supply-side caveats.

This is the unpaid care burden proxy and it is the most directly gender-relevant indicator in the set. Read alongside I-01, the combination of high CIR and low coverage identifies where unpaid care is absorbing the deficit. Map that intersection explicitly.

Optional refinement using `pop_80p` and a high-dependency weight, since an 80-year-old and a 65-year-old are not equivalent care loads:

```
CIR_weighted(a) = (P_0_2 × 1.5 + P_3_5 × 1.0 + P_65_79 × 0.5 + P_80p × 1.5) / fem_15_64
```

Weights are illustrative and must be documented as assumptions, with a sensitivity run at equal weights.

---

### Tier 2: reachability

Routing via Valhalla. Two profiles: pedestrian with elevation costing, and auto. Thimphu's terrain makes flat-network walking times materially wrong, so elevation costing is not optional here.

The `b3_travel_time` field is a String and is a **respondent-reported perception**. Do not use it as a routing input. It is useful only as a validation comparator against modelled times, and that comparison is worth running as a methods note.

---

**I-07 Travel time to nearest service**

```
T(i,g,m) = min over j ∈ g of t_ij(m)
```

for mode `m` in {walk, drive}.

| | |
|---|---|
| Inputs | hex centroids, facility points, road network, DEM |
| Output | `tt_walk_min`, `tt_drive_min` per hex × group |
| Variants | restricted to affordable capacity; restricted to `serves_under_3`; restricted to facilities with spare capacity |
| Caveat | hex centroid as origin; state the approximation |

The **spare-capacity variant** is important and is often skipped. Nearest-service time to a facility that is full overstates real reachability considerably.

---

**I-08 Catchment coverage**

Share of cohort population within threshold:

```
Cover(a,g,τ,m) = Σ_{i ∈ a, T(i,g,m) ≤ τ} D_ig / Σ_{i ∈ a} D_ig
```

Thresholds: 15, 30, 45 minutes walking; 15, 30 minutes driving.

Reported as a coverage curve (share covered against threshold) rather than a single number, since threshold choice is otherwise an undefended judgement call embedded in the headline.

---

**I-09 Enhanced two-step floating catchment area (E2SFCA)**

The methodological centrepiece. Combines capacity, competition between users, and distance decay into one comparable score.

**Step 1**, supply-to-demand ratio at each facility:

```
R_j = C_jg / Σ_{i : t_ij ≤ t_max} D_ig · W(t_ij)
```

**Step 2**, accessibility score at each hex:

```
A_ig = Σ_{j : t_ij ≤ t_max} R_j · W(t_ij)
```

**Decay function.** Gaussian, continuous rather than stepped, because with 76 facilities a stepped function produces visible artefacts at zone boundaries:

```
W(t) = exp(−t² / (2σ²))
```

Parameters: `t_max = 45` min walk, `σ = 15`; `t_max = 30` min drive, `σ = 10`. Both are run and reported. Sensitivity at `σ ± 5` min is included in the annex.

**Interpretation.** `A_ig` has units of places per person and is comparable across space but not across care groups (different capacity attribution) or across countries (different decay parameters). Normalise to a 0 to 100 index against the Thimphu maximum for mapping, retaining the raw value in the data.

| | |
|---|---|
| Inputs | `C_jg` or `C*_jg`, demand surface, travel time matrix |
| Output | `e2sfca_raw`, `e2sfca_index` per hex × group × mode |
| Variants | on `C*` (full-day equivalent), on affordable capacity, on spare capacity |
| Caveat | with N=76 across three groups, per-group facility counts are small. Report `n_facilities` per group alongside every score, and treat the PWD surface as indicative pending both the prevalence validation and the facility count. |

---

**I-10 Choice index**

```
Choice(i,g,τ) = count of j ∈ g with t_ij ≤ τ
```

One reachable facility is coverage but not choice. A parent with a single option has no recourse against cost, quality or a safeguarding concern.

**Expect this to be degenerate.** With 76 facilities across a Thromde and three care groups, most hexes will return 0, 1 or 2. That is itself the finding, and it should be reported as a categorical map (none, single provider, some choice) rather than as a continuous surface implying more precision than exists.

---

**I-11 Journey burden**

Annual household travel time spent on care access:

```
JB(a,g) = Σ_{i ∈ a} D_ig × T(i,g,walk) × 2 × trips_per_year / 60
```

with `trips_per_year = 250` for childcare (daily attendance, round trip), lower and documented for other groups.

Output in person-hours per year at LAP and Thromde. Converts a travel-time map into an economic quantity, and can be monetised against median wage if the study wants a cost-of-inaction figure. State clearly that this is modelled, not observed, and that it assumes attendance at the nearest facility.

---

### Tier 3: quality, safeguarding and inclusion

Section F of the instrument supports a quality dimension. This changes the study from a pure access assessment to an access-and-adequacy assessment, which is a considerably stronger contribution.

---

**I-12 Safeguarding compliance index**

Mean of seven binary components, scored 0 to 1 and reported as a percentage:

| Component | Field | Scoring |
|---|---|---|
| Written safeguarding policy | `f1_safeguarding_policy` | 1 if present |
| Grievance mechanism | `f2_grievance_mechanism/*` | 1 if any mechanism other than `none` |
| Users informed of mechanism | `f3_users_informed` | 1 if yes |
| Staff trained in safeguarding | `f4_staff_trained_safeguarding` | 1 if yes |
| Background checks | `f6_background_checks` | 1 if conducted |
| Incident reporting system | `f7_incident_reporting` | 1 if present |
| Emergency plan | `f8_emergency_plan` | 1 if present |

```
SCI_j = 100 × (Σ components) / 7
```

Report the index, the component-wise compliance rates (more actionable than the composite), and the capacity-weighted index (share of *places*, not facilities, meeting each standard). Capacity weighting matters because a large non-compliant facility is a bigger problem than a small one.

Cross-tabulate against `a4_operator_type` and against `a5_registration_number` presence. The likely finding is a compliance gradient by sector and registration status, which points directly at a regulatory recommendation.

Sub-indicators worth reporting separately:

```
staff_safeguard_trained_share = f4_staff_total / d10_total_staff
firstaid_trained_share        = f9_staff_total / d10_total_staff
inspection_recency_months     = months since f10_last_inspection_date
never_inspected_share         = share with f10_last_inspection_date null
```

`f5_training_types/*` gives the training content profile: child protection, elder care protection, disability inclusion, PSEAH, GBV prevention, MHPSS. Report as a coverage matrix by care group served. PSEAH and GBV prevention coverage rates are directly reportable against UNDP safeguarding commitments.

---

**I-13 Care workforce profile**

The care workforce is itself a gender finding and the instrument captures it.

```
staff_per_user      = (d2_current_enrolment + d6_residential_occupancy) / d10_total_staff
trained_staff_share = d9_trained_staff / d10_total_staff
staff_feminisation  = f4_staff_female / f4_staff_total
```

Reported at facility, LAP and Thromde, weighted by capacity. Staff-to-user ratio is a quality proxy and should be benchmarked against Bhutanese licensing standards where those exist, which is worth confirming with the ministry counterpart.

Feminisation rate read against fee levels and sector supports the standard care economy argument about undervalued feminised labour. Note the caveat that `f4_staff_*` counts staff trained in safeguarding, not all staff, so the feminisation denominator is a subset. If `f9_staff_*` (first-aid trained) shows a similar rate, that corroborates. A true all-staff sex disaggregation is not in the instrument and should be added for the next country.

---

**I-14 Disability inclusion index**

Two components, kept separate because they mean different things.

*Physical accessibility* (facility-level, applies to all care groups since older persons also need step-free access):

```
PAI_j = 100 × (b6 + b7 + b8) / 3
```

ramp, accessible toilet, handrails.

*Communication and support accessibility:*

```
CAI_j = 100 × (b9 + b10 + b11 + b12 + e6/sign_language + e6/braille + e6/aac_devices) / 7
```

tactile, visual aids, sign language, transport assistance, and the three communication support modes.

Also: `b5_physical_accessibility` (overall self-assessment) as a comparator against the constructed index, and `e4_inclusive_education` for childcare facilities.

**Critical cross-cut:** compute PAI for facilities serving *children* and *older persons*, not only PWD-serving facilities. A childcare centre inaccessible to a disabled parent, or an elderly day centre without handrails, is an inclusion failure that a PWD-only analysis misses entirely. This cross-cut is likely to be one of the more novel findings.

`d4_disability_types/*` gives impairment-type coverage. Compute per-type provision counts to identify which impairment groups have no dedicated provision at all in Thimphu.

---

**I-15 Service breadth**

```
breadth_oldage     = count of e1_services_oldage/* flags
breadth_disability = count of e1_services_disability/* flags
```

Facilities offering only custodial care differ substantially from those offering therapy, rehabilitation, skills training or livelihood support, and the distinction matters for outcomes.

**Asymmetry note:** the instrument provides service multi-selects for older persons and disability, but only `e1_childcare_note` (free text) for childcare. Childcare service breadth is therefore not comparably measurable. Either code the free text manually (76 records makes this feasible) or state the asymmetry as a limitation. Recommend manual coding, since it is a small job and it restores comparability. Add a childcare service multi-select for the next country.

Supplementary: `e2_meals_provided`, `e3_medical_services`, `e5_caregiver_support`. Caregiver support is worth reporting on its own, since services that support the carer rather than only the cared-for are the ones that most directly reduce unpaid care burden, and they are typically rare.

---

### Tier 4: climate exposure and resilience

The FCDO framing. Bhutan's relevant hazards are flood and landslide.

Section G gives **facility-reported** hazard experience, which sits alongside **modelled** hazard layers. Having both is a methodological asset, not a redundancy.

---

**I-16 Hazard exposure of care capacity**

```
Exposed_capacity(h, rp) = Σ_{j ∈ hazard zone(h, rp)} C_j
Exposed_users(h, rp)    = Σ_{j ∈ hazard zone(h, rp)} (d2 + d6)
```

for hazard `h` in {flood, landslide} at each modelled return period.

| | |
|---|---|
| Inputs | facility points, `d1`, `d2`, `d5`, `d6`, hazard rasters |
| Output | facilities exposed, capacity exposed, users exposed, by hazard and return period |

Report as absolute counts and as a share of Thimphu total. "N children in facilities within the 1-in-100 flood extent" is the headline.

---

**I-17 Reported versus modelled exposure agreement**

```
agreement_rate = share where g1_hazard_types/{h} matches hazard-zone membership
```

Confusion matrix per hazard: reported and modelled, reported not modelled, modelled not reported, neither.

This is a genuine methodological contribution and worth writing up as such. Reported-not-modelled cases identify localised hazard the regional model misses, typically drainage failure and slope instability at a scale below raster resolution. Modelled-not-reported cases indicate either model overreach or facilities unaware of their own risk, and the two are distinguishable using `g3_closed_past12months` and `g2_access_affected_rain`.

`g1_hazard_types/road_blockage` deserves separate treatment. It is an *access* hazard rather than a *facility* hazard, and it feeds directly into I-18.

---

**I-18 Disruption reachability and the resilience gap**

Recompute the reachability surface with hazard-affected road segments removed.

```
T_disrupted(i,g) = min over j reachable on the degraded network
ΔT(i,g)          = T_disrupted − T_baseline
Lost_access(g,τ) = Σ D_ig where T_baseline ≤ τ AND T_disrupted > τ
```

`Lost_access` is the headline climate figure: population that has reachable care today and does not during a hazard event. It is the number that connects the care analysis to climate finance, and it should be computed for each hazard and return period.

Also recompute E2SFCA on the degraded network. The delta surface is the **resilience gap map**.

Facilities that are themselves in the hazard zone are removed from the supply set in the disrupted run, so the analysis captures both mechanisms (facility lost, and route lost) and their combination.

| | |
|---|---|
| Inputs | road network, hazard extents, `g1_hazard_types/road_blockage`, facility points, capacity |
| Output | `tt_disrupted`, `delta_tt`, `e2sfca_disrupted`, `resilience_gap` per hex × group × hazard |
| Caveat | assumes binary segment removal; state that partial degradation and speed reduction are not modelled |

---

**I-19 Facility resilience readiness**

```
RRI_j = 100 × (g4_evacuation_plan + g5_evacuation_drill_tested + g3_no_closure_past12m) / 3
```

Read against I-16. **A facility that is highly exposed and has low readiness is the priority investment case**, and that two-by-two is the single most actionable output of this tier. Produce it as an explicit quadrant chart with facilities named, since with 76 records the list is short enough to act on directly.

`g6_disaster_support_needed/*` gives a self-reported investment shopping list: training, evacuation equipment, emergency supplies, safer infrastructure, road improvement, communication systems, backup power, financial support. Tabulate frequency, cross-tabulate against exposure, and carry into the investment priorities section. This is demand-driven costing straight from the providers and it strengthens the recommendations considerably.

`g3_days_closed` is a String, so treat as categorical bands. Do not compute a mean.

---

### Tier 5: composites

---

**I-20 Care desert classification**

Defined as a multi-criteria rule, not a single threshold. A hex is a care desert for group `g` when **both** conditions hold:

```
Condition A (reachability):  T(i,g,walk) > 30 min  OR  e2sfca_index < 25th percentile
Condition B (adequacy):      LAP coverage ratio < 50 places per 100 cohort
```

Four-class output rather than binary, which is more informative and more defensible:

| Class | Definition |
|---|---|
| Adequate | neither condition |
| Access-constrained | A only, supply exists locally but is not reachable |
| Supply-constrained | B only, reachable but insufficient |
| Care desert | both A and B |

Every threshold is a documented judgement call, and each is subjected to a sensitivity run at ±20%. The classification is produced per care group and for affordable capacity separately. The affordable-capacity desert map will be materially larger than the all-capacity one, and the difference between them is a finding worth stating explicitly.

---

**I-21 Care priority index**

Weighted composite for investment targeting, computed per hex and summarised to LAP.

| Component | Source | Direction | Weight |
|---|---|---|---|
| Unmet demand density | I-02 | higher is more priority | 0.25 |
| Reachability deficit | I-09 inverted | higher is more priority | 0.25 |
| Care intensity ratio | I-06 | higher is more priority | 0.20 |
| Hazard exposure | I-16 / I-18 | higher is more priority | 0.15 |
| Affordability gap | I-05 | higher is more priority | 0.15 |

All components min-max normalised to 0 to 100 across Thimphu before weighting.

```
CPI_i = Σ_k w_k × norm(component_k)
```

Weights are provisional and must be set with the Bhutan core group rather than by the analyst, since they encode a policy preference rather than a technical fact. Build the tool so weights are adjustable and the map re-renders, which also makes this a live workshop exercise rather than a static output. The platform already supports client-side reweighting at 0.6 ms, so this is free.

Report the rank correlation between weighting schemes to show how robust the priority ordering is. If the top five LAPs are stable across schemes, the recommendation is strong regardless of weights, and saying so pre-empts the obvious challenge.

---

### Tier 6: scenario and planning

---

**I-22 Optimal siting**

Greedy maximum coverage over candidate sites.

```
maximise Σ_i D_ig × y_i
subject to  y_i ≤ 1 if any selected site is within τ of i
            Σ x_j ≤ k
```

Candidate sites: existing facilities with expansion room, public land parcels, schools and community centres if a suitable layer exists, and hex centroids as a fallback set. Selection at each step maximises newly covered demand.

Run separately per care group and jointly (a co-located multi-group facility being a real policy option worth quantifying).

---

**I-23 Marginal gain curve**

Population newly covered per additional facility, plotted against `k`.

This answers "how many facilities should we fund", which is the question the city will actually ask. The elbow of the curve is the defensible recommendation. Report both raw newly-covered population and cost per person covered, using the CGT costing assumptions where a per-facility capital and operating figure is available.

---

**I-24 Expand versus build**

Compare, at equal cost:

- adding `n` places to existing facilities with spare physical room
- constructing `m` new facilities at optimal sites

Metric: population moved from underserved to served per unit cost. Expansion typically wins on cost per place but loses on spatial coverage, and quantifying that trade-off is directly useful to the investment case.

---

**I-25 Demand projection**

Project cohorts to 2030 and 2035 using NSB projections, applying growth rates at LAP level where the projections support that disaggregation and at Thromde level otherwise.

Recompute I-01, I-02 and I-20 on projected demand at constant supply. Output: LAPs that are adequate today and become care deserts by 2035 without intervention. That map is the strongest argument for acting now and it costs almost nothing to produce once the pipeline exists.

Bhutan's demographic trajectory (falling fertility, rising old-age share) means the childcare and older-person maps will move in opposite directions, and showing that divergence explicitly is more useful than a single aggregate projection.

---

## 4. Output schemas

### 4.1 `fct_facility`

One row per facility, cleaned and derived.

| Column | Type | Source |
|---|---|---|
| `facility_id` | text | `_uuid` |
| `facility_name` | text | `a1_facility_name` |
| `category`, `type` | text | `a2_facility_category`, `a3_facility_type` |
| `operator_type` | text | `a4_operator_type` |
| `registration_number` | text | `a5_registration_number` |
| `is_registered` | bool | derived |
| `dzongkhag`, `throm`, `lap` | text | `a6`, `a7`, `a8` |
| `lap_spatial` | text | point-in-polygon |
| `lap_mismatch` | bool | derived |
| `geom` | point | reconciled per 2.1 |
| `geom_source`, `geom_precision_m` | text, real | derived |
| `operating_status` | text | `a12_operating_status` |
| `year_established` | int | `a14_year_established` |
| `serves_children`, `serves_older`, `serves_pwd` | bool | `a15_target_group/*` |
| `n_groups` | int | derived |
| `capacity_day`, `capacity_residential`, `capacity_total` | real | `d1`, `d5`, derived |
| `enrolment_day`, `occupancy_residential` | real | `d2`, `d6` |
| `capacity_imputed`, `oversubscribed` | bool | derived |
| `utilisation`, `spare_capacity` | real | derived |
| `capacity_fde` | real | derived per 2.5 |
| `w_hours`, `w_days`, `mean_weekday_hours` | real | derived |
| `open_weekend` | bool | `d8_operating_days/saturday`, `/sunday` |
| `care_24hr` | bool | `d7_24hr_care` |
| `serves_under_3`, `age_band_breadth` | bool, int | `d3_age_childcare/*` |
| `cost_to_user`, `monthly_fee` | text, real | `c1`, `c2` |
| `subsidy_available`, `subsidy_provider` | bool, text | `c3`, `c4` |
| `is_affordable` | bool | derived per I-05 |
| `total_staff`, `trained_staff` | real | `d10`, `d9` |
| `staff_per_user`, `trained_staff_share`, `staff_feminisation` | real | derived |
| `waitlist_exists` | bool | `d11` |
| `sci` | real | I-12 |
| `pai`, `cai` | real | I-14 |
| `breadth_oldage`, `breadth_disability` | int | I-15 |
| `inspection_recency_months`, `never_inspected` | real, bool | `f10` |
| `hazard_flood_reported`, `hazard_landslide_reported`, `hazard_roadblock_reported` | bool | `g1_hazard_types/*` |
| `access_affected_rain` | text | `g2` |
| `closed_past12m` | bool | `g3` |
| `rri` | real | I-19 |
| `in_flood_zone_rpN`, `in_landslide_zone` | bool | spatial join |
| `hazard_agreement_flood`, `hazard_agreement_landslide` | text | I-17 |
| `collection_method`, `enumerator_code`, `collection_date` | text, text, date | `h4`, `h6`, `h2` |
| `qa_flags` | text[] | derived per 2.8 |

### 4.2 `fct_facility_group`

Facility × care group. Resolves the capacity attribution problem explicitly.

| Column | Type |
|---|---|
| `facility_id` | text |
| `care_group` | text |
| `capacity_attributed` | real |
| `capacity_partitioned` | real |
| `capacity_fde_attributed` | real |
| `enrolment_attributed` | real |
| `is_affordable` | bool |
| `has_spare` | bool |

### 4.3 `fct_hex`

Hex × care group. The analysis surface.

| Column | Type |
|---|---|
| `hex_id` | text |
| `care_group` | text |
| `demand_pop` | real |
| `tt_walk_min`, `tt_drive_min` | real |
| `tt_walk_affordable`, `tt_walk_spare` | real |
| `e2sfca_raw`, `e2sfca_index` | real |
| `e2sfca_fde`, `e2sfca_affordable` | real |
| `choice_15`, `choice_30`, `choice_45` | int |
| `choice_class` | text |
| `covered_15`, `covered_30`, `covered_45` | bool |
| `tt_disrupted_flood`, `tt_disrupted_landslide` | real |
| `delta_tt_flood`, `delta_tt_landslide` | real |
| `resilience_gap` | real |
| `desert_class` | text |
| `cpi` | real |
| `cpi_components` | jsonb |

Sizing: at 250 m over Thimphu Thromde this is a fraction of the 155k benchmark, so payload is a non-issue.

### 4.4 `fct_admin`

LAP and Thromde × care group.

| Column | Type |
|---|---|
| `admin_id`, `admin_level` | text |
| `care_group` | text |
| `demand_pop`, `demand_pop_2030`, `demand_pop_2035` | real |
| `n_facilities`, `n_multigroup` | int |
| `capacity_total`, `capacity_fde`, `capacity_affordable` | real |
| `cov_pct`, `cov_pct_fde`, `cov_pct_under3`, `cov_pct_affordable` | real |
| `unmet_headcount`, `unmet_headcount_fde` | real |
| `unmet_headcount_2035` | real |
| `utilisation`, `saturation_share` | real |
| `dens_pop`, `dens_area` | real |
| `sector_mix` | jsonb |
| `median_fee`, `free_share`, `subsidised_share` | real |
| `cir`, `cir_weighted` | real |
| `cover_15`, `cover_30`, `cover_45` | real |
| `e2sfca_mean` | real |
| `journey_burden_hours` | real |
| `sci_mean`, `sci_capacity_weighted` | real |
| `pai_mean`, `cai_mean` | real |
| `staff_per_user`, `staff_feminisation` | real |
| `exposed_facilities`, `exposed_capacity`, `exposed_users` | real |
| `lost_access_pop` | real |
| `desert_share` | real |
| `cpi` | real |

### 4.5 `fct_scenario_site`

| Column | Type |
|---|---|
| `scenario_id`, `care_group` | text |
| `rank` | int |
| `site_hex_id` | text |
| `newly_covered_pop` | real |
| `cumulative_covered_pop` | real |
| `cumulative_covered_share` | real |
| `est_cost` | real |
| `cost_per_person_covered` | real |

---

## 5. Sequencing

| Stage | Contents | Blocked by |
|---|---|---|
| 0 | Data preparation, QA, coordinate reconciliation, consistency checks | nothing |
| 1 | Demand surface finalisation, I-06 | dasymetric surface sign-off |
| 2 | Facility derivation, Tier 1 and Tier 3 indicators | capacity convention decision |
| 3 | Routing setup, travel-time matrix, Tier 2 | road network QA, Valhalla with DEM |
| 4 | Hazard join, Tier 4 | flood and landslide layers |
| 5 | Tier 5 composites | weights agreed with core group |
| 6 | Tier 6 scenarios | Tier 5 complete |

Tiers 1 and 3 are unblocked by routing and can be produced in parallel with the routing setup. Tier 3 in particular requires no spatial analysis beyond a LAP join, so quality and safeguarding findings can be circulated early while the reachability work continues.

---

## 6. Stated limitations

To carry into the report as written.

1. **Sample size.** 76 facilities in Thimphu Thromde. Per-care-group counts are small, so group-specific reachability surfaces are indicative rather than precise. Facility counts must be reported alongside every group-level figure.
2. **Geographic scope.** Thimphu Thromde only. No findings generalise to rural Bhutan, where the care access picture is likely materially different.
3. **Capacity attribution.** Multi-group facilities report a single undifferentiated capacity. Group-level capacity figures depend on a documented convention and are not additive.
4. **Waitlist intensity.** Captured as Boolean only. Excess demand can be detected but not quantified.
5. **Informal care is out of frame.** Home-based, family and neighbour care carries most of the load and is not in the supply dataset. Every coverage figure is formal-sector coverage only, and this framing must be explicit or the headline understates provision while overstating the formal system's role.
6. **Demand is modelled, not measured.** Cohort presence is not the same as demand for a formal place. Take-up rates are unknown.
7. **Disability cohort.** PWD demand is withheld pending prevalence validation. All PWD indicators are conditional.
8. **Childcare service breadth** is not comparably measured against the other two groups, absent manual coding of the free-text field.
9. **Non-response.** Refusals and non-contacts are not represented in the delivered file. The denominator of the sampling frame is needed from the consulting firm to state facility coverage.
10. **Travel time is modelled** on network geometry with elevation costing. It does not capture road surface condition, seasonal passability, informal paths, or safety, all of which affect real walking behaviour, particularly for women and older persons.
11. **Single time point.** No seasonal variation, which matters in a monsoon context.
