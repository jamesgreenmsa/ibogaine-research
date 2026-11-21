/******************************************************************************
PROGRAM  : 03_define_cyp2d6_exposure.sas
VERSION  : fp_v006 (round 4 fixes: semicolon removed from require_dataset
           context; target-drug identification now name-based ONLY, no
           longer gated on cyp2d6_tier='STRONG' -- a known target drug with
           a blank/miscoded tier is no longer missed, and an unrelated
           untiered medication no longer makes the target-drug outcome
           unknown; all-strong-tier sensitivity now has its own invalid-
           supply uncertainty, which was missing before)
******************************************************************************/

%put NOTE: 03_define_cyp2d6_exposure.sas starting...;
%require_dataset(&t_base., context=03_exposure needs 02_build first);
%require_dataset(ibog._ibogaine_pd_flags, context=03_exposure needs pharmacy file);

%macro run_03_exposure;

%require_dataset(work._enr_long, context=_enr_long from 02_build - rerun 02_build if missing);

/* ===========================================================================
   STEP 0: _pd_valid created first. Normalizes tier and drug name once.
   is_target_drug is NAME-BASED and does not depend on tier_norm at all --
   this is the key structural fix this round.
   =========================================================================== */
data _pd_valid;
   set ibog._ibogaine_pd_flags;
   length tier_norm $10 name_norm $100;
   tier_norm = upcase(strip(cyp2d6_tier));
   name_norm = upcase(strip(&pd_generic_name_var.));
   valid_supply = (not missing(days_suply_num) and days_suply_num > 0
                   and days_suply_num <= &max_days_supply.);
   is_bupropion   = (index(name_norm, "&target_drug_1.")   > 0);
   is_paroxetine  = (index(name_norm, "&target_drug_2.")  > 0);
   is_fluoxetine  = (index(name_norm, "&target_drug_3.")  > 0);
   is_target_drug = (is_bupropion or is_paroxetine or is_fluoxetine);
run;

/* Concordance check moved to 01_validate_lydia_staging.sas (item 7 fix,
   this round) -- it now lives in the staging audit itself, so an analyst
   reviewing 99a's output before setting audit_approved=Y can actually see
   it, rather than it only existing after Program 03 runs. &t_concord. is
   already built by the time this program executes, since 01_validate
   runs earlier in every driver's %include chain. */

/* ===========================================================================
   STEP 1: Part D observability near the index date.
   TWO SEPARATE windows (this round's fix): active-at-index needs the
   longer max_days_supply-based window (a fill could be dispensed up to
   max_days_supply days before index and still cover it); recent-fill only
   needs the shorter recent_fill_days window. Reusing one window for both
   meant someone observable for the 90 recent days but not the extra
   ~10 days could be wrongly marked UNKNOWN_NO_PARTD for the recent-fill
   outcome specifically.
   =========================================================================== */
data _cohort_partd_win;
   set &t_base.;
   /* ITEM 5 FIX: exact start dates, defined once and reused everywhere.
      Coverage formula is srvc_dt + days_supply - 1 >= index_dt, so with
      max_days_supply=100 the EARLIEST possibly-active dispensing date is
      index_dt - 99, not index_dt - 100. Same logic for the recent window:
      the 90-day window is index_dt-89 through index_dt (90 calendar
      days inclusive), not index_dt-90. Previously the observability
      windows started one day earlier than necessary, which could add an
      entire calendar month to the requirement when that extra day
      crossed a month boundary. */
   active_start_dt = index_dt - &max_days_supply. + 1;
   recent_start_dt = index_dt - &recent_fill_days. + 1;

   /* Active-at-index window (longer, uses max_days_supply) */
   active_win_start = intnx('month', active_start_dt, 0, 'beginning');
   active_win_end   = intnx('month', index_dt, 0, 'beginning');
   expected_active_months = intck('month', active_win_start, active_win_end) + 1;
   /* Recent-fill window (shorter, uses recent_fill_days only) */
   recent_win_start = intnx('month', recent_start_dt, 0, 'beginning');
   recent_win_end   = active_win_end; /* same end month */
   expected_recent_months = intck('month', recent_win_start, recent_win_end) + 1;
   format active_win_start active_win_end recent_win_start recent_win_end
          active_start_dt recent_start_dt date9.;
   keep bene_id index_dt active_start_dt recent_start_dt
        active_win_start active_win_end expected_active_months
        recent_win_start recent_win_end expected_recent_months;
