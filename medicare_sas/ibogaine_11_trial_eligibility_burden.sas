/* ============================================================================
   ibogaine_11_trial_eligibility_burden.sas
   Trial Medication Eligibility Burden Analysis - Medicare FFS

   PURPOSE:
   Quantifies the proportion of proxy-defined ibogaine candidates who carry
   active medication co-exposures corresponding to published ibogaine trial
   restriction criteria, particularly NCT05029401 (oral ibogaine study).

   FRAMING NOTE: This is an active-at-index medication snapshot, not a
   literal trial eligibility determination. Frame as "medication restriction
   burden at the analytic index date" or "active medication burden
   corresponding to published trial restrictions" rather than "trial
   incompatibility" or "eligibility."

   DESIGN:
   Cross-sectional. Exposure ascertainment at the pre-specified analytic
   index date using Part D days-supply (same index as primary Paper 2
   analysis). All flags are active-at-index only.

   REFERENCE PROTOCOL: NCT05029401
   Key medication restrictions:
     - Strong CYP2D6 inhibitors (bupropion, paroxetine, fluoxetine)
     - Any SSRI or SNRI near dosing
     - QT-prolonging medications
     - Mood stabilizers (lithium, valproate, lamotrigine, carbamazepine)

   PRE-SPECIFIED TIERS:
     Tier 1: Active strong CYP2D6 inhibitor only (bupropion/paroxetine/
             fluoxetine) - already quantified in primary analysis (15.8%)
     Tier 2: Active SSRI or SNRI (broader than Tier 1; includes sertraline,
             escitalopram, citalopram, venlafaxine, duloxetine, desvenlafaxine)
     Tier 3: Active QT-prolonging medication (antipsychotics: haloperidol,
             quetiapine, risperidone, olanzapine, ziprasidone, aripiprazole,
             clozapine, thioridazine; plus methadone)
     Tier 4: Active mood stabilizer (lithium, valproate/divalproex,
             lamotrigine, carbamazepine, oxcarbazepine)
     Composite: Any Tier 1, 2, 3, or 4 medication active at index
     Dual conflict: Two or more distinct tier conflicts active at index

   OUTPUTS:
     coh.ibog_11_eligibility_flags    - patient-level flag dataset
     coh.ibog_11_eligibility_summary  - prevalence table by group
     coh.ibog_11_eligibility_tiers    - tier-by-tier breakdown
     coh.ibog_11_vet_eligibility      - veteran subgroup (if demographics
                                         available from eligible_scp table)

   DEPENDENCIES:
     coh.ibog_fp_analysis_fp_full_v001 - primary analytic table
     ibog._ibogaine_pd_flags           - Part D claim-level drug data
                                         (FDB_GNN60 = generic drug name)
     ibog.eligible_scp_ibogaine_bene_flags - demographics if available

   SERVER: crdw-ifhsas02-prod-asb.rad.rutgers.edu (IFH Citrix)
   AUTHOR: James Green, MS - jg1984@shp.rutgers.edu
   DATE:   September 2, 2026
   VERSION: v1
============================================================================ */

options nodate nonumber ls=180 ps=max;
%let run_date = %sysfunc(today(), yymmdd10.);
%put NOTE: ibogaine_11 Trial Eligibility Burden - run date: &run_date;

libname coh  "/path/to/your/working/directory\Working\Cohorts";
libname ibog "/path/to/your/working/directory\Ibogaine_Extraction\Output";

proc contents data=ibog._ibogaine_pd_flags; run;

/* ── SECTION 1: Pull primary cohort ───────────────────────────────────────
   Candidates and non-candidates from the confirmed primary analytic table.
   N=590,770 confirmed by audit v7 Section E.                              */

%put NOTE: [Section 1] Loading primary analytic cohort...;

/* Rebuild PSYCH_ONLY groups from component flags using coalesce()
   so missing flags become 0 rather than propagating missing values
   that would silently misclassify patients as intermediate.
   This is the Medicare primary definition (PSYCH_ONLY) - no MOUD qualifier. */
