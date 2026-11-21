/******************************************************************************
  PROGRAM  : ibogaine_07a_cardiac_feasibility.sas
  VERSION  : v1.0 (2026-08-27)
  PURPOSE  : Blinded cardiac outcome feasibility check.
             Counts incident serious cardiac events by outcome category
             in the ibogaine candidate and comparator populations.
             This is a FEASIBILITY CHECK ONLY - it does not compare
             inhibitor-exposed vs unexposed patients, and no comparative
             estimates are computed here. The output informs the team
             decision on whether to proceed with Program 07b (comparative
             outcome analysis) and which endpoint to pre-specify.

  ESTIMAND : Among proxy-defined ibogaine candidates and OUD comparators
             in the Medicare FFS cohort, what is the observed incidence
             of serious cardiac events in the follow-up window after the
             analytic index date?

  DESIGN NOTE: This program is intentionally blinded. It counts outcomes
             by cohort group (CANDIDATE vs COMPARATOR) but does NOT
             stratify by CYP2D6 inhibitor exposure status. Looking at
             the inhibitor-stratified analysis before the team agrees on
             an endpoint and analysis plan would compromise the integrity
             of a subsequent pre-registered analysis.

  PI       : James Green (jg1984@shp.rutgers.edu)
  DEPENDS  : 00_ibogaine_setup.sas must have run in this session.
             coh.ibog_fp_analysis_fp_full_v001 (99c output)
             ibog._cardiac_outcome_flags (Lydia's extraction)
             ibog.eligible_scp_ibogaine_bene_flags (Lydia's bene table)

  PRIMARY ENDPOINT (proposed):
             out_torsades (I49.01) - Torsades de pointes
             This is the arrhythmia mechanism implicated in documented
             ibogaine-associated deaths and the most specific endpoint
             for the CYP2D6-inhibition pathway.

  SECONDARY ENDPOINTS:
             out_cardiac_arrest (I46x) - Cardiac arrest
             out_vt (I47.2) - Ventricular tachycardia
             out_vf (I49.0x) - Ventricular fibrillation
             Composite of above four (QT/arrhythmia composite)

  OUTPUT   : coh.ibog_07a_feasibility  - event counts by outcome + group
             coh.ibog_07a_incidence    - crude incidence rates per 1,000 PY
             Descriptive PROC PRINT to log

  KEY QUESTION THIS PROGRAM ANSWERS:
             Do we have sufficient events to power a comparative analysis?
             Minimum threshold for proceeding to 07b:
             >= 100 torsades events total (proposed - subject to team review)
             >= 500 composite endpoint events total

  NOTES:
  - Follow-up starts at index_dt + 180 days (latency floor, matching 04_outcomes)
  - Follow-up ends at min(first cardiac event date, end_study, death, disenroll)
  - Prevalent cardiac events (before index_dt) are excluded - incident only
  - No inhibitor-exposure stratification in this program
  - Do not modify this program to add inhibitor stratification before
    team review of these feasibility results
******************************************************************************/

%put NOTE: ibogaine_07a_cardiac_feasibility.sas (v1.0) starting...;

/* -------------------------------------------------------------------------
   Set the path to your pipeline setup file (00_ibogaine_setup.sas) below.
   That file assigns all library names via a single proj_root macro variable.
   ------------------------------------------------------------------------- */
/* %include "/path/to/j_code/00_ibogaine_setup.sas"; */

/*--- PREFLIGHT -------------------------------------------------------------*/
%macro preflight_07a;
  %local _n _abort;
  %let _abort = 0;

  %macro _chktbl(lib, mem);
    %local _n2;
    proc sql noprint;
      select count(*) into :_n2 trimmed
      from dictionary.tables
      where upcase(libname) = upcase("&lib.")
        and upcase(memname) = upcase("&mem.");
    quit;
    %if &_n2 = 0 %then %do;
      %put ERROR: [preflight_07a] &lib..&mem. not found.;
      %let _abort = 1;
    %end;
  %mend;

  %_chktbl(COH,  IBOG_FP_ANALYSIS_FP_FULL_V001);
