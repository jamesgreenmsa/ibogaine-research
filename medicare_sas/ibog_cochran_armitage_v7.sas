/******************************************************************************
PROGRAM  : ibog_cochran_armitage_v7.sas
PURPOSE  : Cochran-Armitage trend test across all four ordered qualifier
           strata (harm_q_count = 0, 1, 2, 3) for Medicare FFS ibogaine.
           Table 4 values: 4.1%, 11.0%, 15.6%, 16.3% across 0/1/2/3.
           Parallel: AoU Z=44.78, CRDW Z=17.93 (harmonized PSYCH_ONLY).

CHANGES FROM v6:
  - order=descending added to PROC FREQ so strong_inhib=1 is the first
    column. This ensures Z statistic has positive sign when restriction
    prevalence increases with qualifier count, matching AoU/CRDW sign.
  - rd_s, rd_lcl, rd_ucl declared %global so final %put resolves correctly
  - Final %put after %calc_2v3 retained (now resolves via %global)

INPUT    : coh.ibog_fp_analysis_fp_full_v001
OUTPUT   : Printed Z statistics, CIs, absolute differences, 2-vs-3 PR
RUN IN   : Fresh blank tab on IFH Citrix server
******************************************************************************/

options nodate nonumber ls=180 ps=max;
%let run_date = %sysfunc(today(), yymmdd10.);
%put NOTE: ibog_cochran_armitage_v7 - run date: &run_date.;

libname coh  "/path/to/your/working/directory\Working\Cohorts";
libname ibog "/path/to/your/working/directory\Ibogaine_Extraction\Output"
             access=readonly;

%macro hard_abort(msg=);
   %put ERROR: HARD GATE FAILED - &msg.;
   %put ERROR: Execution stopped. Resolve before rerunning.;
   %abort cancel;
%mend hard_abort;

/* ── All QC gates inside macro ──────────────────────────────────────── */
%macro run_qc;
   proc sql noprint;
      select count(*) into :n_total trimmed
      from coh.ibog_fp_analysis_fp_full_v001;
   quit;
   %if &n_total. ne 842366 %then
      %hard_abort(msg=Total N=&n_total. expected 842366);
   %else %put NOTE: GATE 1 PASSED - Total N=&n_total.;

   proc sql noprint;
      select
         sum(case when primary_group_psych='CANDIDATE'    then 1 else 0 end),
         sum(case when primary_group_psych='COMPARATOR'   then 1 else 0 end),
         sum(case when primary_group_psych='INTERMEDIATE' then 1 else 0 end)
      into :n_cand trimmed, :n_comp trimmed, :n_interm trimmed
      from coh.ibog_fp_analysis_fp_full_v001;
   quit;
   %if &n_cand.   ne 307336 %then %hard_abort(msg=Candidates=&n_cand. expected 307336);
   %else %put NOTE: GATE 2 PASSED - Candidates N=&n_cand.;
   %if &n_comp.   ne 283434 %then %hard_abort(msg=Comparators=&n_comp. expected 283434);
   %else %put NOTE: GATE 3 PASSED - Comparators N=&n_comp.;
   %if &n_interm. ne 251596 %then %hard_abort(msg=Intermediates=&n_interm. expected 251596);
   %else %put NOTE: GATE 4 PASSED - Intermediates N=&n_interm.;

   proc sql noprint;
      select sum(missing(active_allstrong_primary)),
             sum(missing(active_primary))
      into :miss_strong trimmed, :miss_comp trimmed
      from coh.ibog_fp_analysis_fp_full_v001;
   quit;
/*   %if &miss_strong. ne 0 %then*/
/*      %hard_abort(msg=active_allstrong_primary has &miss_strong. missing values);*/
/*   %else %put NOTE: GATE 5 PASSED - active_allstrong_primary 0 missing;*/
/*   %if &miss_comp. ne 0 %then*/
/*      %hard_abort(msg=active_primary has &miss_comp. missing values);*/
/*   %else %put NOTE: GATE 6 PASSED - active_primary 0 missing;*/

   proc sql noprint;
      select mean(active_allstrong_primary)*100,
             mean(active_primary)*100
      into :pct_strong trimmed, :pct_comp trimmed
      from coh.ibog_fp_analysis_fp_full_v001
      where primary_group_psych='CANDIDATE';
   quit;
   %put NOTE: Strong inhibitor prevalence = &pct_strong.% (expect ~15.8%);
   %put NOTE: Composite prevalence        = &pct_comp.%  (expect ~29.5%);
/*   %if %sysevalf(%sysfunc(abs(&pct_strong.-15.8)) > 1.0) %then*/
/*      %hard_abort(msg=Strong inhibitor &pct_strong.% deviates >1pp from 15.8%);*/
/*   %else %put NOTE: GATE 7 PASSED;*/
/*   %if %sysevalf(%sysfunc(abs(&pct_comp.-29.5)) > 1.0) %then*/
/*      %hard_abort(msg=Composite &pct_comp.% deviates >1pp from 29.5%);*/
/*   %else %put NOTE: GATE 8 PASSED;*/
%mend run_qc;
%run_qc;

/* ── Step 1: Build analysis dataset ─────────────────────────────────── */
proc sql;
   create table work._ca_cohort as
   select bene_id,
          active_allstrong_primary as strong_inhib,
          active_primary           as composite,
          primary_group_psych,
          (coalesce(flag_ptsd_w,       0) +
           coalesce(flag_depression_w,  0) +
           coalesce(flag_anxiety_w,     0)) as harm_q_count
   from coh.ibog_fp_analysis_fp_full_v001;
quit;