proc sql;
  create table _s1_cohort as
  select bene_id,
         index_dt,
         active_primary as tier1_strong_inhib,
         partd_active_window_obs,
         partd_full_year_obs,
         (coalesce(flag_ptsd_w,0) +
          coalesce(flag_depression_w,0) +
          coalesce(flag_anxiety_w,0))  as harm_q_count,
         case
           when (coalesce(flag_ptsd_w,0) +
                 coalesce(flag_depression_w,0) +
                 coalesce(flag_anxiety_w,0)) >= 2 then 'CANDIDATE'
           when (coalesce(flag_ptsd_w,0) +
                 coalesce(flag_depression_w,0) +
                 coalesce(flag_anxiety_w,0)) = 0  then 'COMPARATOR'
           else 'INTERMEDIATE'
         end                           as cohort_group length=12
  from coh.ibog_fp_analysis_fp_full_v001
  where (coalesce(flag_ptsd_w,0) +
         coalesce(flag_depression_w,0) +
         coalesce(flag_anxiety_w,0)) in (0, 2, 3); /* candidates and comparators only */
quit;

%put NOTE: Cohort loaded. Confirming N...;
proc freq data=_s1_cohort; tables cohort_group / nocum; run;

/* Cohort gate - abort if reconstructed N deviates materially from confirmed 590,770 */
proc sql noprint;
  select count(*) into :n_cohort_check
  from _s1_cohort
  where cohort_group in ('CANDIDATE','COMPARATOR');
quit;
%put NOTE: Reconstructed candidate+comparator N = &n_cohort_check (target: 590,770);
%if %sysfunc(abs(%eval(&n_cohort_check - 590770))) > 1000 %then %do;
  %put ERROR: Cohort N deviates from confirmed 590,770 by more than 1,000.;
  %put ERROR: Check component flag derivation and WHERE clause before proceeding.;
  %abort cancel;
%end;
%put NOTE: Cohort gate PASSED. Proceeding.;

/* ── SECTION 2: Build medication flag lists ────────────────────────────────
   Each tier derived from FDB_GNN60 in ibog._ibogaine_pd_flags.
   All flags: active at index date (days-supply spans index_dt).
   One row per bene_id per fill; we collapse to patient level.

   IMPORTANT: active_primary (Tier 1) already exists in the primary table.
   We re-derive here for audit consistency and to confirm the source,
   then use the primary table value as the authoritative Tier 1 flag.     */

%put NOTE: [Section 2] Building medication flags from ibog._ibogaine_pd_flags...;

/* --- Tier 2a: any_ssri_snri - includes ALL SSRIs/SNRIs (incl. Tier 1 drugs)
   This is the clinically interpretable prevalence: how many candidates have
   ANY SSRI/SNRI active at index? Use for prevalence reporting.           --- */
proc sql;
  create table _t2a_any_ssri_snri as
  select distinct a.bene_id
  from _s1_cohort a
  inner join ibog._ibogaine_pd_flags b on a.bene_id = b.bene_id
  where b.srvc_dt <= a.index_dt
    and (b.srvc_dt + b.DAYS_SUPLY_NUM) > a.index_dt
    and (
      upcase(b.FDB_GNN60) contains 'SERTRALINE'       or
      upcase(b.FDB_GNN60) contains 'ESCITALOPRAM'     or
      upcase(b.FDB_GNN60) contains 'CITALOPRAM'       or
      upcase(b.FDB_GNN60) contains 'FLUVOXAMINE'      or
      /* bupropion excluded: not an SSRI/SNRI; belongs only in Tier 1 */
      upcase(b.FDB_GNN60) contains 'PAROXETINE'       or
      upcase(b.FDB_GNN60) contains 'FLUOXETINE'       or
      upcase(b.FDB_GNN60) contains 'VENLAFAXINE'      or
      upcase(b.FDB_GNN60) contains 'DULOXETINE'       or
      upcase(b.FDB_GNN60) contains 'DESVENLAFAXINE'   or
      upcase(b.FDB_GNN60) contains 'LEVOMILNACIPRAN'  or
      upcase(b.FDB_GNN60) contains 'MILNACIPRAN'
    );
quit;
proc sql noprint; select count(*) into :_n_t2a from _t2a_any_ssri_snri; quit;
%put NOTE: _t2a_any_ssri_snri (ANY SSRI/SNRI including Tier 1 drugs): &_n_t2a;

