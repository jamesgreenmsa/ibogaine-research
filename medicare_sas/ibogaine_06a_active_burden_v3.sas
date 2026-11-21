/******************************************************************************
  PROGRAM  : ibogaine_06a_active_burden_v2.sas
  VERSION  : v2.2 (2026-08-20)
  PURPOSE  : Analysis A - Current-Active Medication Transition Burden.
             For candidates and comparators with bupropion, paroxetine,
             and/or fluoxetine active at index, reconstruct expected
             prescription coverage remaining at index per drug, count
             concurrent active target inhibitors.
             Estimand: among patients with at least one target inhibitor
             active at the analytic index, what expected prescription
             coverage does a clinician potentially have to manage?
******************************************************************************/

%put NOTE: ibogaine_06a_active_burden_v2.sas (v2.2) starting...;

/*--- PREFLIGHT -------------------------------------------------------------*/
/*%macro preflight_06a;*/
/*  %local _n _abort;*/
/*  %let _abort=0;*/
/**/
/*  /* Cohort table exists */*/
/*  proc sql noprint;*/
/*    select count(*) into :_n trimmed*/
/*    from dictionary.tables*/
/*    where upcase(libname)='COH'*/
/*      and upcase(memname)='IBOG_FP_ANALYSIS_FP_FULL_V001';*/
/*  quit;*/
/*  %if &_n=0 %then %do;*/
/*    %put ERROR: [preflight_06a] coh.ibog_fp_analysis_fp_full_v001 not found.;*/
/*    %let _abort=1;*/
/*  %end;*/

  /* Part D flags table exists */
/*  proc sql noprint;*/
/*    select count(*) into :_n trimmed*/
/*    from dictionary.tables*/
/*    where upcase(libname)='IBOG'*/
/*      and upcase(memname)='IBOGAINE_PD_FLAGS';*/
/*  quit;*/
/*  %if &_n=0 %then %do;*/
/*    %put ERROR: [preflight_06a] ibog._ibogaine_pd_flags not found.;*/
/*    %let _abort=1;*/
/*  %end;*/

  /* Cohort column checks */
  %macro _chkcol(ds,col);
/*    %local _nc;*/
/*    proc sql noprint;*/
/*      select count(*) into :_nc trimmed*/
/*      from dictionary.columns*/
/*      where upcase(libname)=upcase(scan("&ds.",1,'.'))*/
/*        and upcase(memname)=upcase(scan("&ds.",2,'.'))*/
/*        and upcase(name)=upcase("&col.");*/
/*    quit;*/
/*    %if &_nc=0 %then %do;*/
/*      %put ERROR: [preflight_06a] Column &col. not found in &ds.;*/
/*      %let _abort=1;*/
/*    %end;*/
/*  %mend;*/
/*  %_chkcol(coh.ibog_fp_analysis_fp_full_v001, bene_id);*/
/*  %_chkcol(coh.ibog_fp_analysis_fp_full_v001, index_dt);*/
/*  %_chkcol(coh.ibog_fp_analysis_fp_full_v001, primary_group_psych);*/
/*  %_chkcol(coh.ibog_fp_analysis_fp_full_v001, active_bupropion);*/
/*  %_chkcol(coh.ibog_fp_analysis_fp_full_v001, active_paroxetine);*/
/*  %_chkcol(coh.ibog_fp_analysis_fp_full_v001, active_fluoxetine);*/
/**/
/*  /* Part D column checks (v2.1 addition) */*/
/*  %_chkcol(ibog._ibogaine_pd_flags, bene_id);*/
/*  %_chkcol(ibog._ibogaine_pd_flags, FDB_GNN60);*/
/*  %_chkcol(ibog._ibogaine_pd_flags, cyp2d6_tier);*/
/*  %_chkcol(ibog._ibogaine_pd_flags, srvc_dt);*/
/*  %_chkcol(ibog._ibogaine_pd_flags, days_suply_num);*/

  %if %symexist(max_days_supply)=0 %then %do;
/*    %put ERROR: [preflight_06a] max_days_supply not defined. Run 00_ibogaine_setup.sas first.;*/
/*    %let _abort=1;*/
/*  %end;*/

/*  %if &_abort=1 %then %abort cancel;*/
/*  %put NOTE: [preflight_06a] All preflight checks passed.;*/
/*%mend preflight_06a;*/
/*%preflight_06a;*/

