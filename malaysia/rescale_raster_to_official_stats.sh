#!/usr/bin/env bash
#
# Full reproduction of "the spatial distribution layer that matches DOSM
# totals": data/pop2026/agesex_2026_dosm_rescaled_pass2/ (63 rasters, 100m,
# EPSG:4326), rebuilding every intermediate from README_2026_population_
# dataset.md's Method steps 1-7, not just the final rasterize/multiply stage.
#
# WHAT GETS RASTERIZED, IN ONE SENTENCE: not population — a per-mukim
# correction FACTOR (target population / WorldPop's own population sum for
# that mukim, one ratio per (sex x age-bin) cell). gdal_rasterize paints that
# scalar across every 100m pixel inside the mukim's polygon; gdal_calc then
# multiplies that factor grid, pixel by pixel, into WorldPop's raw population
# raster. WorldPop supplies *where* people are within a mukim; the rasterized
# factor only corrects the *level* to match DOSM, uniformly within each
# polygon. Two factor rasterizations are combined per cell (standard
# center-of-pixel + ALL_TOUCHED fallback) because 7/245 mukims are smaller
# than 4 pixels and can otherwise be rasterized to zero coverage.
#
# TWO KINDS OF INPUT:
#  (a) Mechanically rebuilt here: DOSM's population_state.csv /
#      population_district.csv (re-downloaded), district/mukim age-sex
#      targets, WorldPop's raw zonal sums, both passes' correction factors,
#      both passes' rasters.
#  (b) Treated as FIXED, not rebuilt: data/Mukim 2020 Census Combined.xlsx
#      (the 2020 census baseline) and data/admin_units/selangor_put_kl.fgb
#      (mukim polygons). Both were built through a separate, manually
#      judgment-heavy QA pass earlier in the project (reconciling mismatched
#      mukim codes across DOSM source tables, cross-checking against a PDF,
#      excluding one confirmed data-error mukim (SGR100771 / Pekan Peretak),
#      and identifying 24 mukims with no reliable 2020 baseline — see that
#      file's Source_Verification / Consistency_Check_Summary sheets). That
#      judgment isn't mechanically re-derivable, so this script requires
#      those two files to already exist rather than regenerating them.
#
# Usage:
#   ./reproduce_pop2026_agesex_dosm_rescaled_pass2.sh
#   ./reproduce_pop2026_agesex_dosm_rescaled_pass2.sh --refresh-dosm   # force
#       re-download of population_state.csv/population_district.csv even if
#       already present (these are LIVE endpoints -- default behaviour keeps
#       whatever snapshot is already on disk so re-runs stay reproducible;
#       pass this flag only if you deliberately want today's DOSM figures)
#
# Run from the project root (the directory containing data/, qa_output/).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

REFRESH_DOSM=0
[[ "${1:-}" == "--refresh-dosm" ]] && REFRESH_DOSM=1

POP="data/pop2026"
PROCESSED="data/processed"
RAW="data/worldpop_agesex_2026/clipped_4326"
QA="qa_output/zonal_stats"
CENSUS_XLSX="data/Mukim 2020 Census Combined.xlsx"
ADMIN_SRC="data/admin_units/selangor_put_kl.fgb"
ADMIN="$PROCESSED/admin_units_wgs84.fgb"

TE="100.7858322 2.5733337 101.9899989 3.8908337"   # matches WorldPop's clipped_4326 grid exactly
TR="0.00083333333 0.00083333333"                    # WorldPop's native ~100m pixel size
WP_AGES=(00 01 05 10 15 20 25 30 35 40 45 50 55 60 65 70 75 80 85 90)
NODATA=-99999
STATES_PY="['Selangor', 'W.P. Kuala Lumpur', 'W.P. Putrajaya']"

for f in "$CENSUS_XLSX" "$ADMIN_SRC"; do
  [[ -f "$f" ]] || { echo "Missing fixed input (see header comment): $f" >&2; exit 1; }
done
for tool in gdal_rasterize gdal_calc.py exactextract ogrinfo ogr2ogr gdalinfo curl python3; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done
python3 -c "import geopandas, rasterio, pandas, openpyxl" 2>/dev/null || {
  echo "Missing python deps: geopandas, rasterio, pandas, openpyxl" >&2; exit 1
}

mkdir -p "$POP" "$PROCESSED" "$QA"

# ---------------------------------------------------------------------------
# STAGE 0a — admin unit boundaries: make-valid + WGS84 (skip if built already)
# ---------------------------------------------------------------------------
if [[ ! -f "$ADMIN" ]]; then
  echo "=== Stage 0a: building $ADMIN ==="
  ogr2ogr -f FlatGeobuf -makevalid "$ADMIN" "$ADMIN_SRC" -nlt PROMOTE_TO_MULTI
else
  echo "=== Stage 0a: $ADMIN already present, skipping ==="
fi

# ---------------------------------------------------------------------------
# STAGE 0b — DOSM "Current Population Estimates" source tables
#            (skip by default: these are LIVE endpoints, re-downloading
#            silently changes the target numbers to whatever DOSM has
#            published as of today; use --refresh-dosm to force it)
# ---------------------------------------------------------------------------
STATE_CSV="$POP/population_state.csv"
DISTRICT_CSV="$POP/population_district.csv"
if [[ ! -f "$STATE_CSV" || $REFRESH_DOSM -eq 1 ]]; then
  echo "=== Stage 0b: downloading population_state.csv ==="
  curl -sL -o "$STATE_CSV" "https://storage.dosm.gov.my/population/population_state.csv" --max-time 60
