/******************************************************************************
  PROGRAM  : ibogaine_08_supplemental_analysis.sas
  VERSION  : v1.0 (2026-08-28)
  PURPOSE  : Three supplemental analyses that can run immediately against
             existing COH library output tables without additional data pulls.

             Analysis A: Exact composite event count
             Counts unique beneficiaries with at least one of VT, VF, or
             cardiac arrest in the post-index feasibility window.
             Resolves the approximate composite N in the feasibility document.

             Analysis B: Qualifier-count gradient table for manuscript
             Formats the qualifier-0 through qualifier-3 exposure gradient
             with exact Ns and confidence intervals, ready for Table 1.

             Analysis C: Age subgroup breakdown for Medicare candidates
             Formal tabulation of under-65 vs 65-plus split with demographic
             breakdown, supporting the VA-relevance argument in the manuscript.

  DEPENDS  : coh.ibog_07a_patientlevel  (from ibogaine_07a_cardiac_feasibility)
             coh.ibog_fp_analysis_fp_full_v001 (from 99c run)
             coh.ibog_fp_table1_fp_full_v001  (from 99c run)

  OUTPUT   : coh.ibog_08a_composite_exact  -- exact composite N by group
             coh.ibog_08b_gradient_ci      -- gradient with 95% Wald CIs
             coh.ibog_08c_age_subgroup     -- age subgroup breakdown

  PI       : James Green (jg1984@shp.rutgers.edu)
******************************************************************************/

%put NOTE: ibogaine_08_supplemental_analysis.sas (v1.0) starting...;

/* -------------------------------------------------------------------------
   Set the path to your pipeline setup file (00_ibogaine_setup.sas) below.
   That file assigns all library names via a single proj_root macro variable.
   ------------------------------------------------------------------------- */
/* %include "/path/to/j_code/00_ibogaine_setup.sas"; */

/*--- PREFLIGHT -----------------------------------------------------------*/
%macro preflight_08;
  %local _abort; %let _abort = 0;
  %macro _chk(lib, mem);
    %local _n;
    proc sql noprint;
      select count(*) into :_n trimmed
      from dictionary.tables
      where upcase(libname) = upcase("&lib.")
        and upcase(memname) = upcase("&mem.");
    quit;
    %if &_n = 0 %then %do;
      %put ERROR: [preflight_08] &lib..&mem. not found.;
      %let _abort = 1;
    %end;
  %mend;

  %_chk(COH, IBOG_07A_PATIENTLEVEL);
  %_chk(COH, IBOG_FP_ANALYSIS_FP_FULL_V001);
  %_chk(COH, IBOG_FP_TABLE1_FP_FULL_V001);

  %if &_abort = 1 %then %abort cancel;
  %put NOTE: [preflight_08] All preflight checks passed.;
%mend preflight_08;
%preflight_08;

/******************************************************************************
  ANALYSIS A: EXACT COMPOSITE EVENT COUNT
  Count unique beneficiaries with >=1 VT/VF/cardiac arrest event in the
  post-index feasibility window. Resolves the approximate ~36,000 in the
  feasibility document and provides overlap QC across the three components.
******************************************************************************/
%put NOTE: [08a] Starting exact composite event count...;

proc sql;
  create table coh.ibog_08a_composite_exact as
  select
    cohort_group,
    count(*)                                as n_total,
    sum(ev_vt)                             as n_vt,
    sum(ev_vf)                             as n_vf,
    sum(ev_composite)                      as n_composite_exact,
    /* Overlap counts for QC */
    sum(case when ev_vt=1 and ev_vf=1
             and ev_cardiac_arrest=0 then 1 else 0 end) as n_vt_and_vf_only,
    sum(case when ev_vt=1 and ev_cardiac_arrest=1
             and ev_vf=0 then 1 else 0 end) as n_vt_and_arrest_only,
    sum(case when ev_vf=1 and ev_cardiac_arrest=1
             and ev_vt=0 then 1 else 0 end) as n_vf_and_arrest_only,
    sum(case when ev_vt=1 and ev_vf=1
             and ev_cardiac_arrest=1 then 1 else 0 end) as n_all_three,
    sum(ev_cardiac_arrest)                 as n_arrest,
    /* Composite as % of group */
    calculated n_composite_exact /
      calculated n_total * 100             as pct_composite
  from coh.ibog_07a_patientlevel
  group by cohort_group;
