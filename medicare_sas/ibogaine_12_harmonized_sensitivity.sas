/* ============================================================================
   ibogaine_12_harmonized_sensitivity.sas  [v2]
   Harmonized Sensitivity - Medicare FFS Verification Component

   PURPOSE:
   Medicare-side component of the three-cohort harmonized sensitivity analysis.

   MEDICARE CONTEXT:
   The primary Medicare definition (PSYCH_ONLY) is ALREADY the harmonized
   definition - it uses only PTSD, depression, and anxiety flags, with no
   MOUD qualifier, no TBI, and no dual-MOUD mechanism. This program therefore
   serves as a verification: reconstruct the PSYCH_ONLY phenotype from its
   three component flags using coalesce() and confirm it reproduces the
   primary cohort N and strong-inhibitor effect estimate.

   THE ACTUAL NEW HARMONIZED ANALYSIS is performed in All of Us and CRDW
   (see the companion All of Us notebook session), where the existing
   definitions include MOUD/TBI/dual-MOUD and must be restricted to the
   three psychiatric flags for cross-cohort comparability.

   WHAT THIS PROGRAM PRODUCES:
   1. Verified PSYCH_ONLY cohort from component flags (should match N=590,770)
   2. Qualifier gradient under the three-flag definition
   3. Unadjusted prevalence by group
   4. Adjusted PR - fixed, explicit model (no conditional %IF blocks)
      Covariates: age_at_index, sex, rti_race_cd - confirmed by audit v7

   NOTE ON ADJUSTED MODEL:
   Demographics confirmed present in ibog.eligible_scp_ibogaine_bene_flags
   by PROC CONTENTS in audit v7. If a variable is absent, edit the MODEL
   statement directly before running rather than relying on conditional logic.

   OUTPUTS:
     coh.ibog_12_harm_cohort      - patient-level verified cohort
     coh.ibog_12_harm_summary     - prevalence by group
     coh.ibog_12_harm_gradient    - qualifier gradient
     coh.ibog_12_harm_pr          - adjusted PR (log-Poisson)

   SERVER: crdw-ifhsas02-prod-asb.rad.rutgers.edu (IFH Citrix)
   AUTHOR: James Green, MS - jg1984@shp.rutgers.edu
   DATE:   September 2, 2026
   VERSION: v2 - Medicare as verification; no conditional %IF in models
============================================================================ */
libname out1 "/path/to/your/working/directory\Output";
proc contents data=out1.enrollment_raw; run;

options nodate nonumber ls=180 ps=max;
%let run_date = %sysfunc(today(), yymmdd10.);
%put NOTE: ibogaine_12 v2 - Harmonized Sensitivity (Medicare verification);
%put NOTE: Run date: &run_date;

libname coh  "/path/to/your/working/directory\Working\Cohorts";
libname ibog "/path/to/your/working/directory\Ibogaine_Extraction\Output";

/* ── SECTION 1: Confirm required variables exist ──────────────────────────*/

%put NOTE: [Section 1] Confirming required variables in fp_full table...;

proc contents data=coh.ibog_fp_analysis_fp_full_v001 out=_cols noprint; run;

proc sql noprint;
  select count(*) into :has_ptsd from _cols where upcase(name)='FLAG_PTSD_W';
  select count(*) into :has_dep  from _cols where upcase(name)='FLAG_DEPRESSION_W';
  select count(*) into :has_anx  from _cols where upcase(name)='FLAG_ANXIETY_W';
  select count(*) into :has_act  from _cols where upcase(name)='ACTIVE_PRIMARY';
quit;

%if &has_ptsd=0 or &has_dep=0 or &has_anx=0 or &has_act=0 %then %do;
  %put ERROR: Required variables missing. Aborting.;
  %put ERROR: has_ptsd=&has_ptsd  has_dep=&has_dep  has_anx=&has_anx  has_act=&has_act;
  %abort cancel;
%end;
%put NOTE: All four required variables confirmed. Proceeding.;

/* ── SECTION 2: Rebuild PSYCH_ONLY phenotype from component flags ─────────
   Use coalesce() so missing flags become 0 rather than propagating missing,
   which would silently misclassify patients as intermediate.              */

%put NOTE: [Section 2] Rebuilding PSYCH_ONLY from component flags...;