run;

proc sql;
   create table _partd_obs_index as
   select c.bene_id, c.expected_active_months,
          count(l.month_start_dt) as observed_active_months,
          sum(l.partd_month) as covered_active_months,
          max(case when l.month_start_dt = intnx('month', c.index_dt, 0, 'beginning')
                   then l.partd_month else 0 end) as index_month_covered
   from _cohort_partd_win c
   left join work._enr_long l
      on c.bene_id = l.bene_id
     and l.month_start_dt >= c.active_win_start
     and l.month_start_dt <= c.active_win_end
   group by c.bene_id, c.expected_active_months;
quit;

data _partd_obs_index;
   set _partd_obs_index;
   partd_active_window_obs =
      (observed_active_months = expected_active_months
       and covered_active_months = expected_active_months
       and index_month_covered = 1);
   if missing(partd_active_window_obs) then partd_active_window_obs = 0;
run;

/* Separate, shorter window specifically for the recent-fill outcome */
proc sql;
   create table _partd_obs_recent as
   select c.bene_id, c.expected_recent_months,
          count(l.month_start_dt) as observed_recent_months,
          sum(l.partd_month) as covered_recent_months
   from _cohort_partd_win c
   left join work._enr_long l
      on c.bene_id = l.bene_id
     and l.month_start_dt >= c.recent_win_start
     and l.month_start_dt <= c.recent_win_end
   group by c.bene_id, c.expected_recent_months;
quit;

data _partd_obs_recent;
   set _partd_obs_recent;
   partd_recent_window_obs =
      (observed_recent_months = expected_recent_months
       and covered_recent_months = expected_recent_months);
   if missing(partd_recent_window_obs) then partd_recent_window_obs = 0;
run;

proc sql;
   create table _partd_obs_full_year as
   select bene_id, moud_fully_observable as partd_full_year_obs
   from &t_base.;
quit;

/* ===========================================================================
   STEP 2: Active-at-index and recent exposure.
   Target-drug measures no longer require tier_norm='STRONG' -- name match
   alone determines is_target_drug. All-strong-tier sensitivity is
   unchanged (tier-based) but now gets its OWN invalid-supply uncertainty,
   which the prior version omitted.
   =========================================================================== */