quit;

/* Also get the all-groups combined row */
proc sql;
  insert into coh.ibog_08a_composite_exact
  select
    'TOTAL'                                as cohort_group,
    count(*)                               as n_total,
    sum(ev_vt)                             as n_vt,
    sum(ev_vf)                             as n_vf,
    sum(ev_composite)                      as n_composite_exact,
    sum(case when ev_vt=1 and ev_vf=1
             and ev_cardiac_arrest=0 then 1 else 0 end) as n_vt_and_vf_only,
    sum(case when ev_vt=1 and ev_cardiac_arrest=1
             and ev_vf=0 then 1 else 0 end) as n_vt_and_arrest_only,
    sum(case when ev_vf=1 and ev_cardiac_arrest=1
             and ev_vt=0 then 1 else 0 end) as n_vf_and_arrest_only,
    sum(case when ev_vt=1 and ev_vf=1
             and ev_cardiac_arrest=1 then 1 else 0 end) as n_all_three,
    sum(ev_cardiac_arrest)                 as n_arrest,
    sum(ev_composite) / count(*) * 100     as pct_composite
  from coh.ibog_07a_patientlevel;
quit;

title "Analysis A: Exact Composite Event Count (VT + VF + Cardiac Arrest)";
title2 "Blinded - no inhibitor-exposure stratification";
proc print data=coh.ibog_08a_composite_exact noobs label;
  var cohort_group n_total n_vt n_vf n_arrest n_composite_exact pct_composite
      n_vt_and_vf_only n_vt_and_arrest_only n_vf_and_arrest_only n_all_three;
  format pct_composite 6.2;
run;
title; title2;

%put NOTE: [08a] Exact composite event count complete. Output: coh.ibog_08a_composite_exact;

/******************************************************************************
  ANALYSIS B: QUALIFIER-COUNT GRADIENT WITH CONFIDENCE INTERVALS
  Format the qualifier-0 through qualifier-3 exposure gradient from 99c
  output with exact Ns, exposed counts, crude prevalence, and 95% Wald CIs.
  Ready for manuscript Table 1.
******************************************************************************/
%put NOTE: [08b] Starting qualifier gradient with CIs...;

/* Pull qualifier-level counts from the first-pass analysis table */
proc sql;
  create table _08b_base as
  select
    n_qualifiers,
    sum(n_benes)            as n_total,
    sum(n_active_strong)    as n_exposed,
    sum(n_active_strong) /
      sum(n_benes)          as prevalence,
    /* 95% Wald CI on proportion */
    (sum(n_active_strong) / sum(n_benes))
      - 1.96 * sqrt( (sum(n_active_strong)/sum(n_benes)) *
                     (1 - sum(n_active_strong)/sum(n_benes)) /
                     sum(n_benes))        as ci_lower,
    (sum(n_active_strong) / sum(n_benes))
      + 1.96 * sqrt( (sum(n_active_strong)/sum(n_benes)) *
                     (1 - sum(n_active_strong)/sum(n_benes)) /
                     sum(n_benes))        as ci_upper
  from coh.ibog_fp_analysis_fp_full_v001
  where primary_group_psych in ('CANDIDATE', 'COMPARATOR')
    and n_qualifiers in (0, 1, 2, 3)
  group by n_qualifiers
  order by n_qualifiers;
quit;