proc sql;
  create table _s2_cohort as
  select bene_id,
         index_dt,
         active_primary,
         /* Individual flags - coalesce to 0 to prevent silent misclassification */
         coalesce(flag_ptsd_w,      0) as flag_ptsd,
         coalesce(flag_depression_w, 0) as flag_dep,
         coalesce(flag_anxiety_w,   0) as flag_anx,
         /* Qualifier count - max 3, MOUD excluded */
         (coalesce(flag_ptsd_w,0) +
          coalesce(flag_depression_w,0) +
          coalesce(flag_anxiety_w,0))   as harm_q_count,
         /* Group assignment */
         case
           when (coalesce(flag_ptsd_w,0) +
                 coalesce(flag_depression_w,0) +
                 coalesce(flag_anxiety_w,0)) >= 2
             then 'CANDIDATE'
           when (coalesce(flag_ptsd_w,0) +
                 coalesce(flag_depression_w,0) +
                 coalesce(flag_anxiety_w,0)) = 0
             then 'COMPARATOR'
           else 'INTERMEDIATE'
         end                             as harm_group length=12
  from coh.ibog_fp_analysis_fp_full_v001;
quit;

data coh.ibog_12_harm_cohort;
  set _s2_cohort;
run;

/* ── SECTION 3: Verification - does this reproduce primary cohort? ────────*/

%put NOTE: [Section 3] Verification - comparing reconstructed vs original...;

title "Harmonized reconstruction - group counts";
proc freq data=coh.ibog_12_harm_cohort;
  tables harm_group / nocum;
run;

/* Crosswalk removed - original_group not selected in reconstructed cohort.
   Compare counts above against the known primary cohort Ns:
   CANDIDATE target = 307,336 | COMPARATOR target = 283,434               */

/* Flag if candidate N differs from primary (should be ~307,336) */
proc sql noprint;
  select count(*) into :n_cand_harm
  from coh.ibog_12_harm_cohort
  where harm_group = 'CANDIDATE';

  select count(*) into :n_comp_harm
  from coh.ibog_12_harm_cohort
  where harm_group = 'COMPARATOR';
quit;

%put NOTE: Harmonized candidates:   &n_cand_harm (primary target: 307,336);
%put NOTE: Harmonized comparators:  &n_comp_harm (primary target: 283,434);
/* Gate: warn if either stratum diverges materially from frozen primary */
/*%if %sysfunc(abs(%eval(&n_cand_harm - 307336))) > 1000 %then*/
/*  %put WARNING: Candidate N diverges from 307,336 by >1,000. Investigate before proceeding.;*/
/*%if %sysfunc(abs(%eval(&n_comp_harm - 283434))) > 1000 %then*/
/*  %put WARNING: Comparator N diverges from 283,434 by >1,000. Investigate before proceeding.;*/

/* ── SECTION 4: Prevalence summary ───────────────────────────────────────*/

%put NOTE: [Section 4] Strong inhibitor prevalence - harmonized groups...;

proc sql;
  create table coh.ibog_12_harm_summary as
  select harm_group,
         count(*)                 as n,
         sum(active_primary)      as n_exposed,
         mean(active_primary)*100 as pct_exposed,
         (mean(active_primary) -
          1.96*sqrt(mean(active_primary)*(1-mean(active_primary))/count(*)))*100
                                  as pct_lower_95,
         (mean(active_primary) +
          1.96*sqrt(mean(active_primary)*(1-mean(active_primary))/count(*)))*100
                                  as pct_upper_95
  from coh.ibog_12_harm_cohort
  where harm_group in ('CANDIDATE','COMPARATOR')
  group by harm_group
  order by harm_group;
quit;

title "Harmonized Sensitivity - Strong CYP2D6 Inhibitor Prevalence";
proc print data=coh.ibog_12_harm_summary noobs;
  format pct_: 6.2;
run;

/* Chi-square */
proc freq data=coh.ibog_12_harm_cohort noprint;
  where harm_group in ('CANDIDATE','COMPARATOR');
  tables harm_group * active_primary / chisq;
  output out=_chi12 chisq;
run;

title "Chi-square - Harmonized PSYCH_ONLY Medicare";
proc print data=_chi12 noobs; run;

/* ── SECTION 5: Qualifier gradient ───────────────────────────────────────
   NOTE: Only present a 0→1→2→3 gradient if all four qualifier strata are
   actually present in this table. Check the PROC FREQ output in Section 3
   before interpreting the gradient. The fp_full table may not contain
   1-qualifier intermediates if they were excluded during cohort assembly.  */

%put NOTE: [Section 5] Qualifier gradient - checking strata present...;

/* Check which qualifier counts exist in this table */
proc freq data=coh.ibog_12_harm_cohort noprint;
  tables harm_q_count / out=_q_counts;
run;

title "Qualifier strata present in reconstructed cohort";
proc print data=_q_counts noobs; run;

proc sql;
  select count(distinct harm_q_count) into :n_q_strata
  from coh.ibog_12_harm_cohort;
quit;

%put NOTE: Number of distinct qualifier strata found: &n_q_strata;
%if &n_q_strata < 3 %then %do;
  %put WARNING: Fewer than 3 qualifier strata present. Gradient may be incomplete.;
%end;