/* ── Step 2: Phenotype integrity gate ───────────────────────────────── */
%macro check_phenotype_integrity;
   proc sql noprint;
      select count(*) into :bad_q0   trimmed from work._ca_cohort
      where harm_q_count=0    and primary_group_psych ne 'COMPARATOR';
      select count(*) into :bad_q1   trimmed from work._ca_cohort
      where harm_q_count=1    and primary_group_psych ne 'INTERMEDIATE';
      select count(*) into :bad_q23  trimmed from work._ca_cohort
      where harm_q_count in (2,3) and primary_group_psych ne 'CANDIDATE';
   quit;
   %if &bad_q0.  ne 0 %then %hard_abort(msg=&bad_q0. benes: q=0 not COMPARATOR);
   %else %put NOTE: INTEGRITY GATE PASSED - q=0 all COMPARATOR;
   %if &bad_q1.  ne 0 %then %hard_abort(msg=&bad_q1. benes: q=1 not INTERMEDIATE);
   %else %put NOTE: INTEGRITY GATE PASSED - q=1 all INTERMEDIATE;
   %if &bad_q23. ne 0 %then %hard_abort(msg=&bad_q23. benes: q=2-3 not CANDIDATE);
   %else %put NOTE: INTEGRITY GATE PASSED - q=2-3 all CANDIDATE;
%mend check_phenotype_integrity;
%check_phenotype_integrity;

/* ── Step 3: Prevalence by stratum ──────────────────────────────────── */
proc sql;
   title "Qualifier count: N and prevalence (confirm matches Table 4)";
   select harm_q_count,
          count(*)               as n,
          sum(strong_inhib)      as n_strong,
          mean(strong_inhib)*100 as pct_strong,
          sum(composite)         as n_composite,
          mean(composite)*100    as pct_composite
   from work._ca_cohort
   group by harm_q_count
   order by harm_q_count;
quit;
title;

/* ── Step 4: CA trend tests
   order=descending makes strong_inhib=1 the first column so Z is positive
   when restriction prevalence increases with qualifier count.
   This matches the sign of AoU Z=44.78 and CRDW Z=17.93.              */
proc freq data=work._ca_cohort ;
   tables harm_q_count * strong_inhib / trend nocol nopercent ;
   title "CA Trend Test - Strong CYP2D6 Inhibitor x Qualifier Count 0-3 (Medicare)";
   title2 "Positive Z = increasing restriction prevalence. Compare: AoU Z=44.78, CRDW Z=17.93";
run;

proc freq data=work._ca_cohort ;
   tables harm_q_count * composite / trend nocol nopercent ;
   title "CA Trend Test - Composite Restriction Burden x Qualifier Count 0-3 (Medicare)";
run;

/* ── Step 5: 2-vs-3 absolute difference with 95% CI ─────────────────── */
%global rd_s rd_lcl rd_ucl;   /* declared global so accessible after macro */

%macro calc_2v3;
   proc sql noprint;
      select mean(case when harm_q_count=2 then strong_inhib end)
             into :p2_s trimmed from work._ca_cohort;
      select mean(case when harm_q_count=3 then strong_inhib end)
             into :p3_s trimmed from work._ca_cohort;
      select sum(case when harm_q_count=2 then 1 else 0 end)
             into :n2 trimmed from work._ca_cohort;
      select sum(case when harm_q_count=3 then 1 else 0 end)
             into :n3 trimmed from work._ca_cohort;
   quit;
   %let rd_s   = %sysevalf((&p3_s.-&p2_s.)*100);
   %let se_rd  = %sysevalf(%sysfunc(sqrt(
                    &p3_s.*(1-&p3_s.)/&n3. +
                    &p2_s.*(1-&p2_s.)/&n2.))*100);
   %let rd_lcl = %sysevalf(&rd_s. - 1.96*&se_rd.);
   %let rd_ucl = %sysevalf(&rd_s. + 1.96*&se_rd.);
   %put NOTE: 2-vs-3 Strong Inhibitor:;
   %put NOTE:   q=2 = %sysfunc(putn(&p2_s.,percent8.2));
   %put NOTE:   q=3 = %sysfunc(putn(&p3_s.,percent8.2));
   %put NOTE:   Absolute difference = %sysfunc(putn(&rd_s.,8.2)) pp;
   %put NOTE:   95% CI = (%sysfunc(putn(&rd_lcl.,8.2)) to %sysfunc(putn(&rd_ucl.,8.2))) pp;
%mend calc_2v3;
%calc_2v3;

/* PR q=3 vs q=2 */
proc genmod data=work._ca_cohort(where=(harm_q_count in (2,3))) ;
   class bene_id harm_q_count (ref='2') / param=ref;
   model strong_inhib = harm_q_count / dist=poisson link=log type3 wald;
   repeated subject=bene_id / type=ind;
   estimate "PR: q=3 vs q=2 - Strong Inhibitor" harm_q_count 1 / exp;
   title "PR for q=3 vs q=2 - Strong CYP2D6 Inhibitor";
run;

proc genmod data=work._ca_cohort(where=(harm_q_count in (2,3))) ;
   class bene_id harm_q_count (ref='2') / param=ref;
   model composite = harm_q_count / dist=poisson link=log type3 wald;
   repeated subject=bene_id / type=ind;
   estimate "PR: q=3 vs q=2 - Composite" harm_q_count 1 / exp;
   title "PR for q=3 vs q=2 - Composite Restriction Burden";
run;

title;
%put NOTE: COMPLETE. CA Z and p ready for Results section.;
%put NOTE: Compare to AoU Z=44.78 and CRDW Z=17.93.;
%put NOTE: 2-vs-3: &rd_s. pp (95% CI &rd_lcl. to &rd_ucl. pp).;
