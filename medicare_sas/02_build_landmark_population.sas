/******************************************************************************
PROGRAM  : 02_build_landmark_population.sas
VERSION  : fp_v006 (fixes: item 1 hash restriction, item 10 MOUD-unknown
           group handling, item 11 FFS through index_dt, item 12 duplicate
           check, item 13 test-sample strata, item 14 proper attrition)
******************************************************************************/

%put NOTE: 02_build_landmark_population.sas starting...;
%require_dataset(res.ibog_run_manifest&version_tag., context=02_build needs 00_setup);
%require_dataset(ibog.eligible_scp_ibogaine_bene_flags, context=run 01_validate and review before 02_build);

%macro run_02_build;

%local n_original_staged;
proc sql noprint;
   select count(*) into :n_original_staged trimmed
   from ibog.eligible_scp_ibogaine_bene_flags;
quit;
%put NOTE: ATTRITION 0 -- original staged rows (before anchor-date filtering): &n_original_staged.;

/* ===========================================================================
   STEP 1: Anchor date + canonical date boundaries.
   Set once here; never recalculate differently in any downstream program.
   =========================================================================== */
data _anchor_full;
   set ibog.eligible_scp_ibogaine_bene_flags;
   anchor_dt = min(first_oud_dx_dt, first_moud_fill_dt);
   /* ITEM 8 FIX: this delete was previously invisible to the attrition
      table -- n_staged below was computed AFTER this deletion, so the
      attrition table's stage 1 ("Lydia staged") was actually already the
      post-deletion, valid-anchor count, not the true original count
      captured above as n_original_staged. */
   if missing(anchor_dt) then delete;

   length anchor_type $8;
   if not missing(first_oud_dx_dt) and not missing(first_moud_fill_dt)
      and first_oud_dx_dt = first_moud_fill_dt then anchor_type = 'BOTH';
   else if anchor_dt = first_oud_dx_dt then anchor_type = 'OUD_DX';
   else anchor_type = 'MOUD';

   classification_start_dt = anchor_dt;
   classification_end_dt   = anchor_dt + &classification_days. - 1;
   index_dt                = anchor_dt + &index_offset.;
   followup_start_dt       = index_dt + 1;

   format anchor_dt classification_start_dt classification_end_dt
          index_dt followup_start_dt date9.;

   keep bene_id anchor_dt anchor_type flag_oud_dx flag_moud_fill
        first_oud_dx_dt first_moud_fill_dt
        classification_start_dt classification_end_dt index_dt followup_start_dt;
run;

%local n_staged;
proc sql noprint; select count(*) into :n_staged trimmed from _anchor_full; quit;
%put NOTE: ATTRITION 1 -- staged population: &n_staged.;

/* ===========================================================================
   STEP 2: Test-mode restriction using a hash lookup (item 1 fix).
   ITEM 13: sample strata cover anchor type, strong-inhibitor users,
   missing/invalid days-supply, untiered drugs -- not just anchor types.
   =========================================================================== */
