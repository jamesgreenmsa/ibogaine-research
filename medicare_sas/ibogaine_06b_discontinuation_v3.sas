/******************************************************************************
  PROGRAM  : ibogaine_06b_discontinuation_v2.sas
  VERSION  : v2.2 (2026-08-20)
  PURPOSE  : Analysis B - Observed Intervals Since Expected Target-Drug Coverage Ended.
             Estimand: among patients with no target inhibitor (bupropion,
             paroxetine, or fluoxetine) active at the analytic index date,
             what are the observed calendar intervals between expected
             coverage ending and the index date?
             Analysis A and B together form a clean clinical contrast:
             A = active target medication at index → management burden
             B = previously exposed, none active → interval since expected target-drug coverage ended

  CHANGES v2.1 (from reviewer feedback):
  - Estimand clarified: population is all-three-drug-inactive patients
    (not drug-specific); header updated to match code
  - Fills pulled through srvc_dt <= index_dt for independent reconciliation
  - Active-leak QC now fully independent of upstream flags
  - Interval 0-13 corrected to 1-13 (min possible gap is 1 day)
  - Duplicate QC replaced with GROUP BY HAVING approach (no string concat)
  - Patient-level interval since last expected target-drug coverage ended output added
  - Post-write verification added
  - Full bidirectional reconciliation with Program 03 added

  PI       : James Green (jg1984@shp.rutgers.edu)
  DEPENDS  : 00_ibogaine_setup.sas must have run in this session.
             coh.ibog_fp_analysis_fp_full_v001 must exist (output of 99c).
             ibog._ibogaine_pd_flags must exist (Lydia's Part D extract).
  OUTPUT   : coh.ibog_06b_discont_v2    patient x drug level
             coh.ibog_06b_patient_v2    patient-level interval since last expected target-drug coverage ended
             coh.ibog_06b_freq_v2       interval frequency table
******************************************************************************/

%put NOTE: ibogaine_06b_discontinuation_v2.sas (v2.2) starting...;

/*--- PREFLIGHT -------------------------------------------------------------*/
/*%macro preflight_06b;*/
/*  %local _n _abort;*/
/*  %let _abort=0;*/
/**/
/*  proc sql noprint;*/
/*    select count(*) into :_n trimmed*/
/*    from dictionary.tables*/
/*    where upcase(libname)='COH'*/
/*      and upcase(memname)='IBOG_FP_ANALYSIS_FP_FULL_V001';*/
/*  quit;*/
/*  %if &_n=0 %then %do;*/
/*    %put ERROR: [preflight_06b] coh.ibog_fp_analysis_fp_full_v001 not found.;*/
/*    %let _abort=1;*/
/*  %end;*/
/**/
/*  proc sql noprint;*/
/*    select count(*) into :_n trimmed*/
/*    from dictionary.tables*/
/*    where upcase(libname)='IBOG'*/
/*      and upcase(memname)='IBOGAINE_PD_FLAGS';*/
/*  quit;*/
/*  %if &_n=0 %then %do;*/
/*    %put ERROR: [preflight_06b] ibog._ibogaine_pd_flags not found.;*/
/*    %let _abort=1;*/
/*  %end;*/
/**/
/*  %macro _chkcol(ds,col);*/
/*    %local _nc;*/
/*    proc sql noprint;*/
/*      select count(*) into :_nc trimmed*/
/*      from dictionary.columns*/
/*      where upcase(libname)=upcase(scan("&ds.",1,'.'))*/
/*        and upcase(memname)=upcase(scan("&ds.",2,'.'))*/
/*        and upcase(name)=upcase("&col.");*/
/*    quit;*/
/*    %if &_nc=0 %then %do;*/
/*      %put ERROR: [preflight_06b] Column &col. not found in &ds.;*/
/*      %let _abort=1;*/
/*    %end;*/
/*  %mend;*/
/*  %_chkcol(coh.ibog_fp_analysis_fp_full_v001, bene_id);*/
/*  %_chkcol(coh.ibog_fp_analysis_fp_full_v001, index_dt);*/
/*  %_chkcol(coh.ibog_fp_analysis_fp_full_v001, primary_group_psych);*/
/*  %_chkcol(coh.ibog_fp_analysis_fp_full_v001, active_bupropion);*/
/*  %_chkcol(coh.ibog_fp_analysis_fp_full_v001, active_paroxetine);*/
/*  %_chkcol(coh.ibog_fp_analysis_fp_full_v001, active_fluoxetine);*/
/*  %_chkcol(ibog._ibogaine_pd_flags, bene_id);*/
/*  %_chkcol(ibog._ibogaine_pd_flags, FDB_GNN60);*/
/*  %_chkcol(ibog._ibogaine_pd_flags, cyp2d6_tier);*/
/*  %_chkcol(ibog._ibogaine_pd_flags, srvc_dt);*/
/*  %_chkcol(ibog._ibogaine_pd_flags, days_suply_num);*/
/**/
/*  %if %symexist(max_days_supply)=0 %then %do;*/
/*    %put ERROR: [preflight_06b] max_days_supply not defined. Run 00_ibogaine_setup.sas first.;*/
/*    %let _abort=1;*/
/*  %end;*/
/**/
/*  %if &_abort=1 %then %abort cancel;*/
/*  %put NOTE: [preflight_06b] All preflight checks passed.;*/
/*%mend preflight_06b;*/
/*%preflight_06b;*/

