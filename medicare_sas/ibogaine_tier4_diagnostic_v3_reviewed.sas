/* ============================================================================
   ibogaine_tier4_diagnostic_v2.sas
   Tier 4 Mood Stabilizer Active-at-Index Diagnostic

   PURPOSE:
   Definitively determines whether the Tier 4 zero result in Program 11
   was caused by drug-name matching failure or represents a true zero
   active-at-index exposure. Six steps:

   1. Rebuild frozen Medicare cohort - aborts if not exactly 590,770 total /
      307,336 candidates / 283,434 comparators
   2. Show actual FDB_GNN60 mood-stabilizer strings present in Part D
   3. Report ever-exposed AND active-at-index counts (broad match)
   4. Compare original Program 11 strings vs broad match - counts recovered
   5. Print exact FDB_GNN60 strings missed by Program 11 (active-at-index)
   6. Claim date / days-supply QC for mood stabilizer claims

   ACTIVE-AT-INDEX RULE (same as Program 11):
     srvc_dt <= index_dt AND srvc_dt + DAYS_SUPLY_NUM > index_dt

   THREE POSSIBLE CONCLUSIONS:
   A. Broad active counts nonzero → drug-name matching failure; repair P11
   B. Drugs exist historically but broad active = 0 → likely true zero
   C. Drugs exist but coverage fields missing/invalid → drop Tier 4

   DEPENDENCIES:
     coh.ibog_fp_analysis_fp_full_v001  - primary analytic table with index_dt
     ibog._ibogaine_pd_flags            - Part D claim-level drug data

   SERVER: crdw-ifhsas02-prod-asb.rad.rutgers.edu (IFH Citrix)
   AUTHOR: James Green, MS - jg1984@shp.rutgers.edu
   DATE:   September 3, 2026
============================================================================ */

options nodate nonumber ls=180 ps=max;
%put NOTE: ibogaine_tier4_diagnostic_v2.sas start: %sysfunc(datetime(), datetime20.);

libname coh  "/path/to/your/working/directory\Working\Cohorts";
libname ibog "/path/to/your/working/directory\Ibogaine_Extraction\Output";

/* ── STEP 1: Independently rebuild frozen PSYCH_ONLY cohort and gate ───────*/
%put NOTE: [Step 1] Independently rebuilding frozen Medicare PSYCH_ONLY cohort...;
	
proc sql;
  create table _cohort as
  select bene_id,
         index_dt,
         case
           when (coalesce(flag_ptsd_w,0) +
                 coalesce(flag_depression_w,0) +
                 coalesce(flag_anxiety_w,0)) >= 2 then 'CANDIDATE'
           when (coalesce(flag_ptsd_w,0) +
                 coalesce(flag_depression_w,0) +
                 coalesce(flag_anxiety_w,0)) = 0 then 'COMPARATOR'
           else 'INTERMEDIATE'
         end as cohort_group length=12
  from coh.ibog_fp_analysis_fp_full_v001
  where (coalesce(flag_ptsd_w,0) +
         coalesce(flag_depression_w,0) +
         coalesce(flag_anxiety_w,0)) in (0,2,3);
quit;

proc sql noprint;
  select count(*) into :n_total trimmed from _cohort;
  select count(*) into :n_cand trimmed
  from _cohort where cohort_group='CANDIDATE';
  select count(*) into :n_comp trimmed
  from _cohort where cohort_group='COMPARATOR';
quit;

%put NOTE: Total N = &n_total (target: 590,770);
%put NOTE: Candidates = &n_cand (target: 307,336);
%put NOTE: Comparators = &n_comp (target: 283,434);

%if &n_total ne 590770 or &n_cand ne 307336 or &n_comp ne 283434 %then %do;
  %put ERROR: Independent PSYCH_ONLY cohort gate FAILED. Aborting.;
  %put ERROR: Total=&n_total (expected 590,770);
  %put ERROR: Candidates=&n_cand (expected 307,336);
  %put ERROR: Comparators=&n_comp (expected 283,434);
  %abort cancel;
%end;
%put NOTE: Independent PSYCH_ONLY cohort gate PASSED.;

/* ── STEP 2: Actual FDB_GNN60 mood-stabilizer strings in Part D ───────────*/
%put NOTE: [Step 2] FDB_GNN60 mood-stabilizer strings in Part D...;