proc sql;
   create table _cyp_active_recent as
   select b.bene_id, b.index_dt,

      /* PRIMARY: active at index, target drugs by NAME (tier irrelevant) */
      max(case when p.is_target_drug = 1
                and p.valid_supply = 1
                and p.srvc_dt <= b.index_dt
                and (p.srvc_dt + p.days_suply_num - 1) >= b.index_dt
               then 1 else 0 end) as active_at_index_target,

      /* Target drug, active window, but invalid supply -- the ONLY
         uncertainty source for the target-drug measure, since drug
         identity itself is unambiguous (name match, not tier-dependent) */
      max(case when p.is_target_drug = 1
                and p.valid_supply = 0
                and p.srvc_dt <= b.index_dt
                and p.srvc_dt >= b.index_dt - &max_days_supply. + 1
               then 1 else 0 end) as uncertain_invalid_supply_target,

      /* Drug-specific active flags -- name-based, tier irrelevant */
      max(case when p.is_bupropion = 1 and p.valid_supply = 1
                and p.srvc_dt <= b.index_dt
                and (p.srvc_dt + p.days_suply_num - 1) >= b.index_dt
               then 1 else 0 end) as active_bupropion_raw,
      max(case when p.is_paroxetine = 1 and p.valid_supply = 1
                and p.srvc_dt <= b.index_dt
                and (p.srvc_dt + p.days_suply_num - 1) >= b.index_dt
               then 1 else 0 end) as active_paroxetine_raw,
      max(case when p.is_fluoxetine = 1 and p.valid_supply = 1
                and p.srvc_dt <= b.index_dt
                and (p.srvc_dt + p.days_suply_num - 1) >= b.index_dt
               then 1 else 0 end) as active_fluoxetine_raw,

      /* SENSITIVITY: active at index, ANY strong-tier drug (unchanged) */
      max(case when p.tier_norm in &cyp2d6_strong_tiers.
                and p.valid_supply = 1
                and p.srvc_dt <= b.index_dt
                and (p.srvc_dt + p.days_suply_num - 1) >= b.index_dt
               then 1 else 0 end) as active_at_index_allstrong,

      /* NEW: invalid-supply uncertainty for the all-strong measure --
         was missing before, meaning a strong-tier fill with bad supply
         data was wrongly falling through to NOT_ACTIVE_OBSERVABLE */
      max(case when p.tier_norm in &cyp2d6_strong_tiers.
                and p.valid_supply = 0
                and p.srvc_dt <= b.index_dt
                and p.srvc_dt >= b.index_dt - &max_days_supply. + 1
               then 1 else 0 end) as uncertain_inv_supply_allstron,

      /* Drug-class-unknown uncertainty applies ONLY to the all-strong
         measure -- an untiered drug can't be confirmed OR ruled out as
         strong-tier. It does NOT apply to the target-drug measure, since
         target-drug identity is name-based and doesn't depend on tier.
         FIX (this round): no longer requires valid_supply=1 -- a missing-
         tier record that ALSO has invalid supply previously satisfied
         neither this check nor uncertain_inv_supply_allstron (which
         requires a confirmed strong tier), and fell through undetected to
         NOT_ACTIVE_OBSERVABLE. Now ANY untiered record in the plausible
         window is drug-class-uncertain regardless of supply validity,
         since coverage can't be assessed when the drug identity itself
         is unknown. */
      max(case when missing(p.cyp2d6_tier)
                and p.srvc_dt <= b.index_dt
                and p.srvc_dt >= b.index_dt - &max_days_supply. + 1
               then 1 else 0 end) as uncertain_drug_class_allstrong,

      /* Recent prescription, target drugs (name-based). Service date
         only -- no days-supply requirement, since a documented fill
         within the window doesn't need coverage-length validation the
         way an "active at index" claim does. (Removed the invalid-supply
         uncertainty variable that was here before: it was logically
         unreachable, since any qualifying invalid-supply record already
         satisfies is_target_drug=1 + in-window, which sets
         recent_fill_target=1 before the uncertainty check could matter.) */
      max(case when p.is_target_drug = 1
                and p.srvc_dt between (b.index_dt - &recent_fill_days. + 1) and b.index_dt
               then 1 else 0 end) as recent_fill_target

   from &t_base. b
   left join _pd_valid p
      on b.bene_id = p.bene_id
     and p.srvc_dt <= b.index_dt
     and p.srvc_dt >= b.index_dt - max(&recent_fill_days., &max_days_supply.) + 1
   group by b.bene_id, b.index_dt;
quit;

/* ===========================================================================
   STEP 3: Historical fill -- full classification window, target drugs
   (name-based, tier irrelevant, same fix as active/recent above).
   Service date only, same reasoning as recent fill above -- no days-supply
   uncertainty variable, since it would be equally unreachable.
   =========================================================================== */
proc sql;
   create table _cyp_historical as
   select b.bene_id,
          max(case when p.is_target_drug = 1
                    and p.srvc_dt >= b.classification_start_dt
                    and p.srvc_dt <= b.classification_end_dt
                   then 1 else 0 end) as historical_fill_target
   from &t_base. b
   left join _pd_valid p on b.bene_id = p.bene_id
   group by b.bene_id;
quit;

/* ===========================================================================
   STEP 4: Assemble final exposure table.
   =========================================================================== */
proc sql;
   create table _cyp_exposure as
   select r.*, o1.partd_active_window_obs, o2.partd_full_year_obs,
          o3.partd_recent_window_obs, h.historical_fill_target
   from _cyp_active_recent r
   left join _partd_obs_index o1 on r.bene_id = o1.bene_id
   left join _partd_obs_full_year o2 on r.bene_id = o2.bene_id
   left join _partd_obs_recent o3 on r.bene_id = o3.bene_id
   left join _cyp_historical h on r.bene_id = h.bene_id;
quit;

