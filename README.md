# Ibogaine Restriction Burden: Analytic Code

This repository contains the analytic code for:

> Green JA, Rowan C, et al. "Restriction burden of ibogaine clinical trial candidates across three real-world cohorts." *JAMA Network Open* (under review, 2026).

The analysis quantifies the proportion of potential ibogaine trial participants who are
currently prescribed medications that would be restricted under typical cardiac safety
protocols, using three independent cohorts.

---

## Cohorts

| Cohort | Data Source | N at index | Period |
|---|---|---|---|
| NIH All of Us | C2024Q3R9 | see manuscript | 2016 to 2023 |
| Rutgers CRDW | Through April 2025 | see manuscript | 2016 to 2024 |
| Medicare FFS | DUA RSCH-2024-70249 | 590,770 | 2016 to 2022 |

**Eligibility**: OUD diagnosis plus 2 of the following qualifying conditions: PTSD, MDD,
anxiety disorder, or prior MOUD exposure.

---

## Repository Structure

```
medicare_sas/           Medicare FFS analytic pipeline (SAS)
  00_ibogaine_setup.sas   Central configuration: set proj_root here
  01_validate_lydia_staging.sas
  02_build_landmark_population.sas
  03_define_cyp2d6_exposure.sas
  04_first_pass_results.sas
  ibogaine_05_adjusted_model.sas
  ibogaine_06a_active_burden_v3.sas
  ibogaine_06b_discontinuation_v3.sas
  ibogaine_07a_cardiac_feasibility.sas
  ibogaine_08_supplemental_analysis.sas
  ibogaine_09_age_interaction_audit.sas
  ibogaine_11_trial_eligibility_burden.sas    Composite restriction burden
  ibogaine_12_harmonized_sensitivity.sas
  ...supporting diagnostic and audit files

CRDW_Paper2_v4_1_AMAREL.ipynb    Rutgers CRDW pipeline (Python/Jupyter)
```

---

## Running the Medicare FFS Pipeline

### Prerequisites

- SAS 9.4 or later (tested on SAS 9.4 TS1M7, Citrix server environment)
- Access to Medicare Fee-for-Service Part D claims data under an approved DUA
- The pipeline was developed and run under DUA RSCH-2024-70249 (PI: C. Rowan,
  Rutgers Institute for Health, Health Care Policy and Aging Research)

### Configuration

Before running any script, open `medicare_sas/00_ibogaine_setup.sas` and set
`proj_root` to your working directory:

```sas
%let proj_root = /path/to/your/working/directory;
```

The setup file derives all downstream library assignments from this single macro
variable. All other scripts either include `00_ibogaine_setup.sas` or inherit its
library assignments from a driver script.

**Expected subdirectory layout under `proj_root`:**

```
proj_root/
  Output/
    temp_output_green/
  Working/
    Cohorts/
    Ibogaine_FirstPass/
  Ibogaine_Extraction/
    Output/
      Enrollment/
```

### Running Order

Run scripts in numeric order using one of the driver files:

| Driver | Purpose |
|---|---|
| `99a_run_staging_audit.sas` | Staging validation only |
| `99b_run_branch_test.sas` | Branch test (small sample) |
| `99c_run_full_firstpass.sas` | Full first-pass production run |

Alternatively, run individual numbered files in sequence (00 through 12) for
step-by-step execution.

---

## Running the CRDW Pipeline

`CRDW_Paper2_v4_1_AMAREL.ipynb` is a Jupyter notebook developed for the
Rutgers Amarel high-performance computing cluster. It requires:

- Python 3.9+
- Standard scientific stack: `pandas`, `numpy`, `scipy`, `statsmodels`
- Access to the Rutgers CRDW (Center for Real-World Data and Analytics) environment

The notebook is provided for transparency and reproducibility documentation.
Direct replication requires an approved CRDW data use agreement.

---

## Data Availability

The Medicare FFS data underlying the Medicare analysis are not publicly available.
Researchers may apply for access through the ResDAC/CMS data request process.

The NIH All of Us data are available to registered researchers through the
All of Us Researcher Workbench (https://workbench.researchallofus.org).

The Rutgers CRDW data require a data use agreement with Rutgers University.

---

## Key Results

| Cohort | Prevalence Ratio (95% CI) |
|---|---|
| NIH All of Us | 8.06 (6.86, 9.47) |
| Rutgers CRDW | 5.51 (4.01, 7.57) |
| Medicare FFS | 3.51 (3.44, 3.59) |

Composite restriction burden (Medicare FFS, primary estimate): **29.5%**

---

## Citation

Green JA, Rowan C, et al. Restriction burden of ibogaine clinical trial candidates
across three real-world cohorts. *JAMA Network Open*. 2026 (under review).

Preprint: medRxiv (forthcoming).

---

## License

Code is released under the MIT License. Data are governed by their respective
data use agreements and cannot be shared.

---

## Contact

James A. Green, MSA
Rutgers Institute for Health, Health Care Policy and Aging Research
GitHub: https://github.com/jamesgreenmsa/ibogaine-research