title "STEP 2: Mood-stabilizer FDB_GNN60 values present in _ibogaine_pd_flags";
proc sql outobs=200;
  select distinct b.FDB_GNN60,
         count(*)                 as n_claims,
         count(distinct b.bene_id) as n_patients
  from ibog._ibogaine_pd_flags b
  inner join _cohort a on b.bene_id = a.bene_id
  where upcase(b.FDB_GNN60) contains 'LITHIUM'
     or upcase(b.FDB_GNN60) contains 'VALPROAT'
     or upcase(b.FDB_GNN60) contains 'VALPROIC'
     or upcase(b.FDB_GNN60) contains 'DIVALPROEX'
     or upcase(b.FDB_GNN60) contains 'LAMOTRIGIN'
     or upcase(b.FDB_GNN60) contains 'CARBAMAZE'
     or upcase(b.FDB_GNN60) contains 'OXCARBAZE'
     or upcase(b.FDB_GNN60) contains 'DEPAKOT'
     or upcase(b.FDB_GNN60) contains 'DEPAKENE'
     or upcase(b.FDB_GNN60) contains 'TEGRETOL'
     or upcase(b.FDB_GNN60) contains 'TRILEPTAL'
     or upcase(b.FDB_GNN60) contains 'LAMICTAL'
     or upcase(b.FDB_GNN60) contains 'ESKALITH'
  group by b.FDB_GNN60
  order by n_patients desc;
quit;
title;

/* ── STEP 3A: Ever-exposed counts (any claim, no date restriction) ─────────*/
%put NOTE: [Step 3A] Ever-exposed counts - broad match...;

proc sql;
  create table _t4_ever_broad as
  select distinct a.bene_id, a.cohort_group
  from _cohort a
  inner join ibog._ibogaine_pd_flags b on a.bene_id = b.bene_id
  where upcase(b.FDB_GNN60) contains 'LITHIUM'
     or upcase(b.FDB_GNN60) contains 'VALPROAT'
     or upcase(b.FDB_GNN60) contains 'VALPROIC'
     or upcase(b.FDB_GNN60) contains 'DIVALPROEX'
     or upcase(b.FDB_GNN60) contains 'LAMOTRIGIN'
     or upcase(b.FDB_GNN60) contains 'CARBAMAZE'
     or upcase(b.FDB_GNN60) contains 'OXCARBAZE'
     or upcase(b.FDB_GNN60) contains 'DEPAKOT'
     or upcase(b.FDB_GNN60) contains 'DEPAKENE'
     or upcase(b.FDB_GNN60) contains 'TEGRETOL'
     or upcase(b.FDB_GNN60) contains 'TRILEPTAL'
     or upcase(b.FDB_GNN60) contains 'LAMICTAL'
     or upcase(b.FDB_GNN60) contains 'ESKALITH';
quit;

title "STEP 3A: Ever-exposed Tier 4 (broad match, no date restriction)";
proc sql;
  select cohort_group,
         count(*) as n_ever_exposed,
         (select count(*) from _cohort where cohort_group=a.cohort_group) as n_total,
         count(*) / (select count(*) from _cohort
                     where cohort_group=a.cohort_group) * 100 as pct_ever
  from _t4_ever_broad a
  group by cohort_group;
quit;
title;

/* ── STEP 3B: Active-at-index counts (same rule as Program 11) ────────────*/
%put NOTE: [Step 3B] Active-at-index counts - broad match...;

proc sql;
  create table _t4_active_broad as
  select distinct a.bene_id, a.cohort_group
  from _cohort a
  inner join ibog._ibogaine_pd_flags b on a.bene_id = b.bene_id
  where not missing(b.srvc_dt)
    and not missing(b.DAYS_SUPLY_NUM)
    and b.DAYS_SUPLY_NUM > 0
    and b.srvc_dt <= a.index_dt
    and (b.srvc_dt + b.DAYS_SUPLY_NUM) > a.index_dt
    and (upcase(b.FDB_GNN60) contains 'LITHIUM'
      or upcase(b.FDB_GNN60) contains 'VALPROAT'
      or upcase(b.FDB_GNN60) contains 'VALPROIC'
      or upcase(b.FDB_GNN60) contains 'DIVALPROEX'
      or upcase(b.FDB_GNN60) contains 'LAMOTRIGIN'
      or upcase(b.FDB_GNN60) contains 'CARBAMAZE'
      or upcase(b.FDB_GNN60) contains 'OXCARBAZE'
      or upcase(b.FDB_GNN60) contains 'DEPAKOT'
      or upcase(b.FDB_GNN60) contains 'DEPAKENE'
      or upcase(b.FDB_GNN60) contains 'TEGRETOL'
      or upcase(b.FDB_GNN60) contains 'TRILEPTAL'
      or upcase(b.FDB_GNN60) contains 'LAMICTAL'
      or upcase(b.FDB_GNN60) contains 'ESKALITH');