/*--- STEP 0: Pull active-target-drug patients ------------------------------*/
proc sql;
  create table _a_base as
  select
    bene_id,
    index_dt,
    primary_group_psych as cohort_group length=12,
    coalesce(active_bupropion,0)  as active_bupropion,
    coalesce(active_paroxetine,0) as active_paroxetine,
    coalesce(active_fluoxetine,0) as active_fluoxetine,
    coalesce(active_bupropion,0)
      + coalesce(active_paroxetine,0)
      + coalesce(active_fluoxetine,0) as n_active_target_drugs
  from coh.ibog_fp_analysis_fp_full_v001
  where primary_group_psych in ('CANDIDATE','COMPARATOR')
    and (  coalesce(active_bupropion,0)=1
        or coalesce(active_paroxetine,0)=1
        or coalesce(active_fluoxetine,0)=1 );
quit;

%let _n_base=0;
proc sql noprint;
  select count(*) into :_n_base trimmed from _a_base;
quit;
%put NOTE: [06a Step 0] Active-target-drug population N = &_n_base.;

/* Assertion: active patient x drug rows must equal upstream drug-specific
   flag sum (computed directly from primary analysis table). */
proc sql noprint;
  select sum(coalesce(active_bupropion,0))
       + sum(coalesce(active_paroxetine,0))
       + sum(coalesce(active_fluoxetine,0))
  into :_n_upstream_drugrows trimmed
  from coh.ibog_fp_analysis_fp_full_v001
  where primary_group_psych in ('CANDIDATE','COMPARATOR');
quit;
%put NOTE: [06a Step 0] Upstream drug-specific flag sum = &_n_upstream_drugrows. (expected active patient x drug rows in output);

/*--- STEP 1: Pull all valid fills ------------------------------------------*/
proc sql;
  create table _a_fills as
  select
    b.bene_id,
    b.index_dt,
    b.cohort_group,
    b.n_active_target_drugs,
    case
      when index(upcase(p.FDB_GNN60),'BUPROPION')  > 0 then 'BUPROPION'
      when index(upcase(p.FDB_GNN60),'PAROXETINE') > 0 then 'PAROXETINE'
      when index(upcase(p.FDB_GNN60),'FLUOXETINE') > 0 then 'FLUOXETINE'
    end as drug_name length=12,
    p.srvc_dt + p.days_suply_num - 1 as coverage_end format=date9.
  from _a_base b
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
    and p.srvc_dt >= b.index_dt - 365
    and p.srvc_dt <= b.index_dt;
quit;

/*--- STEP 2: Max coverage end per patient x drug ---------------------------*/
proc sql;
  create table _a_maxcov as
  select
    bene_id,
    index_dt,
    cohort_group,
    n_active_target_drugs,
    drug_name,
    max(coverage_end)                           as max_coverage_end format=date9.,
    max(0, max(coverage_end) - index_dt + 1)    as days_coverage_remaining,
    case when max(coverage_end) >= index_dt then 1 else 0 end
                                                as confirmed_active_at_index
  from _a_fills
  where drug_name ne ''
  group by bene_id, index_dt, cohort_group, n_active_target_drugs, drug_name;
quit;

/*--- STEP 3: Bidirectional reconciliation (v2.1) ---------------------------*/
proc sql;
  create table _a_reconcile as
  select
    b.bene_id,
    b.index_dt,
    b.active_bupropion,
    b.active_paroxetine,
    b.active_fluoxetine,
    max(case when c.drug_name='BUPROPION'  then c.confirmed_active_at_index else . end) as pd_bup_active,
    max(case when c.drug_name='PAROXETINE' then c.confirmed_active_at_index else . end) as pd_par_active,
    max(case when c.drug_name='FLUOXETINE' then c.confirmed_active_at_index else . end) as pd_flu_active
  from _a_base b
  left join _a_maxcov c
    on b.bene_id=c.bene_id and b.index_dt=c.index_dt
  group by b.bene_id, b.index_dt,
           b.active_bupropion, b.active_paroxetine, b.active_fluoxetine;
quit;