/*  %_chktbl(IBOG, CARDIAC_OUTCOME_FLAGS);*/
/*  %_chktbl(IBOG, ELIGIBLE_SCP_IBOGAINE_BENE_FLAGS);*/

  %if &_abort = 1 %then %abort cancel;
  %put NOTE: [preflight_07a] All preflight checks passed.;
%mend preflight_07a;
%preflight_07a;

/*--- PARAMETERS -----------------------------------------------------------*/
%let latency_days  = 180;       /* days from index before outcomes count    */
%let end_study     = %str(mdy(12,31,2022)); /* last date in Lydia's extract */
%let min_events_primary   = 100;  /* feasibility threshold - torsades       */
%let min_events_composite = 500;  /* feasibility threshold - composite       */

/*--- STEP 1: Pull cohort base (candidates and comparators) ---------------*/
proc sql;
  create table _07a_cohort as
  select
    bene_id,
    index_dt,
    primary_group_psych as cohort_group length = 12,
    index_dt + &latency_days. as latency_dt format = date9.,
    &end_study.           as end_study_dt format = date9.
  from coh.ibog_fp_analysis_fp_full_v001
  where primary_group_psych in ('CANDIDATE', 'COMPARATOR');
quit;

%let _n_cohort = 0;
proc sql noprint;
  select count(*) into :_n_cohort trimmed from _07a_cohort;
quit;
%put NOTE: [07a Step 1] Cohort N = &_n_cohort.;

/*--- STEP 2: Pull cardiac outcome flags and restrict to post-latency -----*/
/* The cardiac_outcome_flags table contains one row per bene per event date
   per outcome type. We need incident events only (after index_dt) and
   specifically post-latency (after index_dt + 180 days).               */

proc sql;
  create table _07a_cardiac as
  select
    c.bene_id,
    c.cohort_group,
    c.index_dt,
    c.latency_dt,
    c.end_study_dt,
    f.CLM_FROM_DT as event_dt,
    f.out_torsades,
    f.out_cardiac_arrest,
    f.out_vt,
    f.out_vf,
    f.out_qt_prolongation,
    f.out_qt_obs,
    f.out_arrhythmia_other,
    f.out_afib,
    f.out_bradycardia,
    f.out_cardioversion,
    /* Composite: TdP + cardiac arrest + VT + VF */
    case when coalesce(f.out_torsades,0) = 1
           or coalesce(f.out_cardiac_arrest,0) = 1
           or coalesce(f.out_vt,0) = 1
           or coalesce(f.out_vf,0) = 1
         then 1 else 0 end as out_composite
  from _07a_cohort c
  inner join ibog._cardiac_outcome_flags f
    on c.bene_id = f.bene_id
  where f.CLM_FROM_DT > c.index_dt          /* incident only                  */
    and f.CLM_FROM_DT >= c.latency_dt       /* post-latency floor             */
    and f.CLM_FROM_DT <= c.end_study_dt;    /* within study window            */
quit;

%put NOTE: [07a Step 2] Post-latency cardiac event records: %trim(%left(%sysfunc(open(_07a_cardiac))));

/*--- STEP 3: First incident event per bene per outcome -------------------*/
/* Take the earliest post-latency event per bene per outcome type.
   A bene should contribute at most one event per outcome category.    */