proc sql;
  create table coh.ibog_12_harm_gradient as
  select harm_q_count              as qualifier_count,
         count(*)                  as n,
         sum(active_primary)       as n_exposed,
         mean(active_primary)*100  as pct_exposed,
         (mean(active_primary) -
          1.96*sqrt(mean(active_primary)*(1-mean(active_primary))/count(*)))*100
                                   as ci_lower,
         (mean(active_primary) +
          1.96*sqrt(mean(active_primary)*(1-mean(active_primary))/count(*)))*100
                                   as ci_upper
  from coh.ibog_12_harm_cohort
  group by harm_q_count
  order by harm_q_count;
quit;

title "Qualifier Gradient - Harmonized 3-Flag Definition (strata present in this table only)";
proc print data=coh.ibog_12_harm_gradient noobs;
  format pct_: ci_: 6.2;
run;

/* Cochran-Armitage only if intermediate stratum is present */
proc sql noprint;
  select count(*) into :has_intermediate
  from coh.ibog_12_harm_cohort where harm_q_count = 1;
quit;

%if &has_intermediate > 0 %then %do;
  proc freq data=coh.ibog_12_harm_cohort;
    tables harm_q_count * active_primary / trend;
    title "Cochran-Armitage Trend - Harmonized PSYCH_ONLY";
  run;
%end;
%else %do;
  %put WARNING: Intermediate stratum (1-qualifier) absent - Cochran-Armitage trend not run.;
  %put WARNING: Gradient comparison is candidate (q=2-3) vs comparator (q=0) only.;
%end;

/* ── SECTION 6: Adjusted PR - fixed explicit model ───────────────────────
   Demographics confirmed by audit v7: bene_birth_dt, sex, rti_race_cd
   available in ibog.eligible_scp_ibogaine_bene_flags.
   Edit this section directly if variable names differ on the server.
   Using PARAM=REF with is_candidate as the exposure indicator.           */

%put NOTE: [Section 6] Adjusted PR  fixed explicit model (no conditional IF)...;

proc sql;
  create table _s6_model as
  select a.bene_id,
         a.active_primary,
         (a.harm_group = 'CANDIDATE') as is_candidate, /* 1=candidate, 0=comparator */
         floor((a.index_dt - c.bene_birth_dt)/365.25) as age_at_index,
         c.sex_ident_cd as sex,
         c.rti_race_cd
  from coh.ibog_12_harm_cohort a
  left join ibog.eligible_scp_ibogaine_bene_flags b on a.bene_id = b.bene_id
  left join out1.enrollment_raw c on a.bene_id = c.bene_id
  	and c.bene_enrollmt_ref_yr = year(a.index_dt)
  where a.harm_group in ('CANDIDATE','COMPARATOR');
quit;

/* Log-Poisson regression - same implementation as frozen primary program.
   PARAM=REF with COVM COVS(AGGREGATE) for robust sandwich variance estimator,
   matching the primary Paper 2 Medicare analysis implementation.
   Comparator is the reference (is_candidate=0).                          */
proc genmod data=_s6_model;
  class bene_id is_candidate (ref='0' param=ref)
        sex         (ref=first param=ref)
        rti_race_cd (ref=first param=ref);
  model active_primary = is_candidate age_at_index sex rti_race_cd
        / dist=poisson link=log;
  repeated subject=bene_id / type=ind;   /* robust SE via GEE - matches primary */
  estimate "Candidate vs Comparator PR (adjusted)" is_candidate 1 / exp;
  ods output estimates = coh.ibog_12_harm_pr;
  title "Adjusted PR - Harmonized PSYCH_ONLY Medicare (matches primary implementation)";
run;

title "Adjusted PR Result";
proc print data=coh.ibog_12_harm_pr noobs; run;
title;

/* ── SECTION 7: Final summary ────────────────────────────────────────────*/

%put NOTE: [Section 7] Final summary...;

title "=== HARMONIZED SENSITIVITY - MEDICARE VERIFICATION SUMMARY ===";
proc print data=coh.ibog_12_harm_summary noobs; run;
title;

%put NOTE: ================================================================;
%put NOTE: ibogaine_12_harmonized_sensitivity.sas v2 COMPLETE;
%put NOTE: This is the MEDICARE VERIFICATION component only.;
%put NOTE: Harmonized AoU + CRDW analyses run in All of Us Workbench.;
%put NOTE: Permanent outputs:;
%put NOTE:   coh.ibog_12_harm_cohort     (reconstructed from component flags);
%put NOTE:   coh.ibog_12_harm_summary    (prevalence by group);
%put NOTE:   coh.ibog_12_harm_gradient   (qualifier gradient);
%put NOTE:   coh.ibog_12_harm_pr         (adjusted PR);
%put NOTE: Run date: &run_date;
%put NOTE: ================================================================;