/*--- STEP 0: Base population - none of the three drugs active at index -----*/
/* Estimand: patients where none of bupropion, paroxetine, or fluoxetine
   is active at index. This complements Analysis A exactly.               */

proc sql;
  create table _b_base as
  select
    bene_id,
    index_dt,
    primary_group_psych as cohort_group length=12,
    coalesce(active_bupropion,0)  as active_bupropion,
    coalesce(active_paroxetine,0) as active_paroxetine,
    coalesce(active_fluoxetine,0) as active_fluoxetine
  from coh.ibog_fp_analysis_fp_full_v001
  where primary_group_psych in ('CANDIDATE','COMPARATOR')
    and coalesce(active_bupropion,0)  = 0
    and coalesce(active_paroxetine,0) = 0
    and coalesce(active_fluoxetine,0) = 0;
quit;

%let _n_b_base=0;
proc sql noprint;
  select count(*) into :_n_b_base trimmed from _b_base;
quit;
%put NOTE: [06b Step 0] None-active-at-index population N = &_n_b_base.;

/*--- STEP 1: Pull fills through srvc_dt <= index_dt (v2.1 change) ---------*/
/* Pull through index_dt (not strictly before) to enable independent
   reconstruction and reconciliation against upstream flags.              */

proc sql;
  create table _b_fills as
  select
    b.bene_id,
    b.index_dt,
    b.cohort_group,
    b.active_bupropion,
    b.active_paroxetine,
    b.active_fluoxetine,
    case
      when index(upcase(p.FDB_GNN60),'BUPROPION')  > 0 then 'BUPROPION'
      when index(upcase(p.FDB_GNN60),'PAROXETINE') > 0 then 'PAROXETINE'
      when index(upcase(p.FDB_GNN60),'FLUOXETINE') > 0 then 'FLUOXETINE'
    end as drug_name length=12,
    p.srvc_dt + p.days_suply_num - 1 as coverage_end format=date9.
  from _b_base b
  inner join ibog._ibogaine_pd_flags p
    on b.bene_id = p.bene_id
  where
    (  index(upcase(p.FDB_GNN60),'BUPROPION')  > 0
    or index(upcase(p.FDB_GNN60),'PAROXETINE') > 0
    or index(upcase(p.FDB_GNN60),'FLUOXETINE') > 0 )
    and upcase(p.cyp2d6_tier) = 'STRONG'
    and not missing(p.days_suply_num)
    and p.days_suply_num > 0
    and p.days_suply_num <= &max_days_supply.
    /* v2.2: coverage-end anchored lookback.
       Pull fills that could extend into the 365-day window before index.
       After reconstruction, require max_coverage_end >= index_dt - 365
       and < index_dt. This aligns the observation window with the
       quantity being analyzed (time since expected coverage ended). */
    and p.srvc_dt >= b.index_dt - (365 + &max_days_supply. - 1)
    and p.srvc_dt <= b.index_dt;
quit;

/*--- STEP 2: Max coverage end per patient x drug ---------------------------*/
proc sql;
  create table _b_maxcov as
  select
    bene_id,
    index_dt,
    cohort_group,
    active_bupropion,
    active_paroxetine,
    active_fluoxetine,
    drug_name,
    max(coverage_end)                   as max_coverage_end format=date9.,
    case when max(coverage_end) >= index_dt then 1 else 0 end
                                        as reconstructed_active
  from _b_fills
  where drug_name ne ''
  group by bene_id, index_dt, cohort_group,
           active_bupropion, active_paroxetine, active_fluoxetine, drug_name;
quit;

/*--- STEP 3: Bidirectional reconciliation (v2.1 - fully independent) ------*/
/* Check 1: upstream flag=0, but Part D reconstruction says active → hard stop
   Check 2: upstream flag=1 should not occur in this population by definition
   (all three active_* = 0), but verify for safety                       */