/* --- Tier 2b: other_ssri_snri - excludes Tier 1 strong inhibitors
   Use for non-overlapping conflict counts (composite/dual flags).
   NOT labeled "any SSRI/SNRI" because it excludes fluoxetine/paroxetine. */
/* --- Tier 2: SSRI/SNRI (broader than Tier 1) --- */
/* Includes all SSRIs and SNRIs per NCT05029401 exclusion language.
   Sertraline, escitalopram, citalopram, fluvoxamine = SSRIs (not strong
   CYP2D6 inhibitors but restricted near ibogaine dosing).
   Venlafaxine, duloxetine, desvenlafaxine, levomilnacipran = SNRIs.    */

proc sql;
  create table _t2_ssri_snri as
  select distinct a.bene_id
  from _s1_cohort a
  inner join ibog._ibogaine_pd_flags b on a.bene_id = b.bene_id
  where b.srvc_dt <= a.index_dt
    and (b.srvc_dt + b.DAYS_SUPLY_NUM) > a.index_dt
    and (
      /* SSRIs */
      upcase(b.FDB_GNN60) contains 'SERTRALINE'       or
      upcase(b.FDB_GNN60) contains 'ESCITALOPRAM'     or
      upcase(b.FDB_GNN60) contains 'CITALOPRAM'       or
      upcase(b.FDB_GNN60) contains 'FLUVOXAMINE'      or
      /* bupropion, paroxetine, fluoxetine already in Tier 1 - excluded here to prevent double-counting */
      /* SNRIs */
      upcase(b.FDB_GNN60) contains 'VENLAFAXINE'      or
      upcase(b.FDB_GNN60) contains 'DULOXETINE'       or
      upcase(b.FDB_GNN60) contains 'DESVENLAFAXINE'   or
      upcase(b.FDB_GNN60) contains 'LEVOMILNACIPRAN'  or
      upcase(b.FDB_GNN60) contains 'MILNACIPRAN'
    );
quit;

proc sql noprint; select count(*) into :_n__t2_ssri_snri from _t2_ssri_snri; quit;
%put NOTE: _t2_ssri_snri active-at-index patients: &_n__t2_ssri_snri;

/* --- Tier 3: Selected QT-associated medications (antipsychotics + methadone) ---
   NOTE: This is a selected set, not a comprehensive QT drug list.
   Label accordingly in manuscript: 'selected QT-associated antipsychotics
   and methadone' rather than 'QT-prolonging medications' generically.    */

proc sql;
  create table _t3_qt_prolonging as
  select distinct a.bene_id
  from _s1_cohort a
  inner join ibog._ibogaine_pd_flags b on a.bene_id = b.bene_id
  where b.srvc_dt <= a.index_dt
    and (b.srvc_dt + b.DAYS_SUPLY_NUM) > a.index_dt
    and (
      upcase(b.FDB_GNN60) contains 'HALOPERIDOL'      or
      upcase(b.FDB_GNN60) contains 'QUETIAPINE'       or
      upcase(b.FDB_GNN60) contains 'RISPERIDONE'      or
      upcase(b.FDB_GNN60) contains 'OLANZAPINE'       or
      upcase(b.FDB_GNN60) contains 'ZIPRASIDONE'      or
      upcase(b.FDB_GNN60) contains 'ARIPIPRAZOLE'     or
      upcase(b.FDB_GNN60) contains 'CLOZAPINE'        or
      upcase(b.FDB_GNN60) contains 'THIORIDAZINE'     or
      upcase(b.FDB_GNN60) contains 'CHLORPROMAZINE'   or
      upcase(b.FDB_GNN60) contains 'METHADONE'
    );
quit;

proc sql noprint; select count(*) into :_n__t3_qt_prolonging from _t3_qt_prolonging; quit;
%put NOTE: _t3_qt_prolonging active-at-index patients: &_n__t3_qt_prolonging;

/* --- Tier 4: Mood stabilizers --- */
/* Per NCT05029401 and related protocols restricting mood-stabilizing agents
   that may interact with ibogaine's CNS profile.                         */