proc sql;
  create table _07a_first as
  select
    bene_id,
    cohort_group,
    index_dt,
    latency_dt,
    end_study_dt,
    min(case when out_torsades     = 1 then event_dt else . end) as dt_torsades     format = date9.,
    min(case when out_cardiac_arrest=1 then event_dt else . end) as dt_arrest       format = date9.,
    min(case when out_vt           = 1 then event_dt else . end) as dt_vt           format = date9.,
    min(case when out_vf           = 1 then event_dt else . end) as dt_vf           format = date9.,
    min(case when out_qt_prolongation=1 then event_dt else . end) as dt_qt          format = date9.,
    min(case when out_afib         = 1 then event_dt else . end) as dt_afib         format = date9.,
    min(case when out_cardioversion= 1 then event_dt else . end) as dt_cardioversion format = date9.,
    min(case when out_composite    = 1 then event_dt else . end) as dt_composite    format = date9.
  from _07a_cardiac
  group by bene_id, cohort_group, index_dt, latency_dt, end_study_dt;
quit;

/*--- STEP 4: Merge back to full cohort (non-events get missing dates) ---*/
proc sql;
  create table _07a_full as
  select
    c.bene_id,
    c.cohort_group,
    c.index_dt,
    c.latency_dt,
    c.end_study_dt,
    coalesce(f.dt_torsades,      .) as dt_torsades     format = date9.,
    coalesce(f.dt_arrest,        .) as dt_arrest       format = date9.,
    coalesce(f.dt_vt,            .) as dt_vt           format = date9.,
    coalesce(f.dt_vf,            .) as dt_vf           format = date9.,
    coalesce(f.dt_qt,            .) as dt_qt           format = date9.,
    coalesce(f.dt_afib,          .) as dt_afib         format = date9.,
    coalesce(f.dt_cardioversion, .) as dt_cardioversion format = date9.,
    coalesce(f.dt_composite,     .) as dt_composite    format = date9.,
    /* Event indicators */
    case when f.dt_torsades      is not missing then 1 else 0 end as ev_torsades,
    case when f.dt_arrest        is not missing then 1 else 0 end as ev_arrest,
    case when f.dt_vt            is not missing then 1 else 0 end as ev_vt,
    case when f.dt_vf            is not missing then 1 else 0 end as ev_vf,
    case when f.dt_qt            is not missing then 1 else 0 end as ev_qt,
    case when f.dt_afib          is not missing then 1 else 0 end as ev_afib,
    case when f.dt_cardioversion is not missing then 1 else 0 end as ev_cardioversion,
    case when f.dt_composite     is not missing then 1 else 0 end as ev_composite,
    /* Person-time: from latency_dt to first event or end_study, in days */
    case when f.dt_composite is not missing
         then f.dt_composite - c.latency_dt
         else c.end_study_dt - c.latency_dt
    end as pt_days_composite,
    case when f.dt_torsades is not missing
         then f.dt_torsades - c.latency_dt
         else c.end_study_dt - c.latency_dt
    end as pt_days_torsades
  from _07a_cohort c
  left join _07a_first f
    on c.bene_id = f.bene_id;
quit;

/*--- STEP 5: QC - no events before latency floor -------------------------*/
%let _n_prelat = 0;
proc sql noprint;
  select count(*) into :_n_prelat trimmed
  from _07a_full
  where ev_torsades = 1 and dt_torsades < latency_dt;
quit;
%put NOTE: [07a QC] Pre-latency torsades events (should be 0): &_n_prelat.;

%macro assert_no_prelat;
  %if &_n_prelat > 0 %then %do;
    %put ERROR: [07a HARD STOP] &_n_prelat. torsades events precede the latency floor.;
    %abort cancel;
  %end;
  %put NOTE: [07a QC] No pre-latency events confirmed.;
%mend assert_no_prelat;
%assert_no_prelat;