quit;

title "STEP 3B: Active-at-index Tier 4 (broad match - KEY OUTPUT)";
proc sql;
  select cohort_group,
         count(*) as n_active_at_index,
         (select count(*) from _cohort where cohort_group=a.cohort_group) as n_total,
         count(*) / (select count(*) from _cohort
                     where cohort_group=a.cohort_group) * 100 as pct_active
  from _t4_active_broad a
  group by cohort_group;
quit;
title;

/* ── STEP 4: Original P11 strings vs broad match comparison ───────────────*/
%put NOTE: [Step 4] Comparing original Program 11 strings vs broad match...;

proc sql;
  create table _t4_active_original as
  select distinct a.bene_id, a.cohort_group
  from _cohort a
  inner join ibog._ibogaine_pd_flags b on a.bene_id = b.bene_id
  where not missing(b.srvc_dt)
    and not missing(b.DAYS_SUPLY_NUM)
    and b.DAYS_SUPLY_NUM > 0
    and b.srvc_dt <= a.index_dt
    and (b.srvc_dt + b.DAYS_SUPLY_NUM) > a.index_dt
    /* Original Program 11 strings exactly */
    and (upcase(b.FDB_GNN60) contains 'LITHIUM'
      or upcase(b.FDB_GNN60) contains 'VALPROATE'
      or upcase(b.FDB_GNN60) contains 'DIVALPROEX'
      or upcase(b.FDB_GNN60) contains 'VALPROIC ACID'
      or upcase(b.FDB_GNN60) contains 'LAMOTRIGINE'
      or upcase(b.FDB_GNN60) contains 'CARBAMAZEPINE'
      or upcase(b.FDB_GNN60) contains 'OXCARBAZEPINE');
quit;

title "STEP 4: Original vs broad match - ACTIVE AT INDEX by cohort";
proc sql;
  create table _t4_original_summary as
  select cohort_group, count(*) as n_original_active
  from _t4_active_original
  group by cohort_group;

  create table _t4_broad_summary as
  select cohort_group, count(*) as n_broad_active
  from _t4_active_broad
  group by cohort_group;

  select c.cohort_group,
         coalesce(o.n_original_active,0) as n_original_active,
         coalesce(b.n_broad_active,0) as n_broad_active,
         calculated n_broad_active - calculated n_original_active
           as n_recovered_by_broad_match
  from (select distinct cohort_group from _cohort) c
  left join _t4_original_summary o
    on c.cohort_group=o.cohort_group
  left join _t4_broad_summary b
    on c.cohort_group=b.cohort_group
  order by c.cohort_group;
quit;
title;

/* ── STEP 5A-B: Exact strings active-at-index missed by original P11 ──────*/
%put NOTE: [Step 5] FDB_GNN60 strings active-at-index, missed by P11...;

title "STEP 5A: All active-at-index mood-stabilizer FDB_GNN60 strings (broad)";
proc sql outobs=100;
  select distinct b.FDB_GNN60,
         a.cohort_group,
         count(distinct a.bene_id) as n_active_patients
  from _cohort a
  inner join ibog._ibogaine_pd_flags b on a.bene_id = b.bene_id
  where not missing(b.srvc_dt)
    and not missing(b.DAYS_SUPLY_NUM)
    and b.DAYS_SUPLY_NUM > 0
    and b.srvc_dt <= a.index_dt
    and (b.srvc_dt + b.DAYS_SUPLY_NUM) > a.index_dt
    and (upcase(b.FDB_GNN60) contains 'LITHIUM'
      or upcase(b.FDB_GNN60) contains 'VALPROAT'
      or upcase(b.FDB_GNN60) contains 'VALPROIC'
      or upcase(b.FDB_GNN60) contains 'DIVALPROEX'
      or upcase(b.FDB_GNN60) contains 'LAMOTRIGIN'
      or upcase(b.FDB_GNN60) contains 'CARBAMAZE'
      or upcase(b.FDB_GNN60) contains 'OXCARBAZE'
      or upcase(b.FDB_GNN60) contains 'DEPAKOT'
      or upcase(b.FDB_GNN60) contains 'DEPAKENE'
      or upcase(b.FDB_GNN60) contains 'TEGRETOL'
      or upcase(b.FDB_GNN60) contains 'TRILEPTAL'
      or upcase(b.FDB_GNN60) contains 'LAMICTAL'
      or upcase(b.FDB_GNN60) contains 'ESKALITH')
  group by b.FDB_GNN60, a.cohort_group
  order by n_active_patients desc;