else
  echo "=== Stage 0b: $STATE_CSV already present, skipping (use --refresh-dosm to force) ==="
fi
if [[ ! -f "$DISTRICT_CSV" || $REFRESH_DOSM -eq 1 ]]; then
  echo "=== Stage 0b: downloading population_district.csv ==="
  curl -sL -o "$DISTRICT_CSV" "https://storage.dosm.gov.my/population/population_district.csv" --max-time 60
else
  echo "=== Stage 0b: $DISTRICT_CSV already present, skipping (use --refresh-dosm to force) ==="
fi

# ---------------------------------------------------------------------------
# STAGE 0c — raw WorldPop 2026 age-sex rasters, clipped to the study area
#            (skip if already present: the source .zip is ~1.6GB and this
#            server has repeatedly proven unreliable for curl/aria2c range
#            requests in the past -- if this fails, download it by hand from
#            https://hub.worldpop.org/geodata/summary?id=...
#            (HDX entry: worldpop-age-and-gender-structures-2015-2030-mys,
#            or data.worldpop.org path below) and place the 63 unzipped
#            .tif files under a WPSRC directory before re-running)
# ---------------------------------------------------------------------------
if [[ ! -d "$RAW" || $(ls "$RAW"/*.tif 2>/dev/null | wc -l) -ne 63 ]]; then
  echo "=== Stage 0c: fetching + clipping raw WorldPop 2026 age-sex bands ==="
  WPZIP="data/worldpop_agesex_2026/mys_agesex_structures_2026_CN_100m_R2025A_v1.zip"
  WPSRC="data/worldpop_agesex_2026/raw"
  mkdir -p "$RAW" "$WPSRC"
  if [[ $(ls "$WPSRC"/*.tif 2>/dev/null | wc -l) -ne 63 ]]; then
    echo "Downloading ~1.6GB from WorldPop (may be slow/unreliable, see comment above)..."
    curl -L -o "$WPZIP" \
      "https://data.worldpop.org/GIS/AgeSex_structures/Global_2015_2030/R2025A/2026/MYS/v1/100m/mys_agesex_structures_2026_CN_100m_R2025A_v1.zip" \
      --max-time 1800 --progress-bar
    unzip -o -q "$WPZIP" -d "$WPSRC"
  fi
  for f in "$WPSRC"/*.tif; do
    gdal_translate -projwin 100.786553 3.890074 101.989280 2.573637 \
      -co COMPRESS=LZW -co PREDICTOR=2 -co TILED=YES \
      "$f" "$RAW/$(basename "$f")" >/dev/null
  done
  echo "Clipped $(ls "$RAW"/*.tif | wc -l) files"
else
  echo "=== Stage 0c: raw clipped WorldPop bands already present ($RAW), skipping ==="
fi

# ---------------------------------------------------------------------------
# STAGE 1 — district-level 2026 targets: 2020->2025 CAGR extrapolated one
#           more year, rescaled to sum exactly to DOSM's official state 2026
#           figure (both totals-only and full 18-bin x 2-sex versions)
# ---------------------------------------------------------------------------
DISTRICT_TOTAL="$POP/district_2026_targets.csv"
DISTRICT_AGESEX="$POP/district_2026_agesex_targets.csv"
if [[ ! -f "$DISTRICT_TOTAL" ]]; then
  echo "=== Stage 1a: building $DISTRICT_TOTAL ==="
  python3 << EOF
import pandas as pd
pop_district = pd.read_csv("$DISTRICT_CSV")
pop_state = pd.read_csv("$STATE_CSV")
STATES = $STATES_PY

d = pop_district[(pop_district['state'].isin(STATES)) & (pop_district['sex']=='both') &
                  (pop_district['age']=='overall') & (pop_district['ethnicity']=='overall')].copy()
d = d[d['date'].isin(['2020-01-01','2025-01-01'])]
d['population'] = d['population'] * 1000
piv = d.pivot(index=['state','district'], columns='date', values='population').reset_index()
piv.columns = ['state','district','pop_2020','pop_2025']
piv['cagr'] = (piv['pop_2025'] / piv['pop_2020'])**(1/5) - 1
piv['pop_2026_district_raw'] = piv['pop_2025'] * (1 + piv['cagr'])

s = pop_state[(pop_state['state'].isin(STATES)) & (pop_state['sex']=='both') &
              (pop_state['age']=='overall') & (pop_state['ethnicity']=='overall') &
              (pop_state['date']=='2026-01-01')].copy()
s['population'] = s['population'] * 1000
s = s[['state','population']].rename(columns={'population':'pop_2026_state_official'})

piv = piv.merge(s, on='state')
state_sum_raw = piv.groupby('state')['pop_2026_district_raw'].transform('sum')
piv['pop_2026_district'] = piv['pop_2026_district_raw'] * piv['pop_2026_state_official'] / state_sum_raw
piv.to_csv("$DISTRICT_TOTAL", index=False)
print(f"Saved {len(piv)} district rows; total = {piv['pop_2026_district'].sum():,.1f}")
EOF
else
  echo "=== Stage 1a: $DISTRICT_TOTAL already present, skipping ==="
fi

if [[ ! -f "$DISTRICT_AGESEX" ]]; then
  echo "=== Stage 1b: building $DISTRICT_AGESEX ==="
  python3 << EOF
import pandas as pd
pop_district = pd.read_csv("$DISTRICT_CSV")
pop_state = pd.read_csv("$STATE_CSV")
STATES = $STATES_PY
AGE_BINS = ['0-4','5-9','10-14','15-19','20-24','25-29','30-34','35-39','40-44','45-49',
            '50-54','55-59','60-64','65-69','70-74','75-79','80-84','85+']

d = pop_district[(pop_district['state'].isin(STATES)) & (pop_district['sex'].isin(['male','female'])) &
                  (pop_district['age'].isin(AGE_BINS)) & (pop_district['ethnicity']=='overall')].copy()
d = d[d['date'].isin(['2020-01-01','2025-01-01'])]
d['population'] = d['population'] * 1000
piv = d.pivot_table(index=['state','district','sex','age'], columns='date', values='population').reset_index()
piv.columns = ['state','district','sex','age','pop_2020','pop_2025']
piv['pop_2020'] = piv['pop_2020'].clip(lower=0.01)
piv['cagr'] = (piv['pop_2025'] / piv['pop_2020'])**(1/5) - 1
piv['pop_2026_raw'] = piv['pop_2025'] * (1 + piv['cagr'])

s = pop_state[(pop_state['state'].isin(STATES)) & (pop_state['sex'].isin(['male','female'])) &
              (pop_state['age'].isin(AGE_BINS)) & (pop_state['ethnicity']=='overall') &
              (pop_state['date']=='2026-01-01')].copy()
s['population'] = s['population'] * 1000
s = s[['state','sex','age','population']].rename(columns={'population':'pop_2026_state_official'})

piv = piv.merge(s, on=['state','sex','age'], how='left')
grp_sum = piv.groupby(['state','sex','age'])['pop_2026_raw'].transform('sum')
piv['pop_2026_district'] = piv['pop_2026_raw'] * piv['pop_2026_state_official'] / grp_sum
piv.to_csv("$DISTRICT_AGESEX", index=False)
print(f"Saved {len(piv)} rows; total = {piv['pop_2026_district'].sum():,.1f}")
EOF
else
  echo "=== Stage 1b: $DISTRICT_AGESEX already present, skipping ==="
fi

# ---------------------------------------------------------------------------
# STAGE 2 — mukim-level 2026 targets: each mukim's share of its district's
#           2020 census population (broad 0-14/15-64/65+ bin for age-sex;
#           whole-mukim share for totals-only), applied to the district
#           target from stage 1
# ---------------------------------------------------------------------------
MUKIM_TOTAL="$POP/mukim_2026_targets.csv"
MUKIM_AGESEX="$POP/mukim_2026_agesex_targets.csv"
if [[ ! -f "$MUKIM_TOTAL" ]]; then
  echo "=== Stage 2a: building $MUKIM_TOTAL ==="
  python3 << EOF
import pandas as pd
census = pd.read_excel("$CENSUS_XLSX", sheet_name='Combined')
district_targets = pd.read_csv("$DISTRICT_TOTAL")

census['district_key_state'] = census['Negeri']
census['district_key_district'] = census['Daerah'].where(census['Negeri']=='Selangor', census['Negeri'])
census.loc[census['Negeri']=='Kuala Lumpur', 'district_key_state'] = 'W.P. Kuala Lumpur'
census.loc[census['Negeri']=='Kuala Lumpur', 'district_key_district'] = 'W.P. Kuala Lumpur'
census.loc[census['Negeri']=='Putrajaya', 'district_key_state'] = 'W.P. Putrajaya'
census.loc[census['Negeri']=='Putrajaya', 'district_key_district'] = 'W.P. Putrajaya'

exclude_mask = census['Mukim Code'].astype(str) == 'SGR100771'  # Pekan Peretak, confirmed data error
usable = census[~exclude_mask & census['Total (2020)'].notna()].copy()

usable['district_census_total'] = usable.groupby(['district_key_state','district_key_district'])['Total (2020)'].transform('sum')
usable['mukim_share_of_district'] = usable['Total (2020)'] / usable['district_census_total']
usable = usable.merge(district_targets[['state','district','pop_2026_district']],
                       left_on=['district_key_state','district_key_district'],
                       right_on=['state','district'], how='left')
usable['pop_2026_mukim_target'] = usable['mukim_share_of_district'] * usable['pop_2026_district']

out = usable[['Mukim','Daerah','Negeri','Mukim Code','Admin Mukim Code','Total (2020)',
              'mukim_share_of_district','pop_2026_mukim_target']]
out.to_csv("$MUKIM_TOTAL", index=False)
print(f"Saved {len(out)} mukim rows; total = {out['pop_2026_mukim_target'].sum():,.1f} (expect 9,657,900)")
EOF
else
  echo "=== Stage 2a: $MUKIM_TOTAL already present, skipping ==="
fi

if [[ ! -f "$MUKIM_AGESEX" ]]; then
  echo "=== Stage 2b: building $MUKIM_AGESEX ==="
  python3 << EOF
import pandas as pd
census = pd.read_excel("$CENSUS_XLSX", sheet_name='Combined')
dtargets = pd.read_csv("$DISTRICT_AGESEX")

def broad_bin(age):
    if age in ['0-4','5-9','10-14']:
        return '0-14 (2020)'
    elif age == '85+' or age.startswith(('65-','70-','75-','80-')):
        return '65 and above (2020)'
    else:
        return '15-64 (2020)'
dtargets['broad_bin'] = dtargets['age'].apply(broad_bin)

census['district_key_state'] = census['Negeri']
census['district_key_district'] = census['Daerah'].where(census['Negeri']=='Selangor', census['Negeri'])
census.loc[census['Negeri']=='Kuala Lumpur', 'district_key_state'] = 'W.P. Kuala Lumpur'
census.loc[census['Negeri']=='Kuala Lumpur', 'district_key_district'] = 'W.P. Kuala Lumpur'
census.loc[census['Negeri']=='Putrajaya', 'district_key_state'] = 'W.P. Putrajaya'
census.loc[census['Negeri']=='Putrajaya', 'district_key_district'] = 'W.P. Putrajaya'

exclude_mask = census['Mukim Code'].astype(str) == 'SGR100771'
usable = census[~exclude_mask & census['Total (2020)'].notna()].copy()

broad_cols = ['0-14 (2020)', '15-64 (2020)', '65 and above (2020)']
records = []
for bcol in broad_cols:
    grp_total = usable.groupby(['district_key_state','district_key_district'])[bcol].transform('sum')
    share = usable[bcol] / grp_total
    tmp = usable[['Mukim','Daerah','Negeri','Mukim Code','Admin Mukim Code','district_key_state','district_key_district']].copy()
    tmp['broad_bin'] = bcol
    tmp['mukim_share_of_broad_bin'] = share
    records.append(tmp)
shares = pd.concat(records, ignore_index=True)

merged = dtargets.merge(shares, left_on=['state','district','broad_bin'],
                         right_on=['district_key_state','district_key_district','broad_bin'], how='inner')
merged['pop_2026_mukim_agesex_target'] = merged['mukim_share_of_broad_bin'] * merged['pop_2026_district']

out = merged[['Mukim','Daerah','Negeri','Mukim Code','Admin Mukim Code','sex','age','broad_bin','pop_2026_mukim_agesex_target']]
out.to_csv("$MUKIM_AGESEX", index=False)
print(f"Saved {len(out)} rows; total = {out['pop_2026_mukim_agesex_target'].sum():,.1f} (expect 9,657,900)")
EOF
else
  echo "=== Stage 2b: $MUKIM_AGESEX already present, skipping ==="
fi

# ---------------------------------------------------------------------------
# STAGE 3 — WorldPop's OWN native zonal sums per mukim, per raw age-sex band
#           (exactextract on the unmodified rasters), collapsed onto DOSM's
#           18 bins -> pass-1 factor = DOSM target / WorldPop's own sum
# ---------------------------------------------------------------------------
FACTORS1_CSV="$POP/mukim_agesex_factors.csv"
if [[ ! -f "$FACTORS1_CSV" ]]; then
  echo "=== Stage 3: raw WorldPop zonal extraction -> pass-1 factors ==="
  mkdir -p "$QA/agesex_raw"
  for f in "$RAW"/mys_f_*_2026_CN_100m_R2025A_v1.tif "$RAW"/mys_m_*_2026_CN_100m_R2025A_v1.tif; do
    base=$(basename "$f" .tif)
    exactextract -p "$ADMIN" -r "v:$f" -f MUKIMCODE -s "sum" \
      -o "$QA/agesex_raw/${base}_zonal.csv" 2>/dev/null
  done
  python3 << EOF
import pandas as pd
import glob, re

rows = []
for f in glob.glob("$QA/agesex_raw/*.csv"):
    m = re.search(r'mys_([fm])_(\d+)_2026', f)
    sex, wp_age = m.group(1), m.group(2)
    df = pd.read_csv(f)
    df['sex'] = 'female' if sex=='f' else 'male'
    df['wp_age'] = wp_age
    rows.append(df)
wp = pd.concat(rows, ignore_index=True)

WP_TO_DOSM = {'00':'0-4','01':'0-4','05':'5-9','10':'10-14','15':'15-19','20':'20-24','25':'25-29',
    '30':'30-34','35':'35-39','40':'40-44','45':'45-49','50':'50-54','55':'55-59',
    '60':'60-64','65':'65-69','70':'70-74','75':'75-79','80':'80-84','85':'85+','90':'85+'}
wp['dosm_age'] = wp['wp_age'].map(WP_TO_DOSM)
wp_dosm = wp.groupby(['MUKIMCODE','sex','dosm_age'])['sum'].sum().reset_index().rename(columns={'sum':'wp_native_sum'})

targets = pd.read_csv("$MUKIM_AGESEX").rename(columns={'age':'dosm_age'})
merged = targets.merge(wp_dosm, left_on=['Admin Mukim Code','sex','dosm_age'],
                        right_on=['MUKIMCODE','sex','dosm_age'], how='left')
merged['factor'] = (merged['pop_2026_mukim_agesex_target'] / merged['wp_native_sum']).fillna(0.0)
merged.loc[merged['wp_native_sum'] <= 0, 'factor'] = 0.0
merged.to_csv("$FACTORS1_CSV", index=False)
print(f"Saved {len(merged)} (mukim x sex x age) pass-1 factor rows")
EOF
  rm -rf "$QA/agesex_raw"
else
  echo "=== Stage 3: $FACTORS1_CSV already present, skipping ==="
fi

# ---------------------------------------------------------------------------
# STAGE 4 — wide pass-1 factor layer: one column per (sex x age-bin) cell,
#           joined onto the admin polygons (this is what gets rasterized)
# ---------------------------------------------------------------------------
FACTORS1_FGB="$POP/admin_units_agesex_factors.fgb"
COLMAP="$POP/agesex_colname_mapping.csv"
if [[ ! -f "$FACTORS1_FGB" ]]; then
  echo "=== Stage 4: building $FACTORS1_FGB ==="
  python3 << EOF
import geopandas as gpd
import pandas as pd

admin = gpd.read_file("$ADMIN")
factors = pd.read_csv("$FACTORS1_CSV")

sex_code = {'female': 'f', 'male': 'm'}
age_code = {a: a.replace('-', '_').replace('+', 'p') for a in factors['dosm_age'].unique()}
factors['colname'] = factors['sex'].map(sex_code) + '_' + factors['dosm_age'].map(age_code)

wide = factors.pivot(index='Admin Mukim Code', columns='colname', values='factor').reset_index()
merged = admin.merge(wide, left_on='MUKIMCODE', right_on='Admin Mukim Code', how='left')
factor_cols = [c for c in wide.columns if c != 'Admin Mukim Code']
merged[factor_cols] = merged[factor_cols].fillna(0.0)
merged.to_file("$FACTORS1_FGB", driver='FlatGeobuf')

mapping = factors[['sex','dosm_age','colname']].drop_duplicates()
mapping.to_csv("$COLMAP", index=False)
print(f"Saved {len(merged)} rows, {len(factor_cols)} factor columns")
EOF
else
  echo "=== Stage 4: $FACTORS1_FGB already present, skipping ==="
fi

# ---------------------------------------------------------------------------
# STAGE 5 — RASTERIZE the 36 pass-1 factor columns: paint each mukim's
#           scalar factor across every pixel inside its polygon (standard
#           center-of-pixel rule, ALL_TOUCHED fallback for sub-pixel mukims)
# ---------------------------------------------------------------------------
FACTOR_R1="$POP/agesex_factor_rasters"
if [[ ! -d "$FACTOR_R1" || $(ls "$FACTOR_R1"/*_combined.tif 2>/dev/null | wc -l) -lt 36 ]]; then
  echo "=== Stage 5: rasterizing pass-1 factor columns into $FACTOR_R1 ==="
  mkdir -p "$FACTOR_R1"
  count=0
  for col in f_0_4 f_5_9 f_10_14 f_15_19 f_20_24 f_25_29 f_30_34 f_35_39 f_40_44 f_45_49 f_50_54 f_55_59 f_60_64 f_65_69 f_70_74 f_75_79 f_80_84 f_85p \
             m_0_4 m_5_9 m_10_14 m_15_19 m_20_24 m_25_29 m_30_34 m_35_39 m_40_44 m_45_49 m_50_54 m_55_59 m_60_64 m_65_69 m_70_74 m_75_79 m_80_84 m_85p; do
    gdal_rasterize -a "$col" -tr $TR -te $TE -ot Float64 -a_nodata -9999 -init -9999 \
      "$FACTORS1_FGB" "$FACTOR_R1/${col}_std.tif" >/dev/null 2>&1
    gdal_rasterize -at -a "$col" -tr $TR -te $TE -ot Float64 -a_nodata -9999 -init -9999 \
      "$FACTORS1_FGB" "$FACTOR_R1/${col}_at.tif" >/dev/null 2>&1
    gdal_calc.py -A "$FACTOR_R1/${col}_std.tif" -B "$FACTOR_R1/${col}_at.tif" \
      --outfile="$FACTOR_R1/${col}_combined.tif" \
      --calc="where(A!=-9999, A, where(B!=-9999, B, -9999))" \
      --NoDataValue=-9999 --type=Float64 --overwrite --quiet
    rm -f "$FACTOR_R1/${col}_std.tif" "$FACTOR_R1/${col}_at.tif"
    count=$((count+1))
  done
  echo "Rasterized $count pass-1 factor grids"
else
  echo "=== Stage 5: pass-1 factor rasters already present, skipping ==="
fi

# ---------------------------------------------------------------------------
# STAGE 6 — pass-1 rescale: MULTIPLY each raw WorldPop band by its matching
#           factor raster (00+01 and 85+90 each share one DOSM-bin factor)
# ---------------------------------------------------------------------------
PASS1="$POP/agesex_2026_dosm_rescaled"
declare -A WP_TO_DOSM=(
  [00]=0_4 [01]=0_4 [05]=5_9 [10]=10_14 [15]=15_19 [20]=20_24 [25]=25_29
  [30]=30_34 [35]=35_39 [40]=40_44 [45]=45_49 [50]=50_54 [55]=55_59
  [60]=60_64 [65]=65_69 [70]=70_74 [75]=75_79 [80]=80_84 [85]=85p [90]=85p
)
if [[ ! -d "$PASS1" || $(ls "$PASS1"/mys_[fm]_*.tif 2>/dev/null | wc -l) -lt 40 ]]; then
  echo "=== Stage 6: pass-1 rescale into $PASS1 ==="
  mkdir -p "$PASS1"
  count=0
  for sex in f m; do
    for wpage in "${WP_AGES[@]}"; do
      dosmbin=${WP_TO_DOSM[$wpage]}
      gdal_calc.py -A "$RAW/mys_${sex}_${wpage}_2026_CN_100m_R2025A_v1.tif" \
        -B "$FACTOR_R1/${sex}_${dosmbin}_combined.tif" \
        --outfile="$PASS1/mys_${sex}_${wpage}_2026_CN_100m_R2025A_v1.tif" \
        --calc="where((A!=$NODATA)*(B!=-9999), A*B, $NODATA)" \
        --NoDataValue=$NODATA --type=Float64 --co COMPRESS=LZW --co TILED=YES --overwrite --quiet
      count=$((count+1))
    done
  done
  echo "Rescaled $count age-sex band rasters (pass 1)"
else
  echo "=== Stage 6: pass-1 rescaled bands already present, skipping ==="
fi

_derive_combined_bands() {
  # $1 = directory containing mys_f_XX / mys_m_XX bands to sum into
  # mys_t_XX / mys_T_F / mys_T_M / mys_pop_2026
  python3 << EOF
import rasterio
import numpy as np

d = "$1"
ages = "${WP_AGES[*]}".split()
NODATA = $NODATA

with rasterio.open(f"{d}/mys_f_00_2026_CN_100m_R2025A_v1.tif") as ref:
    profile = ref.profile
f_sum = np.zeros((profile['height'], profile['width']), dtype=np.float64)
m_sum = np.zeros_like(f_sum)
valid_mask = None

for age in ages:
    with rasterio.open(f"{d}/mys_f_{age}_2026_CN_100m_R2025A_v1.tif") as ff, \
         rasterio.open(f"{d}/mys_m_{age}_2026_CN_100m_R2025A_v1.tif") as fm:
        farr, marr = ff.read(1), fm.read(1)
        v = (farr != NODATA)
        if valid_mask is None:
            valid_mask = v
        t = np.where(v, farr + marr, NODATA)
        profile.update(dtype='float64', nodata=NODATA, compress='lzw', tiled=True)
        with rasterio.open(f"{d}/mys_t_{age}_2026_CN_100m_R2025A_v1.tif", 'w', **profile) as dst:
            dst.write(t.astype(np.float64), 1)
        f_sum[v] += farr[v]
        m_sum[v] += marr[v]

T_F = np.where(valid_mask, f_sum, NODATA)
T_M = np.where(valid_mask, m_sum, NODATA)
grand = np.where(valid_mask, f_sum + m_sum, NODATA)
for name, arr in [('mys_T_F_2026_CN_100m_R2025A_v1.tif', T_F),
                   ('mys_T_M_2026_CN_100m_R2025A_v1.tif', T_M),
                   ('mys_pop_2026_CN_100m_R2025A_v1.tif', grand)]:
    with rasterio.open(f"{d}/{name}", 'w', **profile) as dst:
        dst.write(arr.astype(np.float64), 1)
print(f"Grand total: {grand[valid_mask].sum():,.1f}")
EOF
}

# ---------------------------------------------------------------------------
# STAGE 7 — derive pass-1 combined bands (both-sexes bands, sex totals,
#           grand total) by SUMMING the rescaled bands, never independently
#           rescaled, so female+male=both stays exact by construction
# ---------------------------------------------------------------------------
if [[ ! -f "$PASS1/mys_pop_2026_CN_100m_R2025A_v1.tif" ]]; then
  echo "=== Stage 7: deriving pass-1 combined bands ==="
  _derive_combined_bands "$PASS1"
else
  echo "=== Stage 7: pass-1 combined bands already present, skipping ==="
fi

# ---------------------------------------------------------------------------
# STAGE 8 — pass-2 factors: re-measure what pass-1 actually achieved per
#           mukim (exactextract again, this time on the PASS-1 output) and
#           compute factor2 = target / pass1_achieved (standard IPF step,
#           corrects small boundary-pixel leakage between adjacent mukims)
# ---------------------------------------------------------------------------
FACTORS2_FGB="$POP/admin_units_agesex_factors_pass2.fgb"
if [[ ! -f "$FACTORS2_FGB" ]]; then
  echo "=== Stage 8: measuring pass-1 achieved sums -> pass-2 factors ==="
  ACHIEVED_DIR="$POP/agesex_bin_achieved"
  mkdir -p "$ACHIEVED_DIR"
  declare -A DOSM_TO_WP=(
    [5_9]=05 [10_14]=10 [15_19]=15 [20_24]=20 [25_29]=25 [30_34]=30 [35_39]=35
    [40_44]=40 [45_49]=45 [50_54]=50 [55_59]=55 [60_64]=60 [65_69]=65 [70_74]=70 [75_79]=75 [80_84]=80
  )
  for sex in f m; do
    gdal_calc.py -A "$PASS1/mys_${sex}_00_2026_CN_100m_R2025A_v1.tif" -B "$PASS1/mys_${sex}_01_2026_CN_100m_R2025A_v1.tif" \
      --outfile="$ACHIEVED_DIR/${sex}_0_4.tif" --calc="where((A!=$NODATA)*(B!=$NODATA),A+B,$NODATA)" \
      --NoDataValue=$NODATA --type=Float64 --overwrite --quiet
    gdal_calc.py -A "$PASS1/mys_${sex}_85_2026_CN_100m_R2025A_v1.tif" -B "$PASS1/mys_${sex}_90_2026_CN_100m_R2025A_v1.tif" \
      --outfile="$ACHIEVED_DIR/${sex}_85p.tif" --calc="where((A!=$NODATA)*(B!=$NODATA),A+B,$NODATA)" \
      --NoDataValue=$NODATA --type=Float64 --overwrite --quiet
    for bin in 0_4 85p; do
      exactextract -p "$FACTORS1_FGB" -r "v:$ACHIEVED_DIR/${sex}_${bin}.tif" \
        -f MUKIMCODE -s sum -o "$ACHIEVED_DIR/${sex}_${bin}_zonal.csv" 2>/dev/null
    done
    for dosmbin in "${!DOSM_TO_WP[@]}"; do
      wpage=${DOSM_TO_WP[$dosmbin]}
      exactextract -p "$FACTORS1_FGB" -r "v:$PASS1/mys_${sex}_${wpage}_2026_CN_100m_R2025A_v1.tif" \
        -f MUKIMCODE -s sum -o "$ACHIEVED_DIR/${sex}_${dosmbin}_zonal.csv" 2>/dev/null
    done
  done

  python3 << EOF
import geopandas as gpd
import pandas as pd
import glob

admin = gpd.read_file("$FACTORS1_FGB")
targets = pd.read_csv("$FACTORS1_CSV")
mapping = pd.read_csv("$COLMAP")
targets = targets.merge(mapping, on=['sex','dosm_age'], how='left')

rows = []
for f in glob.glob("$ACHIEVED_DIR/*_zonal.csv"):
    base = f.split('/')[-1].replace('_zonal.csv','')
    df = pd.read_csv(f)
    df['colname'] = base
    rows.append(df)
achieved = pd.concat(rows, ignore_index=True).rename(columns={'sum':'pass1_achieved'})

merged = targets.merge(achieved, left_on=['Admin Mukim Code','colname'], right_on=['MUKIMCODE','colname'], how='left')
merged['factor2'] = (merged['pop_2026_mukim_agesex_target'] / merged['pass1_achieved']).fillna(0.0)
merged.loc[merged['pass1_achieved'] <= 0, 'factor2'] = 0.0

wide2 = merged.pivot(index='Admin Mukim Code', columns='colname', values='factor2').reset_index()
wide2.columns = ['Admin Mukim Code'] + [f'{c}_p2' for c in wide2.columns[1:]]

out = admin[['MUKIMCODE','geometry']].merge(wide2, left_on='MUKIMCODE', right_on='Admin Mukim Code', how='left')
factor_cols = [c for c in wide2.columns if c != 'Admin Mukim Code']
out[factor_cols] = out[factor_cols].fillna(0.0)
out.to_file("$FACTORS2_FGB", driver='FlatGeobuf')
print(f"Saved {len(factor_cols)} pass-2 factor columns")
EOF
  rm -rf "$ACHIEVED_DIR"
else
  echo "=== Stage 8: $FACTORS2_FGB already present, skipping ==="
fi

# ---------------------------------------------------------------------------
# STAGE 9 — RASTERIZE the 36 pass-2 factor columns (same standard +
#           ALL_TOUCHED-fallback approach as stage 5)
# ---------------------------------------------------------------------------
FACTOR_R2="$POP/agesex_factor_rasters_pass2"
if [[ ! -d "$FACTOR_R2" || $(ls "$FACTOR_R2"/*_combined.tif 2>/dev/null | wc -l) -lt 36 ]]; then
  echo "=== Stage 9: rasterizing pass-2 factor columns into $FACTOR_R2 ==="
  mkdir -p "$FACTOR_R2"
  cols=$(ogrinfo -al -so "$FACTORS2_FGB" 2>&1 | grep "_p2:" | sed -E 's/^([A-Za-z0-9_]+):.*/\1/')
  count=0
  for col in $cols; do
    gdal_rasterize -a "$col" -tr $TR -te $TE -ot Float64 -a_nodata -9999 -init -9999 \
      "$FACTORS2_FGB" "$FACTOR_R2/${col}_std.tif" >/dev/null 2>&1
    gdal_rasterize -at -a "$col" -tr $TR -te $TE -ot Float64 -a_nodata -9999 -init -9999 \
      "$FACTORS2_FGB" "$FACTOR_R2/${col}_at.tif" >/dev/null 2>&1
    gdal_calc.py -A "$FACTOR_R2/${col}_std.tif" -B "$FACTOR_R2/${col}_at.tif" \
      --outfile="$FACTOR_R2/${col}_combined.tif" \
      --calc="where(A!=-9999, A, where(B!=-9999, B, -9999))" \
      --NoDataValue=-9999 --type=Float64 --overwrite --quiet
    rm -f "$FACTOR_R2/${col}_std.tif" "$FACTOR_R2/${col}_at.tif"
    count=$((count+1))
  done
  echo "Rasterized $count pass-2 factor grids"
else
  echo "=== Stage 9: pass-2 factor rasters already present, skipping ==="
fi

# ---------------------------------------------------------------------------
# STAGE 10 — pass-2 rescale: MULTIPLY the PASS-1 bands (not the raw WorldPop
#            bands) by the pass-2 factor -> this is the IPF-style second
#            correction pass
# ---------------------------------------------------------------------------
PASS2="$POP/agesex_2026_dosm_rescaled_pass2"
if [[ ! -d "$PASS2" || $(ls "$PASS2"/mys_[fm]_*.tif 2>/dev/null | wc -l) -lt 40 ]]; then
  echo "=== Stage 10: pass-2 rescale into $PASS2 ==="
  mkdir -p "$PASS2"
  count=0
  for sex in f m; do
    for wpage in "${WP_AGES[@]}"; do
      dosmbin=${WP_TO_DOSM[$wpage]}
      gdal_calc.py -A "$PASS1/mys_${sex}_${wpage}_2026_CN_100m_R2025A_v1.tif" \
        -B "$FACTOR_R2/${sex}_${dosmbin}_p2_combined.tif" \
        --outfile="$PASS2/mys_${sex}_${wpage}_2026_CN_100m_R2025A_v1.tif" \
        --calc="where((A!=$NODATA)*(B!=-9999), A*B, $NODATA)" \
        --NoDataValue=$NODATA --type=Float64 --co COMPRESS=LZW --co TILED=YES --overwrite --quiet
      count=$((count+1))
    done
  done
  echo "Rescaled $count age-sex band rasters (pass 2)"
else
  echo "=== Stage 10: pass-2 rescaled bands already present, skipping ==="
fi

# ---------------------------------------------------------------------------
# STAGE 11 — derive pass-2 combined bands (same logic as stage 7) -> this
#            IS the 63-raster deliverable
# ---------------------------------------------------------------------------
if [[ ! -f "$PASS2/mys_pop_2026_CN_100m_R2025A_v1.tif" ]]; then
  echo "=== Stage 11: deriving pass-2 combined bands (final deliverable) ==="
  _derive_combined_bands "$PASS2"
else
  echo "=== Stage 11: pass-2 combined bands already present, skipping ==="
fi

# ---------------------------------------------------------------------------
# STAGE 12 — validate: per-mukim total reconciliation + age-sex structure
#            check against DOSM's official 2026 targets. Should reproduce
#            README's numbers: target 9,657,900 vs achieved ~9,659,589
#            (+0.017%); every one of the 36 (sex x age) cells within 0.1%.
# ---------------------------------------------------------------------------
echo "=== Stage 12: validation ==="
exactextract -p "$FACTORS2_FGB" \
  -r "pop2026:$PASS2/mys_pop_2026_CN_100m_R2025A_v1.tif" \
  -f MUKIMCODE -s "sum" \
  -o "$QA/pop2026_dosm_agesex_pass2_zonal_check.csv"

python3 << EOF
import pandas as pd

targets = pd.read_csv("$MUKIM_TOTAL")
check = pd.read_csv("$QA/pop2026_dosm_agesex_pass2_zonal_check.csv")
m = targets.merge(check, left_on='Admin Mukim Code', right_on='MUKIMCODE', how='left')
m['diff'] = m['sum'] - m['pop_2026_mukim_target']
m['pct_diff'] = 100 * m['diff'] / m['pop_2026_mukim_target']

print("--- Per-mukim total reconciliation (pass 2, final) ---")
print(f"Total target:   {m['pop_2026_mukim_target'].sum():,.1f}")
print(f"Total achieved: {m['sum'].sum():,.1f}  "
      f"(diff {m['sum'].sum() - m['pop_2026_mukim_target'].sum():+.1f}, "
      f"{100*(m['sum'].sum()-m['pop_2026_mukim_target'].sum())/m['pop_2026_mukim_target'].sum():+.4f}%)")
print(f"Rows within 1%: {(m['pct_diff'].abs() < 1).sum()} / {len(m)}")
print(f"Rows within 5%: {(m['pct_diff'].abs() < 5).sum()} / {len(m)}")

import rasterio, glob, re

def total_sum(path, nodata=$NODATA):
    with rasterio.open(path) as ds:
        arr = ds.read(1)
        return arr[arr != nodata].sum()

rows = []
for f in sorted(glob.glob(f"$PASS2/mys_[fm]_*_2026_CN_100m_R2025A_v1.tif")):
    mo = re.search(r'mys_([fm])_(\d+)_2026', f)
    rows.append({'sex': 'Female' if mo.group(1) == 'f' else 'Male',
                 'wp_age': mo.group(2), 'population_2026': total_sum(f)})
df = pd.DataFrame(rows)
WP_TO_DOSM = {'00':'0-4','01':'0-4','05':'5-9','10':'10-14','15':'15-19','20':'20-24','25':'25-29',
    '30':'30-34','35':'35-39','40':'40-44','45':'45-49','50':'50-54','55':'55-59',
    '60':'60-64','65':'65-69','70':'70-74','75':'75-79','80':'80-84','85':'85+','90':'85+'}
df['age_band'] = df['wp_age'].map(WP_TO_DOSM)
achieved = df.groupby(['sex','age_band'])['population_2026'].sum().reset_index()

mukim_targets = pd.read_csv("$MUKIM_AGESEX")
dosm_official = mukim_targets.groupby(['sex','age'])['pop_2026_mukim_agesex_target'].sum().reset_index()
dosm_official['sex'] = dosm_official['sex'].str.capitalize()
dosm_official = dosm_official.rename(columns={'age':'age_band','pop_2026_mukim_agesex_target':'dosm_official'})

comp = achieved.merge(dosm_official, on=['sex','age_band'], how='left')
comp['pct_diff'] = 100 * (comp['population_2026'] - comp['dosm_official']) / comp['dosm_official']
print()
print("--- Age-sex structure vs DOSM official 2026 targets (all 36 cells) ---")
print(f"Max abs %% diff across all 36 (sex x age bin) cells: {comp['pct_diff'].abs().max():.3f}%%")
print(f"Cells within 0.1%%: {(comp['pct_diff'].abs() < 0.1).sum()} / {len(comp)}")
EOF

echo
echo "Done. Deliverable: $PASS2/  (63 rasters, 100m, EPSG:4326)"