/*--- STEP 6: Feasibility summary by cohort group -------------------------*/
proc sql;
  create table _07a_summary as
  select
    cohort_group,
    count(*)               as n_benes,
    sum(ev_torsades)       as n_torsades,
    sum(ev_arrest)         as n_arrest,
    sum(ev_vt)             as n_vt,
    sum(ev_vf)             as n_vf,
    sum(ev_qt)             as n_qt_prolongation,
    sum(ev_afib)           as n_afib,
    sum(ev_cardioversion)  as n_cardioversion,
    sum(ev_composite)      as n_composite,
    sum(pt_days_composite) / 365.25 as pt_years_composite,
    sum(pt_days_torsades)  / 365.25 as pt_years_torsades,
    /* Crude incidence rates per 1,000 person-years */
    sum(ev_torsades)  / (sum(pt_days_torsades)  / 365.25) * 1000 as ir_torsades_per1000py,
    sum(ev_composite) / (sum(pt_days_composite) / 365.25) * 1000 as ir_composite_per1000py
  from _07a_full
  group by cohort_group;
quit;

/* Total events (candidates + comparators combined) */
proc sql noprint;
  select sum(n_torsades)  into :_total_torsades  trimmed from _07a_summary;
  select sum(n_composite) into :_total_composite trimmed from _07a_summary;
quit;

%put NOTE: [07a] Total torsades events (all groups):  &_total_torsades.;
%put NOTE: [07a] Total composite events (all groups): &_total_composite.;
%put NOTE: [07a] Feasibility threshold - torsades:   &min_events_primary. events;
%put NOTE: [07a] Feasibility threshold - composite:  &min_events_composite. events;

/*--- STEP 7: Feasibility verdict -----------------------------------------*/
%macro feasibility_verdict;
  %if %sysevalf(&_total_torsades >= &min_events_primary) %then %do;
    %put NOTE: [07a VERDICT] TORSADES: FEASIBLE (&_total_torsades. events >= threshold &min_events_primary.).;
    %put NOTE: [07a VERDICT] Proceed to 07b torsades primary endpoint analysis after team review.;
  %end;
  %else %do;
    %put NOTE: [07a VERDICT] TORSADES: UNDERPOWERED (&_total_torsades. events < threshold &min_events_primary.).;
    %put NOTE: [07a VERDICT] Do not proceed with torsades as primary endpoint.;
    %put NOTE: [07a VERDICT] Consider composite endpoint if &_total_composite. >= &min_events_composite..;
  %end;

  %if %sysevalf(&_total_composite >= &min_events_composite) %then %do;
    %put NOTE: [07a VERDICT] COMPOSITE: FEASIBLE (&_total_composite. events >= threshold &min_events_composite.).;
  %end;
  %else %do;
    %put NOTE: [07a VERDICT] COMPOSITE: UNDERPOWERED (&_total_composite. events < threshold &min_events_composite.).;
    %put NOTE: [07a VERDICT] Consider reporting as descriptive only - do not proceed to comparative analysis.;
  %end;
%mend feasibility_verdict;
%feasibility_verdict;

/*--- STEP 8: Write permanent output --------------------------------------*/
data coh.ibog_07a_feasibility;
  set _07a_summary;
  label
    cohort_group          = "CANDIDATE or COMPARATOR"
    n_benes               = "N in cohort group"
    n_torsades            = "N with incident torsades de pointes (I49.01)"
    n_arrest              = "N with incident cardiac arrest (I46x)"
    n_vt                  = "N with incident ventricular tachycardia (I47.2)"
    n_vf                  = "N with incident ventricular fibrillation (I49.0x)"
    n_qt_prolongation     = "N with QT prolongation encounter (I45.81)"
    n_afib                = "N with incident atrial fibrillation (I48x)"
    n_cardioversion       = "N with cardioversion procedure (HCPCS 92960/92961)"
    n_composite           = "N with incident composite endpoint (TdP+arrest+VT+VF)"
    pt_years_composite    = "Person-years at risk (composite endpoint follow-up)"
    pt_years_torsades     = "Person-years at risk (torsades follow-up)"
    ir_torsades_per1000py = "Crude torsades incidence rate per 1,000 person-years"
    ir_composite_per1000py= "Crude composite incidence rate per 1,000 person-years";
run;