proc sql;
  create table _t4_mood_stabilizers as
  select distinct a.bene_id
  from _s1_cohort a
  inner join ibog._ibogaine_pd_flags b on a.bene_id = b.bene_id
  where b.srvc_dt <= a.index_dt
    and (b.srvc_dt + b.DAYS_SUPLY_NUM) > a.index_dt
    and (
      upcase(b.FDB_GNN60) contains 'LITHIUM'          or
      upcase(b.FDB_GNN60) contains 'VALPROATE'        or
      upcase(b.FDB_GNN60) contains 'DIVALPROEX'       or
      upcase(b.FDB_GNN60) contains 'VALPROIC ACID'    or
      upcase(b.FDB_GNN60) contains 'LAMOTRIGINE'      or
      upcase(b.FDB_GNN60) contains 'CARBAMAZEPINE'    or
      upcase(b.FDB_GNN60) contains 'OXCARBAZEPINE'
    );
quit;

proc sql noprint; select count(*) into :_n__t4_mood_stabilizers from _t4_mood_stabilizers; quit;
%put NOTE: _t4_mood_stabilizers active-at-index patients: &_n__t4_mood_stabilizers;

/* ── SECTION 3: Merge all flags onto cohort ───────────────────────────────*/

%put NOTE: [Section 3] Merging medication flags...;

proc sql;
  create table _s3_flagged as
  select a.*,
         /* Tier 2a: any active SSRI/SNRI (includes paroxetine/fluoxetine)
            Use this for prevalence reporting: "any SSRI/SNRI at index"   */
         case when b2a.bene_id is not null then 1 else 0 end as any_ssri_snri,
         /* Tier 2b: other SSRI/SNRI (excludes Tier-1-overlapping drugs)
            Use this for non-overlapping composite/dual-conflict counts    */
         case when b2b.bene_id is not null then 1 else 0 end as tier2_other_ssri_snri,
         /* Tier 3: selected QT-associated antipsychotics + methadone */
         case when b3.bene_id is not null then 1 else 0 end as tier3_qt_associated,
         /* Tier 4: mood stabilizer */
         case when b4.bene_id is not null then 1 else 0 end as tier4_mood_stabilizer,
         /* Composite: any active medication restriction burden
            Uses tier2_other_ssri_snri to avoid double-counting Tier-1 drugs */
         case when a.tier1_strong_inhib = 1
               or b2b.bene_id is not null
               or b3.bene_id is not null
               or b4.bene_id is not null
              then 1 else 0 end as composite_restriction_burden,
         /* Dual conflict: 2+ distinct non-overlapping tier conflicts */
         case when (a.tier1_strong_inhib +
                    (case when b2b.bene_id is not null then 1 else 0 end) +
                    (case when b3.bene_id is not null then 1 else 0 end) +
                    (case when b4.bene_id is not null then 1 else 0 end)) >= 2
              then 1 else 0 end as dual_restriction_burden
  from _s1_cohort a
  left join _t2a_any_ssri_snri   b2a on a.bene_id = b2a.bene_id
  left join _t2_ssri_snri        b2b on a.bene_id = b2b.bene_id
  left join _t3_qt_prolonging    b3  on a.bene_id = b3.bene_id
  left join _t4_mood_stabilizers b4  on a.bene_id = b4.bene_id;
quit;

/* Save permanent output */
data coh.ibog_11_eligibility_flags;
  set _s3_flagged;
run;

%put NOTE: coh.ibog_11_eligibility_flags written.;

/* ── SECTION 4: Summary tables ────────────────────────────────────────────*/

%put NOTE: [Section 4] Computing summary tables...;

/* Tier-by-tier prevalence by cohort group */
proc sql;
  create table _s4_summary as
  select cohort_group,
         count(*) as n,
         sum(tier1_strong_inhib)     as n_tier1,
         mean(tier1_strong_inhib)*100 as pct_tier1,
         sum(any_ssri_snri)             as n_tier2_any,
         mean(any_ssri_snri)*100        as pct_tier2_any,
         sum(tier2_other_ssri_snri)     as n_tier2_other,
         mean(tier2_other_ssri_snri)*100 as pct_tier2_other,
         sum(tier3_qt_associated)       as n_tier3,
         mean(tier3_qt_associated)*100  as pct_tier3,
         sum(tier4_mood_stabilizer)     as n_tier4,
         mean(tier4_mood_stabilizer)*100 as pct_tier4,
         sum(composite_restriction_burden)  as n_composite,
         mean(composite_restriction_burden)*100 as pct_composite,
         sum(dual_restriction_burden)   as n_dual,
         mean(dual_restriction_burden)*100 as pct_dual
  from coh.ibog_11_eligibility_flags
  group by cohort_group
  order by cohort_group;