proc sql noprint;
  /* Forward: flag=1 but Part D says not active */
  select count(*) into :_n_fwd_bup trimmed from _a_reconcile
    where active_bupropion=1  and coalesce(pd_bup_active,0) ne 1;
  select count(*) into :_n_fwd_par trimmed from _a_reconcile
    where active_paroxetine=1 and coalesce(pd_par_active,0) ne 1;
  select count(*) into :_n_fwd_flu trimmed from _a_reconcile
    where active_fluoxetine=1 and coalesce(pd_flu_active,0) ne 1;
  /* Reverse (v2.1): flag=0 but Part D says active */
  select count(*) into :_n_rev_bup trimmed from _a_reconcile
    where active_bupropion=0  and coalesce(pd_bup_active,0)=1;
  select count(*) into :_n_rev_par trimmed from _a_reconcile
    where active_paroxetine=0 and coalesce(pd_par_active,0)=1;
  select count(*) into :_n_rev_flu trimmed from _a_reconcile
    where active_fluoxetine=0 and coalesce(pd_flu_active,0)=1;
quit;

%put NOTE: [06a QC] Forward reconciliation failures - Bup:&_n_fwd_bup. Par:&_n_fwd_par. Flu:&_n_fwd_flu.;
%put NOTE: [06a QC] Reverse reconciliation failures - Bup:&_n_rev_bup. Par:&_n_rev_par. Flu:&_n_rev_flu.;

%macro assert_reconcile_a;
  %if &_n_fwd_bup>0 or &_n_fwd_par>0 or &_n_fwd_flu>0
   or &_n_rev_bup>0 or &_n_rev_par>0 or &_n_rev_flu>0 %then %do;
    %put ERROR: [06a HARD STOP] Bidirectional reconciliation failed.;
    %put ERROR: Program 03 drug-specific flags do not agree with Part D coverage reconstruction.;
    %abort cancel;
  %end;
  %put NOTE: [06a QC] Bidirectional reconciliation passed for all three drugs.;
%mend assert_reconcile_a;
%assert_reconcile_a;

/*--- STEP 4: Active patient x drug row count assertion (v2.1) -------------*/
/* Confirmed active rows should equal sum of upstream drug-specific flags */
%let _n_active_rows=0;
proc sql noprint;
  select count(*) into :_n_active_rows trimmed
  from _a_maxcov
  where confirmed_active_at_index=1;
quit;
%put NOTE: [06a QC] Active patient x drug rows (reconstructed): &_n_active_rows.;
%put NOTE: [06a QC] Expected (upstream flag sum):                &_n_upstream_drugrows.;

%macro assert_active_rows;
  %if &_n_active_rows ne &_n_upstream_drugrows %then %do;
    %put ERROR: [06a HARD STOP] Active patient x drug row count &_n_active_rows.;
    %put ERROR: does not equal upstream drug-specific flag sum &_n_upstream_drugrows.;
    %put ERROR: Extra reconstructed active drugs detected. Investigate.;
    %abort cancel;
  %end;
  %put NOTE: [06a QC] Active row count assertion passed.;
%mend assert_active_rows;
%assert_active_rows;

/*--- STEP 5: Patient-level summary (v2.1 max fix) --------------------------*/
/* Fix: use SQL aggregate max(), not Base SAS row-wise max() with 3 args.
   The join restricts c to confirmed_active_at_index=1, so
   max(c.days_coverage_remaining) is the true maximum across active drugs. */

proc sql;
  create table _a_pt_summary as
  select
    b.bene_id,
    b.index_dt,
    b.cohort_group,
    b.n_active_target_drugs,
    max(case when c.drug_name='BUPROPION'  then c.days_coverage_remaining else 0 end)
      as bup_days_remaining,
    max(case when c.drug_name='PAROXETINE' then c.days_coverage_remaining else 0 end)
      as par_days_remaining,
    max(case when c.drug_name='FLUOXETINE' then c.days_coverage_remaining else 0 end)
      as flu_days_remaining,
    /* v2.1 fix: SQL aggregate max, not row-wise max() */
    max(c.days_coverage_remaining)
      as max_days_remaining,
    case when b.n_active_target_drugs > 1 then 1 else 0 end as multi_active_flag
  from _a_base b
  left join _a_maxcov c
    on b.bene_id=c.bene_id and b.index_dt=c.index_dt
    and c.confirmed_active_at_index=1
  group by b.bene_id, b.index_dt, b.cohort_group, b.n_active_target_drugs;
quit;

/*--- STEP 6: Hard QC before writing ----------------------------------------*/

%let _n_pt_rows=0; %let _n_pt_uniq=0;
proc sql noprint;
  select count(*), count(distinct bene_id)
  into :_n_pt_rows trimmed, :_n_pt_uniq trimmed
  from _a_pt_summary;