%if %upcase(&test_mode.) = Y %then %do;
   /* Stratified sample from smaller flag-level tables -- no large scans yet */
   proc sql outobs=&test_sample_n.;
      create table _s_oud  as select bene_id from _anchor_full where anchor_type='OUD_DX';
      create table _s_moud as select bene_id from _anchor_full where anchor_type in ('MOUD','BOTH');
   quit;
   proc sql outobs=&test_sample_n.;
      create table _s_strong as select distinct bene_id from ibog._ibogaine_pd_flags
         where upcase(strip(cyp2d6_tier)) = 'STRONG';
      create table _s_bad_supply as select distinct bene_id from ibog._ibogaine_pd_flags
         where missing(days_suply_num) or days_suply_num <= 0 or days_suply_num > &max_days_supply.;
      create table _s_no_tier as select distinct bene_id from ibog._ibogaine_pd_flags
         where missing(cyp2d6_tier);
      /* Test-sample refinement: target-drug stratum by NAME, not just
         tier. Without this, the sample could contain plenty of
         strong-tier records without ever containing an actual bupropion/
         paroxetine/fluoxetine fill -- meaning the branch test would
         exercise the all-strong SENSITIVITY definition but not the
         actual PRIMARY three-drug definition it's supposed to validate. */
      create table _s_target_drug as select distinct bene_id from ibog._ibogaine_pd_flags
         where upcase(strip(&pd_generic_name_var.)) contains "&target_drug_1."
            or upcase(strip(&pd_generic_name_var.)) contains "&target_drug_2."
            or upcase(strip(&pd_generic_name_var.)) contains "&target_drug_3.";
   quit;
   data _test_benes_all;
      set _s_oud _s_moud _s_strong _s_bad_supply _s_no_tier _s_target_drug;
   run;
   proc sort data=_test_benes_all nodupkey; by bene_id; run;

   /* ITEM 1 FIX: Use a hash lookup instead of a DATA-step SQL subquery */
   data _anchor;
      if _N_ = 1 then do;
         declare hash h(dataset:"_test_benes_all");
         h.defineKey("bene_id");
         h.defineDone();
      end;
      set _anchor_full;
      if h.check() = 0;
   run;

   %local n_test;
   proc sql noprint; select count(*) into :n_test trimmed from _anchor; quit;
   %put NOTE: ATTRITION 2 (TEST MODE) -- sample population: &n_test.;
%end;
%else %do;
   data _anchor; set _anchor_full; run;
   %put NOTE: test_mode=N -- using full staged population (&n_staged. benes).;
%end;

/* ===========================================================================
   STEP 3: Enrollment stack with duplicate check (item 12 fix).
   CRITICAL FIX (this round): restrict to _anchor beneficiaries in BOTH
   modes, not just test_mode=Y. The prior version scanned the ENTIRE
   Medicare enrollment population across all 7 years when test_mode=N --
   "full" should mean the full STAGED IBOGAINE population, not the full
   Medicare population. Uses _anchor (not _test_benes_all, which only
   exists in test mode) so the same restriction logic works in both modes.
   =========================================================================== */
data _anchor_keys;
   set _anchor(keep=bene_id);
run;
proc sort data=_anchor_keys nodupkey; by bene_id; run;

data _enr_stack;
   if 0 then set _anchor_keys; /* establishes PDV shape, doesn't read rows */
   if _N_ = 1 then do;
      declare hash h(dataset:"_anchor_keys");
      h.defineKey("bene_id");
      h.defineDone();
   end;
   set enr.master_1&enr_first_year. - enr.master_1&enr_last_year.
       (keep=bene_id bene_enrollmt_ref_yr bene_death_dt valid_death_dt_sw
             mdcr_entlmt_buyin_ind_01-mdcr_entlmt_buyin_ind_12
             hmo_ind_01-hmo_ind_12
             ptd_cntrct_id_01-ptd_cntrct_id_12);
   if h.check() = 0;
run;

data _enr_long_raw;
   set _enr_stack;
   array entlmt{12} mdcr_entlmt_buyin_ind_01-mdcr_entlmt_buyin_ind_12;
   array hmo{12} hmo_ind_01-hmo_ind_12;
   array ptd{12} $ ptd_cntrct_id_01-ptd_cntrct_id_12;
   do month_num = 1 to 12;
      month_start_dt = mdy(month_num, 1, bene_enrollmt_ref_yr);
      ffs_ab_month = (entlmt{month_num} in &entlmt_ab_codes.
                      and hmo{month_num} in &hmo_ffs_codes.);
      partd_month  = (not missing(ptd{month_num})
                      and ptd{month_num} not in &partd_none_vals.);
      keep bene_id month_start_dt ffs_ab_month partd_month;
      output;
   end;
   format month_start_dt date9.;
run;

/* ITEM 10 FIX: check for CONFLICTING values within duplicate bene/month
   records, not just count duplicates. Exact duplicates (same ffs_ab_month
   and partd_month) are safe to silently collapse. Conflicting duplicates
   (different values for the same bene/month) mean the retained record
   would be arbitrary -- hard-stop in that case rather than guessing. */
%local n_enr_raw n_enr_distinct n_conflicting;
proc sql noprint;
   select count(*), count(distinct catx('|', bene_id, put(month_start_dt, date9.)))
   into :n_enr_raw trimmed, :n_enr_distinct trimmed
   from _enr_long_raw;