quit;

data coh.ibog_11_eligibility_summary;
  set _s4_summary;
run;

title "Trial Medication Eligibility Burden - Candidates vs Non-Candidates";
proc print data=coh.ibog_11_eligibility_summary noobs;
  format pct_: 6.2;
run;

/* Tier breakdown as separate rows for table generation */
proc sql;
  create table coh.ibog_11_eligibility_tiers as
  select cohort_group,
         'Tier 1: Strong CYP2D6 inhibitor (bupropion/paroxetine/fluoxetine)'
           as restriction_label length=80,
         n_tier1 as n_flagged,
         pct_tier1 as pct_flagged,
         'NCT05029401 - CYP2D6 inhibitor exclusion' as protocol_basis length=60
  from _s4_summary
  union all
  select cohort_group,
         'Tier 2a: Any SSRI/SNRI (incl. paroxetine/fluoxetine)' as restriction_label,
         n_tier2_any as n_flagged, pct_tier2_any as pct_flagged,
         'NCT05029401 - SSRI/SNRI restriction near dosing'
  from _s4_summary
  union all
  select cohort_group,
         'Tier 3: QT-prolonging medication (antipsychotics, methadone)'
           as restriction_label,
         n_tier3, pct_tier3,
         'NCT05029401 - QT-prolonging drug exclusion'
  from _s4_summary
  union all
  select cohort_group,
         'Tier 4: Mood stabilizer (lithium, valproate, lamotrigine, etc.)'
           as restriction_label,
         n_tier4, pct_tier4,
         'NCT05029401 - mood stabilizer restriction'
  from _s4_summary
  union all
  select cohort_group,
         'Composite: Any trial-incompatible medication' as restriction_label,
         n_composite, pct_composite,
         'Any Tier 1-4 restriction burden (non-overlapping)'
  from _s4_summary
  union all
  select cohort_group,
         'Dual conflict: 2+ distinct medication class conflicts'
           as restriction_label,
         n_dual, pct_dual,
         'Two or more distinct restriction burden tiers'
  from _s4_summary
  order by restriction_label, cohort_group;
quit;

title "Trial Eligibility Burden - Tier-by-Tier Breakdown";
proc print data=coh.ibog_11_eligibility_tiers noobs;
  format pct_flagged 6.2;
run;

/* ── SECTION 5: Chi-square tests ──────────────────────────────────────────*/

%put NOTE: [Section 5] Chi-square tests (candidate vs non-candidate)...;

%macro chi2_tier(var=, label=);
  /* Use a short fixed temp name to avoid SAS 32-char member name limit */
  proc freq data=coh.ibog_11_eligibility_flags noprint;
    tables cohort_group * &var / chisq;
    output out=_chi_tmp chisq;
  run;
  data _chi_tmp;
    set _chi_tmp;
    restriction = "&label";
    varname     = "&var";
  run;
  %put NOTE: Chi-square for &label computed.;
%mend;

%chi2_tier(var=tier1_strong_inhib,      label=Tier 1: Strong CYP2D6 inhibitor);
%chi2_tier(var=any_ssri_snri,            label=Tier 2a: Any SSRI/SNRI (incl. parox/fluox));
%chi2_tier(var=tier2_other_ssri_snri,    label=Tier 2b: Other SSRI/SNRI (non-overlapping));
%chi2_tier(var=tier3_qt_prolonging,     label=Tier 3: QT-prolonging);
%chi2_tier(var=tier4_mood_stabilizer,   label=Tier 4: Mood stabilizer);
%chi2_tier(var=composite_restriction_burden,label=Composite: Any restriction burden);
%chi2_tier(var=dual_restriction_burden,     label=Dual: 2+ restriction burdens);