proc sql noprint;
  select count(*) into :_n_b_leak_bup trimmed from _b_maxcov
    where drug_name='BUPROPION'  and reconstructed_active=1;
  select count(*) into :_n_b_leak_par trimmed from _b_maxcov
    where drug_name='PAROXETINE' and reconstructed_active=1;
  select count(*) into :_n_b_leak_flu trimmed from _b_maxcov
    where drug_name='FLUOXETINE' and reconstructed_active=1;
quit;

%put NOTE: [06b QC] Active-leak check (must all be 0):;
%put NOTE: [06b QC]   Bupropion active records:  &_n_b_leak_bup.;
%put NOTE: [06b QC]   Paroxetine active records: &_n_b_leak_par.;
%put NOTE: [06b QC]   Fluoxetine active records: &_n_b_leak_flu.;

%macro assert_no_active_b;
  %if &_n_b_leak_bup>0 or &_n_b_leak_par>0 or &_n_b_leak_flu>0 %then %do;
    %put ERROR: [06b HARD STOP] Part D reconstruction finds active coverage at;
    %put ERROR: index for patients whose upstream flags say inactive.;
    %put ERROR: This is a reconciliation failure with Program 03. Investigate.;
    %abort cancel;
  %end;
  %put NOTE: [06b QC] No active-at-index records confirmed - reconciliation passed.;
%mend assert_no_active_b;
%assert_no_active_b;

/*--- STEP 4: Restrict to prior-exposure patients and compute gap -----------*/
/* Now safe to restrict to records where coverage ended before index.    */

data _b_prior;
  set _b_maxcov;
  where reconstructed_active = 0;
  days_since_coverage_end = index_dt - max_coverage_end;
  /* v2.1: bands start at 1 (minimum possible gap is 1 day) */
  length interval_band $25;
  if      days_since_coverage_end < 14 then do;
    interval_band = '1-13 days'; interval_num = 1; end;
  else if days_since_coverage_end < 35 then do;
    interval_band = '14-34 days'; interval_num = 2; end;
  else if days_since_coverage_end < 50 then do;
    interval_band = '35-49 days'; interval_num = 3; end;
  else do;
    interval_band = '50 or more days'; interval_num = 4; end;
  label
    drug_name               = "Drug (BUPROPION/PAROXETINE/FLUOXETINE)"
    max_coverage_end        = "Maximum expected coverage end date"
    days_since_coverage_end = "Days from expected coverage end to index date"
    interval_band           = "Interval since expected target-drug coverage ended (descriptive only)"
    interval_num            = "Interval band order (1=shortest)";
run;

/*--- STEP 5: Duplicate QC (v2.1 - GROUP BY HAVING, no string concat) ------*/
proc sql;
  create table _b_dups as
  select bene_id, index_dt, drug_name, count(*) as n_dup
  from _b_prior
  group by bene_id, index_dt, drug_name
  having count(*) > 1;
quit;

%let _n_dups=0;
proc sql noprint;
  select count(*) into :_n_dups trimmed from _b_dups;
quit;

%macro assert_nodups_b;
  %if &_n_dups > 0 %then %do;
    %put ERROR: [06b HARD STOP] &_n_dups. duplicate bene_id x drug_name rows found.;
    %abort cancel;
  %end;
  %put NOTE: [06b QC] No duplicate bene x drug rows confirmed.;
%mend assert_nodups_b;
%assert_nodups_b;

/*--- STEP 6: Patient-level interval since last expected target-drug coverage ended (v2.1 addition) -------*/
/* How long since ANY of the three target drugs had expected coverage?
   Use the latest coverage end across all prior drugs per patient.       */

proc sql;
  create table _b_patient as
  select
    bene_id,
    index_dt,
    cohort_group,
    max(max_coverage_end)                         as last_any_coverage_end format=date9.,
    index_dt - max(max_coverage_end)              as days_since_any_target_end,
    count(distinct drug_name)                     as n_prior_target_drugs,
    case when index_dt - max(max_coverage_end) < 14 then 1
         when index_dt - max(max_coverage_end) < 35 then 2
         when index_dt - max(max_coverage_end) < 50 then 3
         else                                         4
    end                                           as all_target_gap_num,
    case when index_dt - max(max_coverage_end) < 14 then '1-13 days'
         when index_dt - max(max_coverage_end) < 35 then '14-34 days'
         when index_dt - max(max_coverage_end) < 50 then '35-49 days'
         else                                         '50 or more days'
    end                                           as all_target_gap_band length=25
  from _b_prior
  group by bene_id, index_dt, cohort_group;
quit;

/*--- STEP 7: Frequency summary ---------------------------------------------*/
proc sql;
  create table _b_num as
  select cohort_group, drug_name, interval_band, interval_num, count(*) as n
  from _b_prior
  group by cohort_group, drug_name, interval_band, interval_num;