quit;
%put NOTE: _enr_long_raw: &n_enr_raw. rows, &n_enr_distinct. distinct bene/month combos;

%if &n_enr_raw. ne &n_enr_distinct. %then %do;
   proc sql noprint;
      create table _enr_conflict_check as
      select bene_id, month_start_dt,
             min(ffs_ab_month) as min_ffs, max(ffs_ab_month) as max_ffs,
             min(partd_month) as min_partd, max(partd_month) as max_partd,
             count(*) as n_dupes
      from _enr_long_raw
      group by bene_id, month_start_dt
      having count(*) > 1;
      select count(*) into :n_conflicting trimmed
      from _enr_conflict_check
      where min_ffs ne max_ffs or min_partd ne max_partd;
   quit;
   %put NOTE: %eval(&n_enr_raw. - &n_enr_distinct.) duplicate bene/month records found.;
   %if &n_conflicting. > 0 %then
      %ibog_stop(&n_conflicting. bene/month combinations have CONFLICTING ffs_ab_month
                 or partd_month values across duplicate records. Cannot safely
                 deduplicate. Review _enr_conflict_check and resolve with Lydia
                 before proceeding.);
   %else %put NOTE: All duplicates are exact (no conflicting values) -- safe to collapse.;
%end;
proc sort data=_enr_long_raw nodupkey; by bene_id month_start_dt; run;
data _enr_long; set _enr_long_raw; run;

/* Death dates */
proc sql;
   create table _death as
   select bene_id, min(bene_death_dt) as valid_death_dt format=date9.
   from _enr_stack
   where valid_death_dt_sw = 'V' and not missing(bene_death_dt)
   group by bene_id;
quit;

/* ===========================================================================
   STEP 4: Continuous FFS A/B through index_dt (item 11 fix)
   Prior version required through classification_end_dt = index_dt - 1.
   Now requires through index_dt itself (the exposure-assessment day).
   =========================================================================== */
data _cohort_enroll_window;
   set _anchor;
   enroll_start_month = intnx('month', classification_start_dt, 0, 'beginning');
   enroll_end_month   = intnx('month', index_dt, 0, 'beginning'); /* now includes index month */
   expected_months_ab = intck('month', enroll_start_month, enroll_end_month) + 1;
   format enroll_start_month enroll_end_month date9.;
run;

proc sql;
   create table _enroll_check as
   select c.bene_id, c.expected_months_ab,
          count(l.month_start_dt) as observed_months_ab,
          sum(l.ffs_ab_month) as eligible_months_ab
   from _cohort_enroll_window c
   left join _enr_long l
      on c.bene_id = l.bene_id
     and l.month_start_dt >= c.enroll_start_month
     and l.month_start_dt <= c.enroll_end_month
   group by c.bene_id, c.expected_months_ab;
quit;

data _enroll_check;
   set _enroll_check;
   continuous_ffs = (observed_months_ab = expected_months_ab
                     and eligible_months_ab = expected_months_ab);
   if missing(continuous_ffs) then continuous_ffs = 0;
run;

/* ===========================================================================
   STEP 5: Landmark eligibility
   =========================================================================== */
proc sql;
   create table _cohort_eligible as
   select a.*
   from _anchor a
   inner join _enroll_check e on a.bene_id = e.bene_id
   left join _death d on a.bene_id = d.bene_id
   where e.continuous_ffs = 1
     and (missing(d.valid_death_dt) or d.valid_death_dt > a.index_dt);
quit;

%local n_eligible;
proc sql noprint; select count(*) into :n_eligible trimmed from _cohort_eligible; quit;
%put NOTE: ATTRITION 3 -- landmark-eligible: &n_eligible.;

/* ===========================================================================
   STEP 6: Windowed qualifier flags -- any qualifying claim during
   [classification_start_dt, classification_end_dt]
   =========================================================================== */