quit;
title;

title "STEP 5B: Active-at-index strings NOT matched by original P11 strings";
proc sql outobs=100;
  select distinct b.FDB_GNN60,
         count(distinct a.bene_id) as n_active_patients
  from _cohort a
  inner join ibog._ibogaine_pd_flags b on a.bene_id = b.bene_id
  where not missing(b.srvc_dt)
    and not missing(b.DAYS_SUPLY_NUM)
    and b.DAYS_SUPLY_NUM > 0
    and b.srvc_dt <= a.index_dt
    and (b.srvc_dt + b.DAYS_SUPLY_NUM) > a.index_dt
    /* Broad match */
    and (upcase(b.FDB_GNN60) contains 'LITHIUM'
      or upcase(b.FDB_GNN60) contains 'VALPROAT'
      or upcase(b.FDB_GNN60) contains 'VALPROIC'
      or upcase(b.FDB_GNN60) contains 'DIVALPROEX'
      or upcase(b.FDB_GNN60) contains 'LAMOTRIGIN'
      or upcase(b.FDB_GNN60) contains 'CARBAMAZE'
      or upcase(b.FDB_GNN60) contains 'OXCARBAZE'
      or upcase(b.FDB_GNN60) contains 'DEPAKOT'
      or upcase(b.FDB_GNN60) contains 'DEPAKENE'
      or upcase(b.FDB_GNN60) contains 'TEGRETOL'
      or upcase(b.FDB_GNN60) contains 'TRILEPTAL'
      or upcase(b.FDB_GNN60) contains 'LAMICTAL'
      or upcase(b.FDB_GNN60) contains 'ESKALITH')
    /* NOT matched by original P11 exact strings */
    and not (upcase(b.FDB_GNN60) contains 'LITHIUM'
          or upcase(b.FDB_GNN60) contains 'VALPROATE'
          or upcase(b.FDB_GNN60) contains 'DIVALPROEX'
          or upcase(b.FDB_GNN60) contains 'VALPROIC ACID'
          or upcase(b.FDB_GNN60) contains 'LAMOTRIGINE'
          or upcase(b.FDB_GNN60) contains 'CARBAMAZEPINE'
          or upcase(b.FDB_GNN60) contains 'OXCARBAZEPINE')
  group by b.FDB_GNN60
  order by n_active_patients desc;
quit;
title;

/* ── STEP 6: Claim date / days-supply QC for mood-stabilizer claims ───────*/
%put NOTE: [Step 6] Coverage field QC for mood-stabilizer claims...;