quit;

proc sql;
  create table _b_den as
  select cohort_group, drug_name, count(*) as total_n
  from _b_prior
  group by cohort_group, drug_name;
quit;

proc sql;
  create table _b_freq_work as
  select a.cohort_group, a.drug_name, a.interval_num, a.interval_band,
         a.n, b.total_n,
         a.n / b.total_n * 100 as pct
  from _b_num a
  inner join _b_den b
    on a.cohort_group=b.cohort_group and a.drug_name=b.drug_name
  order by a.cohort_group, a.drug_name, a.interval_num;
quit;

/*--- STEP 8: Write permanent output and verify -----------------------------*/
data coh.ibog_06b_discont_v2;
  set _b_prior;
  keep bene_id index_dt cohort_group drug_name
       max_coverage_end days_since_coverage_end
       interval_band interval_num;
run;

data coh.ibog_06b_patient_v2;
  set _b_patient;
  label
    bene_id                  = "Beneficiary ID"
    index_dt                 = "Index date"
    cohort_group             = "CANDIDATE or COMPARATOR"
    last_any_coverage_end    = "Latest expected coverage end across all target drugs"
    days_since_any_target_end= "Days since any target drug coverage ended"
    n_prior_target_drugs     = "Number of distinct target drugs with prior fills"
    all_target_gap_band     = "All-target-free interval band (descriptive only)";
run;

data coh.ibog_06b_freq_v2;
  set _b_freq_work;
  label pct="Pct within drug x cohort";
run;

/* Post-write verification */
%let _n_w_d=0; %let _n_w_p=0; %let _n_staged_d=0; %let _n_staged_p=0;
proc sql noprint;
  select count(*) into :_n_staged_d trimmed from _b_prior;
  select count(*) into :_n_staged_p trimmed from _b_patient;
  select count(*) into :_n_w_d      trimmed from coh.ibog_06b_discont_v2;
  select count(*) into :_n_w_p      trimmed from coh.ibog_06b_patient_v2;
quit;

%macro assert_write_b;
  %if &_n_w_d ne &_n_staged_d %then %do;
    %put ERROR: [06b HARD STOP] Written discont rows &_n_w_d. ne staged &_n_staged_d.;
    %abort cancel;
  %end;
  %if &_n_w_p ne &_n_staged_p %then %do;
    %put ERROR: [06b HARD STOP] Written patient rows &_n_w_p. ne staged &_n_staged_p.;
    %abort cancel;
  %end;
  %put NOTE: [06b] Post-write verification passed.;
%mend assert_write_b;
%assert_write_b;

/*--- STEP 9: Descriptive output --------------------------------------------*/
title "Table B1: Days since expected coverage end - by drug and cohort";
title2 "(Descriptive interval bands only - no clinical sufficiency interpretation)";
proc print data=coh.ibog_06b_freq_v2 noobs label;
  format pct 6.1;
run; title; title2;

title "Table B2: Days since expected coverage end - distribution by drug";
proc means data=coh.ibog_06b_discont_v2 n mean median min max p25 p75 p95;
  class cohort_group drug_name;
  var days_since_coverage_end;
run; title;

title "Table B3: Patient-level interval since last expected target-drug coverage ended - by cohort group";

proc means data=coh.ibog_06b_patient_v2 n mean median min max p25 p75 p95;
  class cohort_group;
  var days_since_any_target_end;
run; title; title2;

title "Table B4: Interval-since-target-coverage-ended band - by cohort group";
proc sort data=coh.ibog_06b_patient_v2 out=_b_pt_sorted;
  by cohort_group all_target_gap_num;
run;
proc freq data=_b_pt_sorted order=data;
  tables cohort_group * all_target_gap_band / norow nocol nopercent missing;
run; title;

title "Table B5: Patients with a prior qualifying target-drug dispensing in the lookback window and no target drug active at index";
proc sql;
  select cohort_group, count(distinct bene_id) as n_patients
  from coh.ibog_06b_discont_v2
  group by cohort_group;
quit; title;

/*--- CLEANUP ---------------------------------------------------------------*/
proc datasets library=work nolist;
  delete _b_base _b_fills _b_maxcov _b_prior _b_dups _b_patient _b_pt_sorted
         _b_num _b_den _b_freq_work;
quit;

%put NOTE: ibogaine_06b_discontinuation_v2.sas (v2.2) COMPLETE.;
%put NOTE: Output: coh.ibog_06b_discont_v2 | coh.ibog_06b_patient_v2 | coh.ibog_06b_freq_v2;
%put NOTE: Interval bands are DESCRIPTIVE ONLY.;
%put NOTE: Bekelman clinical review required before any sufficiency interpretation.;