proc sql;
   create table _dx_windowed as
   select c.bene_id,
          max(case when d.flag_ptsd       = 1 then 1 else 0 end) as flag_ptsd_w,
          max(case when d.flag_depression = 1 then 1 else 0 end) as flag_depression_w,
          max(case when d.flag_anxiety    = 1 then 1 else 0 end) as flag_anxiety_w,
          max(case when d.flag_tbi        = 1 then 1 else 0 end) as flag_tbi_w
   from _cohort_eligible c
   left join ibog._ibogaine_dx_flags d
      on c.bene_id = d.bene_id
     and d.clm_from_dt >= c.classification_start_dt
     and d.clm_from_dt <= c.classification_end_dt
   group by c.bene_id;
quit;

proc sql;
   create table _moud_windowed as
   select c.bene_id,
          max(case when p.flag_moud = 1 then 1 else 0 end) as flag_moud_w_pd
   from _cohort_eligible c
   left join ibog._ibogaine_pd_flags p
      on c.bene_id = p.bene_id
     and p.srvc_dt >= c.classification_start_dt
     and p.srvc_dt <= c.classification_end_dt
   group by c.bene_id;
quit;

/* ===========================================================================
   STEP 7: MOUD Part D observability (full classification window)
   =========================================================================== */
data _cohort_moud_win;
   set _cohort_eligible;
   moud_start = intnx('month', classification_start_dt, 0, 'beginning');
   moud_end   = intnx('month', classification_end_dt,   0, 'beginning');
   expected_moud_months = intck('month', moud_start, moud_end) + 1;
   format moud_start moud_end date9.;
run;

proc sql;
   create table _moud_obs as
   select c.bene_id, c.expected_moud_months,
          count(l.month_start_dt) as observed_moud_months,
          sum(l.partd_month) as covered_moud_months
   from _cohort_moud_win c
   left join _enr_long l
      on c.bene_id = l.bene_id
     and l.month_start_dt >= c.moud_start
     and l.month_start_dt <= c.moud_end
   group by c.bene_id, c.expected_moud_months;
quit;

data _moud_obs;
   set _moud_obs;
   moud_fully_observable =
      (observed_moud_months = expected_moud_months
       and covered_moud_months = expected_moud_months);
   if missing(moud_fully_observable) then moud_fully_observable = 0;
run;

/* ===========================================================================
   STEP 8: Qualifier counts and group assignment.
   ITEM 10 FIX: MOUD-unknown beneficiaries get UNCLASSIFIED group under
   the psych-plus-MOUD definition when they have insufficient psychiatric
   qualifiers to be classified independently of MOUD.
   Psych-only definition is unaffected and is the safer primary definition.
   =========================================================================== */
proc sql;
   create table _cohort_quals as
   select a.*,
          d.flag_ptsd_w, d.flag_depression_w, d.flag_anxiety_w, d.flag_tbi_w,
          m.flag_moud_w_pd,
          o.moud_fully_observable
   from _cohort_eligible a
   left join _dx_windowed d on a.bene_id = d.bene_id
   left join _moud_windowed m on a.bene_id = m.bene_id
   left join _moud_obs o on a.bene_id = o.bene_id;
quit;