title "STEP 6: QC - missing or invalid dates/days-supply for Tier 4 claims";
proc sql;
  select "Total mood-stabilizer claims in cohort" as check_label,
         count(*) as n
  from _cohort a
  inner join ibog._ibogaine_pd_flags b on a.bene_id = b.bene_id
  where upcase(b.FDB_GNN60) contains 'LITHIUM'
     or upcase(b.FDB_GNN60) contains 'VALPROAT'
     or upcase(b.FDB_GNN60) contains 'VALPROIC'
     or upcase(b.FDB_GNN60) contains 'DIVALPROEX'
     or upcase(b.FDB_GNN60) contains 'LAMOTRIGIN'
     or upcase(b.FDB_GNN60) contains 'CARBAMAZE'
     or upcase(b.FDB_GNN60) contains 'OXCARBAZE'
     or upcase(b.FDB_GNN60) contains 'DEPAKOT'
     or upcase(b.FDB_GNN60) contains 'DEPAKENE'
     or upcase(b.FDB_GNN60) contains 'TEGRETOL'
     or upcase(b.FDB_GNN60) contains 'TRILEPTAL'
     or upcase(b.FDB_GNN60) contains 'LAMICTAL'
     or upcase(b.FDB_GNN60) contains 'ESKALITH'
  union all
  select "Missing srvc_dt",
         count(*)
  from _cohort a
  inner join ibog._ibogaine_pd_flags b on a.bene_id = b.bene_id
  where (upcase(b.FDB_GNN60) contains 'LITHIUM'
      or upcase(b.FDB_GNN60) contains 'VALPROAT'
      or upcase(b.FDB_GNN60) contains 'VALPROIC'
      or upcase(b.FDB_GNN60) contains 'DIVALPROEX'
      or upcase(b.FDB_GNN60) contains 'LAMOTRIGIN'
      or upcase(b.FDB_GNN60) contains 'CARBAMAZE'
      or upcase(b.FDB_GNN60) contains 'OXCARBAZE'
      or upcase(b.FDB_GNN60) contains 'DEPAKOT'
      or upcase(b.FDB_GNN60) contains 'DEPAKENE'
      or upcase(b.FDB_GNN60) contains 'TEGRETOL'
      or upcase(b.FDB_GNN60) contains 'TRILEPTAL'
      or upcase(b.FDB_GNN60) contains 'LAMICTAL'
      or upcase(b.FDB_GNN60) contains 'ESKALITH')
    and b.srvc_dt is missing
  union all
  select "Missing or zero DAYS_SUPLY_NUM",
         count(*)
  from _cohort a
  inner join ibog._ibogaine_pd_flags b on a.bene_id = b.bene_id
  where (upcase(b.FDB_GNN60) contains 'LITHIUM'
      or upcase(b.FDB_GNN60) contains 'VALPROAT'
      or upcase(b.FDB_GNN60) contains 'VALPROIC'
      or upcase(b.FDB_GNN60) contains 'DIVALPROEX'
      or upcase(b.FDB_GNN60) contains 'LAMOTRIGIN'
      or upcase(b.FDB_GNN60) contains 'CARBAMAZE'
      or upcase(b.FDB_GNN60) contains 'OXCARBAZE'
      or upcase(b.FDB_GNN60) contains 'DEPAKOT'
      or upcase(b.FDB_GNN60) contains 'DEPAKENE'
      or upcase(b.FDB_GNN60) contains 'TEGRETOL'
      or upcase(b.FDB_GNN60) contains 'TRILEPTAL'
      or upcase(b.FDB_GNN60) contains 'LAMICTAL'
      or upcase(b.FDB_GNN60) contains 'ESKALITH')
    and (b.DAYS_SUPLY_NUM is missing or b.DAYS_SUPLY_NUM <= 0)
  union all
  select "Claims with date AND valid days-supply (coverage computable)",
         count(*)
  from _cohort a
  inner join ibog._ibogaine_pd_flags b on a.bene_id = b.bene_id
  where (upcase(b.FDB_GNN60) contains 'LITHIUM'
      or upcase(b.FDB_GNN60) contains 'VALPROAT'
      or upcase(b.FDB_GNN60) contains 'VALPROIC'
      or upcase(b.FDB_GNN60) contains 'DIVALPROEX'
      or upcase(b.FDB_GNN60) contains 'LAMOTRIGIN'
      or upcase(b.FDB_GNN60) contains 'CARBAMAZE'
      or upcase(b.FDB_GNN60) contains 'OXCARBAZE'
      or upcase(b.FDB_GNN60) contains 'DEPAKOT'
      or upcase(b.FDB_GNN60) contains 'DEPAKENE'
      or upcase(b.FDB_GNN60) contains 'TEGRETOL'
      or upcase(b.FDB_GNN60) contains 'TRILEPTAL'
      or upcase(b.FDB_GNN60) contains 'LAMICTAL'
      or upcase(b.FDB_GNN60) contains 'ESKALITH')
    and b.srvc_dt is not missing
    and b.DAYS_SUPLY_NUM > 0;
quit;
title;

%put NOTE: ============================================================;
%put NOTE: ibogaine_tier4_diagnostic_v2.sas COMPLETE;
%put NOTE: Key outputs to share:;
%put NOTE:   Step 2  - actual FDB_GNN60 strings;
%put NOTE:   Step 3B - active-at-index broad match counts (KEY);
%put NOTE:   Step 4  - original vs broad active-at-index counts for BOTH groups;
%put NOTE:   Step 5B - strings missed by Program 11;
%put NOTE:   Step 6  - coverage field QC;
%put NOTE: ============================================================;