/* ── SECTION 6: Veteran subgroup ───────────────────────────────────────────
   The veteran enrichment analysis is performed in the All of Us Workbench
   (ibogaine_13_aou_veteran_candidacy.py), where self-reported military
   service is the authoritative variable and the analysis has the correct
   all-OUD denominator.

   Medicare veteran status is not derived here because:
   (1) The IBEN enrollment library was deleted after cohort assembly.
   (2) Opportunistic detection from the SCP table risks selecting an
       unrelated service-date or service-use field.

   If a confirmed veteran variable becomes available in the SCP table after
   review of PROC CONTENTS output, add it explicitly here by name.         */

%put NOTE: [Section 6] Veteran subgroup: see ibogaine_13_aou_veteran_candidacy.py;
%put NOTE: [Section 6] Veteran analysis performed in All of Us Workbench.;
%put NOTE: [Section 6] Medicare veteran status not derived here.;


/* ── SECTION 7: Qualifier-gradient breakdown ──────────────────────────────
   Trial conflict composite by qualifier count - shows whether the
   eligibility burden increases monotonically with clinical complexity.
   This is the strongest argument against "just generic polypharmacy."    */

%put NOTE: [Section 7] Eligibility burden by qualifier count...;

proc sql;
  create table _s7_gradient as
  select harm_q_count,
         cohort_group,
         count(*) as n,
         sum(composite_restriction_burden) as n_composite,
         mean(composite_restriction_burden)*100 as pct_composite,
         sum(tier1_strong_inhib) as n_tier1,
         mean(tier1_strong_inhib)*100 as pct_tier1,
         sum(any_ssri_snri) as n_tier2_any,
         mean(any_ssri_snri)*100 as pct_tier2_any
  from coh.ibog_11_eligibility_flags
  group by harm_q_count, cohort_group
  order by harm_q_count, cohort_group;
quit;

/* NOTE: Section 1 excluded 1-qualifier intermediates (harm_q_count=1)
   from _s1_cohort. The gradient below therefore shows only q=0 and q=2/3.
   To present a full 0→1→2→3 gradient, re-run Section 1 including
   intermediates by changing the WHERE clause to: in (0,1,2,3).           */
title "Trial Eligibility Burden by Qualifier Count (q=0,2,3 only - see note)";
proc print data=_s7_gradient noobs;
  format pct_: 6.2;
run;

/* ── SECTION 8: Summary printout ──────────────────────────────────────────*/

%put NOTE: [Section 8] Final summary...;

title "=== TRIAL ELIGIBILITY BURDEN - FINAL SUMMARY ===";
proc sql;
  select cohort_group,
         n                                          label='N total',
         n_composite                                label='N any trial conflict',
         put(pct_composite,6.2)||'%'                label='% any conflict',
         n_tier1                                    label='N Tier 1 (strong CYP2D6 inh)',
         put(pct_tier1,6.2)||'%'                    label='% Tier 1',
         n_tier2_any                                label='N Tier 2a (Any SSRI/SNRI)',
         put(pct_tier2_any,6.2)||'%'                label='% Tier 2a (Any SSRI/SNRI)',
         n_tier3                                    label='N Tier 3 (QT-prolonging)',
         put(pct_tier3,6.2)||'%'                    label='% Tier 3',
         n_tier4                                    label='N Tier 4 (mood stabilizer)',
         put(pct_tier4,6.2)||'%'                    label='% Tier 4',
         n_dual                                     label='N dual conflict',
         put(pct_dual,6.2)||'%'                     label='% dual conflict'
  from coh.ibog_11_eligibility_summary;
quit;
title;

%put NOTE: ================================================================;
%put NOTE: ibogaine_11_trial_eligibility_burden.sas COMPLETE;
%put NOTE: Permanent outputs:;
%put NOTE:   coh.ibog_11_eligibility_flags     (patient-level flags);
%put NOTE:   coh.ibog_11_eligibility_summary   (group-level prevalence);
%put NOTE:   coh.ibog_11_eligibility_tiers     (tier-by-tier table);
%put NOTE:   coh.ibog_11_vet_eligibility       (veteran subgroup - if available);
%put NOTE: Run date: &run_date;
%put NOTE: ================================================================;