data coh.ibog_08b_gradient_ci;
  set _08b_base;
  label
    n_qualifiers = "Number of qualifying criteria"
    n_total      = "N in qualifier stratum"
    n_exposed    = "N with active strong CYP2D6 inhibitor"
    prevalence   = "Crude prevalence (proportion)"
    ci_lower     = "95% Wald CI lower bound"
    ci_upper     = "95% Wald CI upper bound";
  pct        = prevalence * 100;
  pct_lower  = ci_lower  * 100;
  pct_upper  = ci_upper  * 100;
  label pct = "Prevalence (%)" pct_lower = "95% CI lower (%)" pct_upper = "95% CI upper (%)";
  drop prevalence ci_lower ci_upper;
run;

title "Analysis B: Qualifier-Count Gradient with 95% Wald Confidence Intervals";
title2 "Active strong CYP2D6 inhibitor at index by number of qualifying criteria";
proc print data=coh.ibog_08b_gradient_ci noobs label;
  var n_qualifiers n_total n_exposed pct pct_lower pct_upper;
  format pct pct_lower pct_upper 6.2;
run;
title; title2;

%put NOTE: [08b] Gradient with CIs complete. Output: coh.ibog_08b_gradient_ci;

/******************************************************************************
  ANALYSIS C: AGE SUBGROUP BREAKDOWN FOR MEDICARE CANDIDATES
  Formal tabulation of under-65 vs 65-plus split among candidates, with
  CYP2D6 inhibitor exposure rates by age group.
  Supports the VA-relevance argument (58.4% of candidates under 65).
******************************************************************************/
%put NOTE: [08c] Starting age subgroup breakdown...;

/* The main analysis table should have age_at_index or bene_age.
   Check available age variable in the 99c output */
proc contents data=coh.ibog_fp_table1_fp_full_v001 varnum;
  ods select variables;
run;

/* Build age subgroup table from the first-pass analysis + Table1 */
proc sql;
  create table _08c_base as
  select
    a.bene_id,
    a.primary_group_psych,
    a.active_strong_at_index,
    t.age_at_index,
    case when t.age_at_index < 65 then 'Under 65 (SSDI-eligible)'
         else '65 and older'
    end as age_group length = 30,
    case when t.age_at_index < 65 then 0 else 1 end as age_ge65
  from coh.ibog_fp_analysis_fp_full_v001 a
  left join coh.ibog_fp_table1_fp_full_v001 t
    on a.bene_id = t.bene_id
  where a.primary_group_psych = 'CANDIDATE';
quit;

proc sql;
  create table coh.ibog_08c_age_subgroup as
  select
    age_group,
    count(*)                                   as n_total,
    sum(active_strong_at_index)                as n_exposed,
    sum(active_strong_at_index) /
      count(*) * 100                           as pct_exposed,
    min(age_at_index)                          as age_min,
    mean(age_at_index)                         as age_mean,
    max(age_at_index)                          as age_max,
    calculated n_total /
      (select count(*) from _08c_base) * 100   as pct_of_candidates
  from _08c_base
  group by age_group
  order by age_ge65;
quit;

title "Analysis C: Age Subgroup Breakdown Among Medicare Ibogaine Candidates";
title2 "CYP2D6 inhibitor exposure rates by age group (under 65 = SSDI-eligible)";
proc print data=coh.ibog_08c_age_subgroup noobs label;
  var age_group n_total pct_of_candidates n_exposed pct_exposed
      age_min age_mean age_max;
  format pct_exposed pct_of_candidates age_mean 6.2;
run;
title; title2;

%put NOTE: [08c] Age subgroup breakdown complete. Output: coh.ibog_08c_age_subgroup;

/*--- CLEANUP -----------------------------------------------------------*/
proc datasets library=work nolist;
  delete _08b_base _08c_base;
quit;

%put NOTE: ibogaine_08_supplemental_analysis.sas (v1.0) COMPLETE.;
%put NOTE: Outputs: coh.ibog_08a_composite_exact;
%put NOTE:          coh.ibog_08b_gradient_ci;
%put NOTE:          coh.ibog_08c_age_subgroup;
%put NOTE: All three analyses are exposure-blind and do not examine;
%put NOTE: inhibitor-stratified outcome comparisons.;