data _cohort_quals;
   set _cohort_quals;
   array flgs flag_ptsd_w flag_depression_w flag_anxiety_w flag_tbi_w flag_moud_w_pd;
   do over flgs; if missing(flgs) then flgs = 0; end;
   if missing(moud_fully_observable) then moud_fully_observable = 0;

   /* Three-level MOUD status.
      ITEM 9 CAVEAT: MOUD_ABSENT_OBSERVABLE means no staged flag_moud=1
      Part D record was observed during a fully-observable classification
      period -- it does NOT establish absence of ALL MOUD exposure unless
      Lydia's staged pharmacy file (_ibogaine_pd_flags) is confirmed to
      contain every relevant MOUD source (e.g. methadone dispensed through
      an opioid treatment program may not appear in a Part D extract).
      Confirm this scope during the staging audit before treating
      MOUD_ABSENT_OBSERVABLE as a definitive negative -- this affects
      interpretation of the psych-plus-MOUD sensitivity specifically; the
      psych-only primary analysis does not depend on this variable. */
   length moud_status $24;
   if flag_moud_w_pd = 1 then moud_status = 'MOUD_PRESENT';
   else if moud_fully_observable = 1 then moud_status = 'MOUD_ABSENT_OBSERVABLE';
   else moud_status = 'MOUD_UNKNOWN';

   /* Psych-only count (primary -- unaffected by MOUD uncertainty) */
   n_qualifiers_psych = sum(0, flag_ptsd_w, flag_depression_w, flag_anxiety_w);

   /* Psych+MOUD count (sensitivity) -- raw version, treats unknown MOUD as
      absent, kept only for the group-assignment logic below where the
      UNCLASSIFIED override already handles the uncertainty correctly */
   n_qualifiers_psych_moud = sum(0, flag_ptsd_w, flag_depression_w, flag_anxiety_w,
                                    flag_moud_w_pd);

   /* ITEM 5/6 FIX: class-safe EXACT count for the GRADIENT table.
      Missing whenever MOUD is unknown, full stop -- this is a genuinely
      different question from group eligibility (primary_group_psych_moud
      below can still correctly call someone CANDIDATE via psych alone
      even when MOUD is unknown, since psych qualifiers >= 2 is sufficient
      regardless of MOUD). But the EXACT count shown in the gradient table
      must not silently show "2" for someone whose true count could be 2
      or 3 depending on their actual (unknown) MOUD status -- that would
      mix confirmed-zero-MOUD people with unknown-MOUD people at the same
      displayed count value. */
   if moud_status = 'MOUD_UNKNOWN' then n_qualifiers_psych_moud_class = .;
   else n_qualifiers_psych_moud_class = n_qualifiers_psych_moud;

   /* Descriptive groupings */
   length complexity_psych $20 complexity_psych_moud $20;
   if n_qualifiers_psych = 0 then complexity_psych = 'ZERO_QUALIFIER';
   else if n_qualifiers_psych = 1 then complexity_psych = 'ONE_QUALIFIER';
   else complexity_psych = 'TWO_PLUS_QUALIFIERS';

   if missing(n_qualifiers_psych_moud_class) then complexity_psych_moud = 'UNCLASSIFIED';
   else if n_qualifiers_psych_moud_class = 0 then complexity_psych_moud = 'ZERO_QUALIFIER';
   else if n_qualifiers_psych_moud_class = 1 then complexity_psych_moud = 'ONE_QUALIFIER';
   else complexity_psych_moud = 'TWO_PLUS_QUALIFIERS';

   /* Primary group -- psych-only (stable, not affected by MOUD uncertainty) */
   length primary_group_psych $12;
   if n_qualifiers_psych >= &cand_min_qualifiers. then primary_group_psych = 'CANDIDATE';
   else if n_qualifiers_psych <= &comp_max_qualifiers. then primary_group_psych = 'COMPARATOR';
   else primary_group_psych = 'INTERMEDIATE';

   /* Psych+MOUD group -- UNCLASSIFIED when MOUD unknown and psych alone insufficient
      (item 10 fix: MOUD_UNKNOWN must not be silently treated as MOUD=0) */
   length primary_group_psych_moud $12;
   if n_qualifiers_psych_moud >= &cand_min_qualifiers. then
      primary_group_psych_moud = 'CANDIDATE';       /* psych alone qualifies, MOUD doesn't matter */
   else if moud_status = 'MOUD_UNKNOWN' and n_qualifiers_psych < &cand_min_qualifiers. then
      primary_group_psych_moud = 'UNCLASSIFIED';    /* MOUD unknown, can't confirm comparator */
   else if n_qualifiers_psych_moud <= &comp_max_qualifiers. then
      primary_group_psych_moud = 'COMPARATOR';      /* observably no psych + observably no MOUD */
   else primary_group_psych_moud = 'INTERMEDIATE';

   primary_comparison_flag = (primary_group_psych in ('CANDIDATE','COMPARATOR'));
run;

%assert_unique(_cohort_quals);

/* ===========================================================================
   STEP 9: Write base output and diagnostics
   =========================================================================== */
data &t_base.;
   set _cohort_quals;
run;

%log_counts(&t_base., label=ibog_fp_base final);