data coh.ibog_07a_patientlevel;
  set _07a_full;
  label
    bene_id      = "Beneficiary ID"
    cohort_group = "CANDIDATE or COMPARATOR"
    index_dt     = "Analytic index date"
    latency_dt   = "Latency floor (index + 180 days)"
    ev_torsades  = "1 = incident torsades de pointes in follow-up"
    ev_composite = "1 = incident composite cardiac endpoint in follow-up"
    pt_days_composite = "Person-days at risk for composite endpoint";
run;

/*--- STEP 9: Post-write verification ------------------------------------*/
%let _n_w_feas = 0; %let _n_w_pt = 0;
proc sql noprint;
  select count(*) into :_n_w_feas trimmed from coh.ibog_07a_feasibility;
  select count(*) into :_n_w_pt   trimmed from coh.ibog_07a_patientlevel;
quit;
%put NOTE: [07a] coh.ibog_07a_feasibility rows = &_n_w_feas. (expect 2 - one per group);
%put NOTE: [07a] coh.ibog_07a_patientlevel rows = &_n_w_pt. (expect = cohort N &_n_cohort.);

%macro assert_write_07a;
  %if &_n_w_feas ne 2 %then %do;
    %put ERROR: [07a] Expected 2 rows in feasibility table, got &_n_w_feas.;
    %abort cancel;
  %end;
  %if &_n_w_pt ne &_n_cohort %then %do;
    %put ERROR: [07a] Patient-level table rows &_n_w_pt. ne cohort N &_n_cohort.;
    %abort cancel;
  %end;
  %put NOTE: [07a] Post-write verification passed.;
%mend assert_write_07a;
%assert_write_07a;

/*--- STEP 10: Print results -----------------------------------------------*/
title "Table 07a-1: Cardiac Outcome Feasibility by Cohort Group";
title2 "BLINDED - No inhibitor-exposure stratification in this output";
title3 "Follow-up: index + 180 days through December 31, 2022";
proc print data = coh.ibog_07a_feasibility noobs label;
  var cohort_group n_benes
      n_torsades n_arrest n_vt n_vf n_composite
      pt_years_composite ir_torsades_per1000py ir_composite_per1000py;
  format pt_years_composite ir_torsades_per1000py ir_composite_per1000py 8.1;
run;
title; title2; title3;

title "Table 07a-2: Full Cardiac Event Count Summary";
proc print data = coh.ibog_07a_feasibility noobs label;
  var cohort_group n_benes
      n_torsades n_arrest n_vt n_vf
      n_qt_prolongation n_afib n_cardioversion n_composite;
run;
title;

title "Table 07a-3: Feasibility Verdict Summary";
data _verdict;
  length outcome $40 n_events 8 threshold 8 verdict $20;
  outcome = 'Torsades de pointes (primary)';
  n_events = &_total_torsades.;
  threshold = &min_events_primary.;
  verdict = ifc(n_events >= threshold, 'FEASIBLE', 'UNDERPOWERED');
  output;
  outcome = 'Composite (TdP+arrest+VT+VF)';
  n_events = &_total_composite.;
  threshold = &min_events_composite.;
  verdict = ifc(n_events >= threshold, 'FEASIBLE', 'UNDERPOWERED');
  output;
run;
proc print data = _verdict noobs label;
  var outcome n_events threshold verdict;
run;
title;

/*--- CLEANUP -------------------------------------------------------------*/
proc datasets library = work nolist;
  delete _07a_cohort _07a_cardiac _07a_first _07a_full _07a_summary _verdict;
quit;

%put NOTE: ibogaine_07a_cardiac_feasibility.sas (v1.0) COMPLETE.;
%put NOTE: Output: coh.ibog_07a_feasibility | coh.ibog_07a_patientlevel;
%put NOTE: NEXT STEP: Share Table 07a-1 and 07a-3 with the team.;
%put NOTE: DO NOT run 07b until the team has reviewed the feasibility results;
%put NOTE: and agreed on the primary endpoint and analysis plan.;