data &t_exposure.;
   set _cyp_exposure;
   array nm active_at_index_target active_at_index_allstrong
             active_bupropion_raw active_paroxetine_raw active_fluoxetine_raw
             uncertain_invalid_supply_target uncertain_inv_supply_allstron
             uncertain_drug_class_allstrong
             recent_fill_target
             historical_fill_target
             partd_active_window_obs partd_full_year_obs partd_recent_window_obs;
   do over nm; if missing(nm) then nm = 0; end;

   /* PRIMARY active-at-index status (target drugs, name-based).
      No UNKNOWN_DRUG_CLASS state -- target-drug identity is unambiguous
      by name, so the only uncertainty source is invalid days-supply. */
   length active_status $28;
   if active_at_index_target = 1 then active_status = 'ACTIVE';
   else if partd_active_window_obs = 0 then active_status = 'UNKNOWN_NO_PARTD';
   else if uncertain_invalid_supply_target = 1 then active_status = 'UNKNOWN_DAYS_SUPPLY';
   else active_status = 'NOT_ACTIVE_OBSERVABLE';

   if active_status = 'ACTIVE' then active_primary = 1;
   else if active_status = 'NOT_ACTIVE_OBSERVABLE' then active_primary = 0;
   else active_primary = .;

   /* SENSITIVITY: all-strong-tier status -- now correctly includes its
      own invalid-supply uncertainty (was missing before this round) */
   length active_status_allstrong $28;
   if active_at_index_allstrong = 1 then active_status_allstrong = 'ACTIVE';
   else if partd_active_window_obs = 0 then active_status_allstrong = 'UNKNOWN_NO_PARTD';
   else if uncertain_inv_supply_allstron = 1 then active_status_allstrong = 'UNKNOWN_DAYS_SUPPLY';
   else if uncertain_drug_class_allstrong = 1 then active_status_allstrong = 'UNKNOWN_DRUG_CLASS';
   else active_status_allstrong = 'NOT_ACTIVE_OBSERVABLE';

   if active_status_allstrong = 'ACTIVE' then active_allstrong_primary = 1;
   else if active_status_allstrong = 'NOT_ACTIVE_OBSERVABLE' then active_allstrong_primary = 0;
   else active_allstrong_primary = .;

   /* Recent fill (target drugs, name-based) */
   length recent_status $28;
   if recent_fill_target = 1 then recent_status = 'RECENT';
   else if partd_recent_window_obs = 0 then recent_status = 'UNKNOWN_NO_PARTD';
   else recent_status = 'NOT_RECENT_OBSERVABLE';

   if recent_status = 'RECENT' then recent_primary = 1;
   else if recent_status = 'NOT_RECENT_OBSERVABLE' then recent_primary = 0;
   else recent_primary = .;

   /* Historical (target drugs, full-year observability) */
   length historical_status $28;
   if historical_fill_target = 1 then historical_status = 'HISTORICAL';
   else if partd_full_year_obs = 0 then historical_status = 'UNKNOWN_NO_PARTD';
   else historical_status = 'NOT_HISTORICAL_OBSERVABLE';

   if historical_status = 'HISTORICAL' then historical_primary = 1;
   else if historical_status = 'NOT_HISTORICAL_OBSERVABLE' then historical_primary = 0;
   else historical_primary = .;

   any_unknown = (index(active_status, 'UNKNOWN') > 0
                  or index(recent_status, 'UNKNOWN') > 0
                  or index(historical_status, 'UNKNOWN') > 0);

   /* Drug-specific flags missing (not 0) when active_primary itself
      is unknown */
   if missing(active_primary) then do;
      active_bupropion = .;
      active_paroxetine = .;
      active_fluoxetine = .;
   end;
   else do;
      active_bupropion  = active_bupropion_raw;
      active_paroxetine = active_paroxetine_raw;
      active_fluoxetine = active_fluoxetine_raw;
   end;
run;

%assert_unique(&t_exposure.);
%log_counts(&t_exposure., label=ibog_fp_exposure final);

proc freq data=&t_exposure.;
   tables active_status active_status_allstrong recent_status historical_status / missing;
   title "03_exposure: Exposure status distributions (target-drug primary + all-strong sensitivity)";
run;

%put NOTE: 03_define_cyp2d6_exposure.sas complete.;
%put NOTE: Primary exposure = target drugs (bupropion/paroxetine/fluoxetine) by NAME,;
%put NOTE: independent of cyp2d6_tier. All-strong-tier retained as sensitivity.;
%put NOTE: Target-drug/tier concordance (&t_concord.) was built and should;
%put NOTE: have been reviewed during the staging audit (01_validate), before;
%put NOTE: audit_approved was set to Y.;

%mend run_03_exposure;
%run_03_exposure;

/* end 03_define_cyp2d6_exposure.sas */