/* ITEM 14 FIX: proper attrition table with all stages and group breakdown */
%local n_cand n_comp n_inter n_moud_unknown n_moud_unclassified;
proc sql noprint;
   select sum(primary_group_psych='CANDIDATE'),
          sum(primary_group_psych='COMPARATOR'),
          sum(primary_group_psych='INTERMEDIATE'),
          sum(moud_status='MOUD_UNKNOWN'),
          sum(primary_group_psych_moud='UNCLASSIFIED')
   into :n_cand trimmed, :n_comp trimmed, :n_inter trimmed,
        :n_moud_unknown trimmed, :n_moud_unclassified trimmed
   from &t_base.;
quit;

data &t_attrition.;
   length stage $60 n 8 note $150;
   stage = "1. Original staged rows (eligible_scp_ibogaine_bene_flags)";
   n = &n_original_staged.; note = "Before anchor-date filtering -- true source row count"; output;
   stage = "2. Valid anchor (OUD dx or MOUD fill date present)";
   n = &n_staged.; note = "Excludes rows missing BOTH first_oud_dx_dt and first_moud_fill_dt -- see 01_validate consistency check"; output;
   %if %upcase(&test_mode.) = Y %then %do;
   stage = "3. Test-mode sample"; n = &n_test.;
   note = "Stratified: anchor type, strong-tier, bad-supply, untiered-drug strata"; output;
   %end;
   stage = "4. Landmark-eligible (alive + continuous FFS through index_dt)";
   n = &n_eligible.; note = "FFS required through index date (day 365)"; output;
   stage = "5a. Candidate (>=&cand_min_qualifiers. psych qualifiers)";
   n = &n_cand.; note = "Primary psych-only definition"; output;
   stage = "5b. Comparator (0 psych qualifiers)";
   n = &n_comp.; note = "Primary psych-only definition"; output;
   stage = "5c. Intermediate (1 psych qualifier)";
   n = &n_inter.; note = "Retained in base table, excluded from primary contrast"; output;
   /* ITEM 6 FIX: these are two DIFFERENT questions, no longer conflated.
      A beneficiary with >=2 psych qualifiers and unknown MOUD is counted
      in MOUD_UNKNOWN (exposure ascertainment problem) but is NOT
      unclassified (psych alone already determines CANDIDATE status). */
   stage = "6a. MOUD_UNKNOWN (exposure ascertainment gap)";
   n = &n_moud_unknown.; note = "MOUD exposure could not be fully ascertained -- NOT necessarily unclassified"; output;
   stage = "6b. UNCLASSIFIED under psych+MOUD group definition";
   n = &n_moud_unclassified.; note = "Group could not be assigned under psych+MOUD sensitivity definition specifically"; output;
run;

proc print data=&t_attrition. noobs; title "02_build: Attrition"; run;

/* ITEM 7 FIX: diagnostic PROC FREQ now shows n_qualifiers_psych_moud_class
   (the class-safe exact count, missing when MOUD unknown) instead of the
   raw n_qualifiers_psych_moud, which silently treats unknown MOUD as
   zero and could confuse log review even though the permanent gradient
   table already uses the correct variable. */
proc freq data=&t_base.;
   tables n_qualifiers_psych n_qualifiers_psych_moud_class
          primary_group_psych primary_group_psych_moud
          moud_status anchor_type
          anchor_type * primary_group_psych / missing;
   title "02_build: Qualifier distributions";
run;

/* ITEM 3 FIX (prior round): correct PROC FREQ OUT= syntax.
   ITEM 6 FIX (this round): use moud_status, not the raw flag_moud_w_pd --
   the raw flag treats unknown MOUD as absent, which would silently
   display MOUD_UNKNOWN benes as if they were confirmed MOUD-negative. */
proc freq data=&t_base. noprint;
   tables flag_ptsd_w * flag_depression_w * flag_anxiety_w * moud_status
          / missing list out=&t_qual_combos.;
run;

proc print data=&t_qual_combos. noobs; title "02_build: All qualifier flag combinations"; run;

%put NOTE: 02_build_landmark_population.sas complete.;
%put NOTE: MOUD_UNKNOWN count: &n_moud_unknown.;
%put NOTE: If large, review whether MOUD should remain in the primary qualifier count.;

%mend run_02_build;
%run_02_build;

/* end 02_build_landmark_population.sas */