quit;

%macro assert_pt_a;
  %if &_n_pt_rows ne &_n_pt_uniq %then %do;
    %put ERROR: [06a HARD STOP] Duplicate bene_ids in patient summary.;
    %abort cancel;
  %end;
  %if &_n_pt_rows ne &_n_base %then %do;
    %put ERROR: [06a HARD STOP] Patient summary rows &_n_pt_rows. ne base &_n_base.;
    %abort cancel;
  %end;
  %put NOTE: [06a QC] Patient summary: &_n_pt_rows. rows, &_n_pt_uniq. unique bene_ids. OK.;
%mend assert_pt_a;
%assert_pt_a;

/*--- STEP 7: Write permanent output and verify ----------------------------*/
data coh.ibog_06a_active_v2;
  set _a_maxcov;
  where confirmed_active_at_index=1;
  label
    bene_id                  = "Beneficiary ID"
    index_dt                 = "Index date"
    cohort_group             = "CANDIDATE or COMPARATOR"
    n_active_target_drugs    = "Count of active target inhibitors at index"
    drug_name                = "Drug (BUPROPION/PAROXETINE/FLUOXETINE)"
    max_coverage_end         = "Maximum expected coverage end date"
    days_coverage_remaining  = "Expected prescription coverage remaining at index (days)"
    confirmed_active_at_index= "1 = coverage extends to or past index date";
run;

data coh.ibog_06a_summary_v2;
  set _a_pt_summary;
  label
    bene_id               = "Beneficiary ID"
    index_dt              = "Index date"
    cohort_group          = "CANDIDATE or COMPARATOR"
    n_active_target_drugs = "Count of active target inhibitors at index"
    bup_days_remaining    = "Bupropion: expected prescription coverage remaining (days)"
    par_days_remaining    = "Paroxetine: expected prescription coverage remaining (days)"
    flu_days_remaining    = "Fluoxetine: expected prescription coverage remaining (days)"
    max_days_remaining    = "Maximum expected coverage remaining across active drugs (days)"
    multi_active_flag     = "1 = two or more target drugs active at index";
run;

/* Post-write verification */
%let _n_w_drug=0; %let _n_w_pt=0;
proc sql noprint;
  select count(*) into :_n_w_drug trimmed from coh.ibog_06a_active_v2;
  select count(*) into :_n_w_pt   trimmed from coh.ibog_06a_summary_v2;
quit;

%macro assert_write_a;
  %if &_n_w_drug ne &_n_active_rows %then %do;
    %put ERROR: [06a HARD STOP] Written drug rows &_n_w_drug. ne staged &_n_active_rows.;
    %abort cancel;
  %end;
  %if &_n_w_pt ne &_n_base %then %do;
    %put ERROR: [06a HARD STOP] Written patient rows &_n_w_pt. ne base &_n_base.;
    %abort cancel;
  %end;
  %put NOTE: [06a] Post-write verification passed.;
%mend assert_write_a;
%assert_write_a;

/*--- STEP 8: Descriptive output --------------------------------------------*/
title "Table A1: Active target inhibitors at index by cohort group";
proc freq data=coh.ibog_06a_summary_v2 order=freq;
  tables cohort_group * n_active_target_drugs / norow nocol nopercent missing ;
run; title;

title "Table A2: Expected prescription coverage remaining at index by drug";
proc means data=coh.ibog_06a_active_v2 n mean median min max p25 p75 p95;
  class cohort_group drug_name;
  var days_coverage_remaining;
run; title;

title "Table A3: Multiple concurrent active inhibitors by cohort group";
proc freq data=coh.ibog_06a_summary_v2 order=freq;
  tables cohort_group * multi_active_flag / norow nocol nopercent missing;
run; title;

title "Table A4: Maximum expected coverage remaining across active drugs";
proc means data=coh.ibog_06a_summary_v2 n mean median min max p25 p75 p95;
  class cohort_group;
  var max_days_remaining;
run; title;

/*--- CLEANUP ---------------------------------------------------------------*/
proc datasets library=work nolist;
  delete _a_base _a_fills _a_maxcov _a_reconcile _a_pt_summary;
quit;

%put NOTE: ibogaine_06a_active_burden_v2.sas (v2.2) COMPLETE.;
%put NOTE: Output: coh.ibog_06a_active_v2 | coh.ibog_06a_summary_v2;
