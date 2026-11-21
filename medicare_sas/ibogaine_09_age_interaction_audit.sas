/*===========================================================================
  ibogaine_09_age_interaction_audit.sas
  IFH Citrix Server - crdw-ifhsas02-prod-asb.rad.rutgers.edu
  Author : James Green
  Created: August 2026
  Purpose: (1) Audit and resolve the Analysis C age-subgroup N discrepancy
               (307,425 observed vs 307,336 expected from primary cohort)
           (2) Run the correct age-subgroup analysis: candidate vs non-candidate
               adjusted PR WITHIN each age stratum, plus a formal interaction
               test - the analysis Scott Parrott identified as necessary to
               address age-related polypharmacy as an alternative explanation
           (3) Produce a clean manuscript-ready summary table

  Key confirmed variable names (from PROC CONTENTS, Aug 2026):
    coh.ibog_fp_analysis_fp_full_v001:
      bene_id, n_qualifiers_psych, active_primary, active_allstrong_primary,
      recent_primary, historical_primary, primary_group_psych, index_dt
    iben.master_12016-12022: bene_id, BENE_BIRTH_DT

  Libname assignments (must be set before running):
    libname coh  "/path/to/your/working/directory\Working\Cohorts";
    libname iben "/path/to/your/working/directory\Ibogaine_Extraction\Output\Enrollment";

  Outputs:
    coh.ibog_09_age_base         -- full cohort (candidates + non-candidates)
                                    with age, age group, birth date join status
    coh.ibog_09_age_audit        -- N reconciliation audit table
    coh.ibog_09_age_strat_pr     -- stratum-specific adjusted PRs
    coh.ibog_09_age_interaction  -- interaction model parameter estimates
    coh.ibog_09_age_summary      -- manuscript-ready 2x2 summary table

  NOTE: This program includes only CANDIDATE and NON-CANDIDATE groups
  (primary_group_psych IN ('CANDIDATE','COMPARATOR')). The 1-qualifier
  intermediate stratum is excluded from the primary analysis consistent
  with the first-pass design.

  NOTE ON 'COMPARATOR' TERMINOLOGY: The first-pass pipeline uses the
  label 'COMPARATOR' for what the v13 manuscript calls 'non-candidates'.
  This program uses 'non-candidate' in output labels but reads the
  source variable value 'COMPARATOR' as-is.
===========================================================================*/

options nodate nonumber mprint mlogic;

/* ── Libname assignments ───────────────────────────────────────────────── */
libname coh  "/path/to/your/working/directory\Working\Cohorts";
libname iben "/path/to/your/working/directory\Ibogaine_Extraction\Output\Enrollment";

/* ── Macro parameters ──────────────────────────────────────────────────── */
%let pgm    = ibogaine_09;
%let today  = %sysfunc(today(), yymmddn8.);
%let candidate_flag = CANDIDATE;
%let comparator_flag = COMPARATOR;

/* ═══════════════════════════════════════════════════════════════════════════
   SECTION 1: BUILD BENEFICIARY AGE LOOKUP FROM ENROLLMENT FILES
   Identical logic to 08c but now confirmed correct - use UNION (not
   UNION ALL) so each bene appears once with a consistent birth date.
   ═══════════════════════════════════════════════════════════════════════════ */

%put NOTE: [09 Section 1] Building bene-level birth date lookup...;

proc sql;
    create table _09_bene_age as
    select bene_id, bene_birth_dt
    from iben.master_12016
    union
    select bene_id, bene_birth_dt
    from iben.master_12017
    union
    select bene_id, bene_birth_dt
    from iben.master_12018
    union
    select bene_id, bene_birth_dt
    from iben.master_12019
    union
    select bene_id, bene_birth_dt
    from iben.master_12020
    union
    select bene_id, bene_birth_dt
    from iben.master_12021
    union
    select bene_id, bene_birth_dt
    from iben.master_12022;
quit;

/* Quick count to verify deduplication */
proc sql;
    select count(*) as n_bene_age_lookup,
           count(distinct bene_id) as n_unique_bene
    from _09_bene_age;
quit;

%put NOTE: [09 Section 1] Birth date lookup complete.;


/* ═══════════════════════════════════════════════════════════════════════════
   SECTION 2: BUILD THE FULL ANALYTIC BASE - BOTH GROUPS
   Key difference from Analysis C: includes BOTH candidates AND non-candidates.
   This is required for the candidate-vs-non-candidate PR within each stratum.
   ═══════════════════════════════════════════════════════════════════════════ */

%put NOTE: [09 Section 2] Building full analytic base (candidates + non-candidates)...;

proc sql;
    create table _09_base_raw as
    select
        a.bene_id,
        a.primary_group_psych,
        a.active_primary,           /* binary: 1=active strong CYP2D6 inhibitor at index */
        a.active_allstrong_primary, /* binary: all strong inhibitors */
        a.n_qualifiers_psych,
        a.index_dt,
        b.bene_birth_dt,

        /* Age at index: floor to integer years */
        floor((a.index_dt - b.bene_birth_dt) / 365.25) as age_at_index,

        /* Flag whether birth date was found in enrollment files */
        case when b.bene_birth_dt is null then 1 else 0 end as birth_dt_missing,

        /* Age group: <65 = SSDI-eligible, >=65 = age-eligible */
        case
            when b.bene_birth_dt is null then 'Unknown'
            when floor((a.index_dt - b.bene_birth_dt) / 365.25) < 65
                then 'Under65'
            else 'Age65plus'
        end as age_group length=10,

        /* Binary age indicator for regression */
        case
            when b.bene_birth_dt is null then .
            when floor((a.index_dt - b.bene_birth_dt) / 365.25) < 65 then 0
            else 1
        end as age_ge65,

        /* Candidate indicator for regression (1=candidate, 0=non-candidate) */
        case
            when a.primary_group_psych = "&candidate_flag" then 1
            else 0
        end as is_candidate

    from coh.ibog_fp_analysis_fp_full_v001 a
    left join _09_bene_age b
        on a.bene_id = b.bene_id

    where a.primary_group_psych in ("&candidate_flag", "&comparator_flag");
quit;

%put NOTE: [09 Section 2] Raw base built. Proceeding to audit.;


/* ═══════════════════════════════════════════════════════════════════════════
   SECTION 3: AUDIT - RECONCILE N DISCREPANCY FROM ANALYSIS C
   Expected: 307,336 candidates + 283,434 non-candidates = 590,770 total
   Analysis C reported: 179,394 + 128,031 = 307,425 candidates (89 over)
   This audit finds where the 89 extra come from.
   ═══════════════════════════════════════════════════════════════════════════ */

%put NOTE: [09 Section 3] Running N reconciliation audit...;

/* Overall group counts */
proc sql;
    create table _09_audit_groups as
    select
        primary_group_psych                              as group_label,
        count(*)                                         as n_total,
        sum(birth_dt_missing)                           as n_missing_birthdt,
        count(*) - sum(birth_dt_missing)                as n_with_birthdt,
        sum(case when age_group='Under65'   then 1 else 0 end) as n_under65,
        sum(case when age_group='Age65plus' then 1 else 0 end) as n_age65plus,
        sum(case when age_group='Unknown'   then 1 else 0 end) as n_unknown_age,
        sum(case when age_at_index < 0      then 1 else 0 end) as n_negative_age,
        sum(case when age_at_index >= 0
               and age_at_index < 65       then 1 else 0 end) as n_calc_under65,
        sum(case when age_at_index >= 65    then 1 else 0 end) as n_calc_65plus,
        min(age_at_index) as age_min,
        max(age_at_index) as age_max,
        mean(age_at_index) as age_mean
    from _09_base_raw
    group by primary_group_psych;
quit;

/* Print the audit - this is the key diagnostic output */
title "09 AUDIT: Group-level N reconciliation";
title2 "Expected candidates: 307,336 | Expected non-candidates: 283,434";
title3 "Analysis C reported candidates: 179,394 + 128,031 = 307,425 (89 excess)";
proc print data=_09_audit_groups noobs label;
    var group_label n_total n_missing_birthdt n_with_birthdt
        n_under65 n_age65plus n_unknown_age n_negative_age
        n_calc_under65 n_calc_65plus age_min age_mean age_max;
    label
        group_label     = "Group"
        n_total         = "N Total"
        n_missing_birthdt = "N Missing Birth Dt"
        n_with_birthdt  = "N with Birth Dt"
        n_under65       = "N Under 65 (age_group)"
        n_age65plus     = "N 65+ (age_group)"
        n_unknown_age   = "N Unknown Age (missing birth dt)"
        n_negative_age  = "N with Negative Age (data error)"
        n_calc_under65  = "N Age<65 (numeric calc)"
        n_calc_65plus   = "N Age>=65 (numeric calc)"
        age_min         = "Age Min"
        age_mean        = "Age Mean"
        age_max         = "Age Max";
run;
title;

/* Check for duplicate bene_ids in base - another source of N inflation */
proc sql;
    select
        "Duplicate bene check" as check_label,
        count(*) as n_rows,
        count(distinct bene_id) as n_unique_bene,
        count(*) - count(distinct bene_id) as n_duplicates
    from _09_base_raw
    where primary_group_psych = "&candidate_flag";
quit;

/* Save the audit table permanently */
data coh.ibog_09_age_audit;
    set _09_audit_groups;
run;

%put NOTE: [09 Section 3] Audit complete. Review output above before proceeding.;


/* ═══════════════════════════════════════════════════════════════════════════
   SECTION 4: BUILD CLEAN ANALYTIC DATASET
   Excludes records with missing birth date (unknown age group).
   These will be reported in the audit but excluded from the PR analysis.
   Records with negative calculated age are also flagged.
   ═══════════════════════════════════════════════════════════════════════════ */

%put NOTE: [09 Section 4] Building clean analytic dataset...;

proc sort data=_09_base_raw 
		  out=_09_base_dedup
		  nodupkey;
		  by bene_id ;
run;




data _09_analytic;
    set _09_base_dedup;

    /* Exclude if birth date missing (cannot classify age) */
    if birth_dt_missing = 1 then delete;

    /* Flag implausible ages - keep in data but flag */
    if age_at_index < 0 then age_implausible = 1;
    else if age_at_index > 110 then age_implausible = 1;
    else age_implausible = 0;

run;

/* Verify final analytic N */
proc sql;
    select primary_group_psych, age_group,
           count(*) as n,
           sum(active_primary) as n_exposed,
           sum(active_primary) / count(*) as pct_exposed format=percent8.2
    from _09_analytic
    where age_implausible = 0
    group by primary_group_psych, age_group
    order by primary_group_psych, age_group;
quit;

/* Save permanent base */
data coh.ibog_09_age_base;
    set _09_analytic;
run;

%put NOTE: [09 Section 4] Clean analytic dataset built and saved to coh.ibog_09_age_base.;


/* ═══════════════════════════════════════════════════════════════════════════
   SECTION 5: DESCRIPTIVE SUMMARY TABLE
   Replicates the Analysis C format but correctly for BOTH groups.
   Manuscript Table: strong inhibitor exposure by age group and cohort group.
   ═══════════════════════════════════════════════════════════════════════════ */

%put NOTE: [09 Section 5] Running descriptive summary...;

proc sql;
    create table coh.ibog_09_age_summary as
    select
        primary_group_psych                              as cohort_group,
        age_group,
        count(*)                                         as n_total,
        sum(active_primary)                              as n_exposed,
        sum(active_primary) / count(*)                   as prevalence,
        (sum(active_primary) / count(*))
            - 1.96 * sqrt((sum(active_primary)/count(*)) *
                          (1 - sum(active_primary)/count(*)) /
                          count(*) )                     as ci_lower,
        (sum(active_primary) / count(*))
            + 1.96 * sqrt((sum(active_primary)/count(*)) *
                          (1 - sum(active_primary)/count(*)) /
                          count(*) )                     as ci_upper,
        min(age_at_index) as age_min,
        mean(age_at_index) as age_mean,
        max(age_at_index) as age_max
    from _09_analytic
    where age_implausible = 0
    group by primary_group_psych, age_group
    order by primary_group_psych, age_group;
quit;

title "09 Table: CYP2D6 inhibitor exposure by cohort group and age stratum";
title2 "Primary exposure: active_primary (active strong CYP2D6 inhibitor at index date)";
proc print data=coh.ibog_09_age_summary noobs label;
    format prevalence ci_lower ci_upper percent8.2 age_mean 8.1;
    label
        cohort_group = "Cohort Group"
        age_group    = "Age Stratum"
        n_total      = "N"
        n_exposed    = "N Exposed"
        prevalence   = "Prevalence"
        ci_lower     = "95% CI Lower (Wald)"
        ci_upper     = "95% CI Upper (Wald)"
        age_min      = "Age Min"
        age_mean     = "Age Mean"
        age_max      = "Age Max";
run;
title;


/* ═══════════════════════════════════════════════════════════════════════════
   SECTION 6: STRATUM-SPECIFIC ADJUSTED PREVALENCE RATIOS
   Runs log-Poisson regression (PROC GENMOD) separately within each
   age stratum, estimating candidate vs non-candidate PR adjusted for
   age (continuous, within-stratum), sex, and RTI race.

   NOTE: Age, sex, and RTI race must be available in the first-pass
   analysis table or must be merged in from a demographic source.
   This program assumes they are present in coh.ibog_fp_analysis_fp_full_v001
   as variables: age_at_index (derived above), sex (if available), rti_race.
   If sex and rti_race are not in the first-pass table, this step will
   need a merge from the denominator file. A %put diagnostic will flag
   this if the variables are missing.

   If demographic covariates are unavailable in the source table, the
   unadjusted PR is run instead and labeled accordingly.
   ═══════════════════════════════════════════════════════════════════════════ */

%put NOTE: [09 Section 6] Running stratum-specific adjusted PRs...;

/* First check whether sex and rti_race exist in the analytic dataset */
proc contents data=_09_analytic out=_09_contents noprint; run;

proc sql noprint;
    select count(*) into :has_sex
    from _09_contents
    where upcase(name) = 'SEX';

    select count(*) into :has_race
    from _09_contents
    where upcase(name) in ('RTI_RACE', 'RTI_RACE_CD');
quit;

%put NOTE: has_sex=&has_sex has_race=&has_race;

/* ── Under-65 stratum PR ─────────────────────────────────────────────── */
title "09 Stratum PR: Under 65 (SSDI-eligible) - Candidate vs Non-candidate";
title2 "Outcome: active strong CYP2D6 inhibitor at index (active_primary)";
title3 "Model: log-Poisson with offset=0; adjustment for age (continuous within stratum)";

%if &has_sex > 0 and &has_race > 0 %then %do;
    proc genmod data=_09_analytic(where=(age_group='Under65' and age_implausible=0));
        class primary_group_psych (ref="&comparator_flag") rti_race sex;
        model active_primary = primary_group_psych age_at_index sex rti_race
              / dist=poisson link=log;
        estimate "Candidate vs Non-candidate PR (age<65)"
                 primary_group_psych 1 -1 / exp;
        ods output estimates=_09_pr_u65_adj parameterestimates=_09_pe_u65_adj;
    run;
%end;
%else %do;
    %put NOTE: Sex or race not found in analytic table - running age-only adjusted model for under-65 stratum.;
    proc genmod data=_09_analytic(where=(age_group='Under65' and age_implausible=0));
        class primary_group_psych (ref="&comparator_flag");
        model active_primary = primary_group_psych age_at_index
              / dist=poisson link=log;
        estimate "Candidate vs Non-candidate PR (age<65, age-adjusted)"
                 primary_group_psych 1 -1 / exp;
        ods output estimates=_09_pr_u65_adj parameterestimates=_09_pe_u65_adj;
    run;
%end;
title;

/* ── 65-and-older stratum PR ─────────────────────────────────────────── */
title "09 Stratum PR: 65 and older - Candidate vs Non-candidate";
title2 "Outcome: active strong CYP2D6 inhibitor at index (active_primary)";

%if &has_sex > 0 and &has_race > 0 %then %do;
    proc genmod data=_09_analytic(where=(age_group='Age65plus' and age_implausible=0));
        class primary_group_psych (ref="&comparator_flag") rti_race sex;
        model active_primary = primary_group_psych age_at_index sex rti_race
              / dist=poisson link=log;
        estimate "Candidate vs Non-candidate PR (age>=65)"
                 primary_group_psych 1 -1 / exp;
        ods output estimates=_09_pr_65p_adj parameterestimates=_09_pe_65p_adj;
    run;
%end;
%else %do;
    %put NOTE: Sex or race not found - running age-only adjusted model for 65+ stratum.;
    proc genmod data=_09_analytic(where=(age_group='Age65plus' and age_implausible=0));
        class primary_group_psych (ref="&comparator_flag");
        model active_primary = primary_group_psych age_at_index
              / dist=poisson link=log;
        estimate "Candidate vs Non-candidate PR (age>=65, age-adjusted)"
                 primary_group_psych 1 -1 / exp;
        ods output estimates=_09_pr_65p_adj parameterestimates=_09_pe_65p_adj;
    run;
%end;
title;

/* Stack the stratum PRs for easy comparison */
data _09_pr_stacked;
    length stratum $12 estimate_label $60;
    set
        _09_pr_u65_adj (in=a)
        _09_pr_65p_adj (in=b);
    if a then stratum = 'Under65';
    if b then stratum = 'Age65plus';
run;

title "09 Stratum PR Summary: Candidate vs Non-candidate by Age Group";
proc print data=_09_pr_stacked noobs; run;
title;

data coh.ibog_09_age_strat_pr;
    set _09_pr_stacked;
run;


/* ═══════════════════════════════════════════════════════════════════════════
   SECTION 7: FORMAL INTERACTION TEST
   Tests whether the candidate-vs-non-candidate PR differs between
   age strata. A non-significant interaction p-value (p>0.05) supports
   the interpretation that the association is consistent across age groups.
   A significant interaction would mean age IS a moderator and requires
   stratum-specific reporting.

   The interaction term is: is_candidate * age_ge65
   Primary contrast: is_candidate (1=candidate, 0=non-candidate)
   Moderator: age_ge65 (1=65+, 0=under 65)
   ═══════════════════════════════════════════════════════════════════════════ */

%put NOTE: [09 Section 7] Running formal age-by-group interaction test...;

title "09 Interaction Model: Candidate * Age Group on CYP2D6 Inhibitor Exposure";
title2 "Outcome: active_primary | Primary contrast: is_candidate | Moderator: age_ge65";
title3 "Interaction term p-value is the key inferential test for age moderation";

%if &has_sex > 0 and &has_race > 0 %then %do;
    proc genmod data=_09_analytic(where=(age_implausible=0 and age_ge65 ne .));
        class rti_race sex;
        model active_primary = is_candidate age_ge65 is_candidate*age_ge65
                               age_at_index sex rti_race
              / dist=poisson link=log;
        ods output parameterestimates=_09_interaction_pe
                   modelinfo=_09_interaction_info;
    run;
%end;
%else %do;
    %put NOTE: Sex or race not found - running age-only covariate interaction model.;
    proc genmod data=_09_analytic(where=(age_implausible=0 and age_ge65 ne .));
        model active_primary = is_candidate age_ge65 is_candidate*age_ge65
                               age_at_index
              / dist=poisson link=log;
        ods output parameterestimates=_09_interaction_pe
                   modelinfo=_09_interaction_info;
    run;
%end;
title;

/* Print interaction term specifically */
title "09 Interaction Term: is_candidate * age_ge65";
title2 "Non-significant (p>0.05) = consistent association across age strata";
proc print data=_09_interaction_pe noobs;
    where index(upcase(parameter), 'IS_CANDIDATE') > 0
       or index(upcase(parameter), 'AGE_GE65') > 0;
    var parameter estimate stderr lowerci upperci probchisq;
run;
title;

data coh.ibog_09_age_interaction;
    set _09_interaction_pe;
run;

%put NOTE: [09 Section 7] Interaction test complete.;


/* ═══════════════════════════════════════════════════════════════════════════
   SECTION 8: FINAL MANUSCRIPT TABLE
   Structured to directly replace the current v13 eTable 4 placeholder.
   Shows: N, N exposed, prevalence, 95% CI by cohort group x age stratum,
   plus the stratum-specific PRs and interaction p-value.
   ═══════════════════════════════════════════════════════════════════════════ */

%put NOTE: [09 Section 8] Building manuscript-ready output table...;

proc sql;
    create table _09_mstable as
    select
        primary_group_psych as cohort_group,
        case
            when age_group = 'Under65'   then 'Under 65 (SSDI-eligible)'
            when age_group = 'Age65plus' then '65 and older'
            else 'Unknown'
        end as age_stratum length=25,
        count(*)                                         as n_total,
        sum(active_primary)                              as n_exposed,
        sum(active_primary) / count(*) * 100            as pct_exposed,
        (sum(active_primary) / count(*) -
            1.96 * sqrt((sum(active_primary)/count(*)) *
                        (1 - sum(active_primary)/count(*)) /
                        count(*) )) * 100                as ci_lower_pct,
        (sum(active_primary) / count(*) +
            1.96 * sqrt((sum(active_primary)/count(*)) *
                        (1 - sum(active_primary)/count(*)) /
                        count(*) )) * 100                as ci_upper_pct,
        min(age_at_index)                                as age_min,
        mean(age_at_index)                               as age_mean,
        max(age_at_index)                                as age_max
    from _09_analytic
    where age_implausible = 0
    group by primary_group_psych,
             case
                when age_group = 'Under65'   then 'Under 65 (SSDI-eligible)'
                when age_group = 'Age65plus' then '65 and older'
                else 'Unknown'
             end
    order by
        case when primary_group_psych = "&candidate_flag" then 1 else 2 end,
        case when age_group = 'Under65' then 1 else 2 end;
quit;

title "09 MANUSCRIPT TABLE: CYP2D6 Inhibitor Exposure by Cohort Group and Age Stratum";
title2 "Medicare FFS 2016-2022 | Primary exposure: active strong CYP2D6 inhibitor at index date";
title3 "Stratum-specific adjusted PRs and interaction test results in coh.ibog_09_age_strat_pr and coh.ibog_09_age_interaction";
proc print data=_09_mstable noobs label;
    format pct_exposed ci_lower_pct ci_upper_pct 8.2 age_mean 8.1;
    var cohort_group age_stratum n_total n_exposed
        pct_exposed ci_lower_pct ci_upper_pct
        age_min age_mean age_max;
    label
        cohort_group   = "Cohort Group"
        age_stratum    = "Age Stratum"
        n_total        = "N"
        n_exposed      = "N Exposed"
        pct_exposed    = "Prevalence (%)"
        ci_lower_pct   = "95% CI Lower (%)"
        ci_upper_pct   = "95% CI Upper (%)"
        age_min        = "Age Min"
        age_mean       = "Age Mean"
        age_max        = "Age Max";
run;
title;

/* Verify N sums match primary cohort */
proc sql;
    select
        "N reconciliation check"        as check,
        sum(case when primary_group_psych="&candidate_flag"   then n_total else 0 end) as cand_n,
        sum(case when primary_group_psych="&comparator_flag"  then n_total else 0 end) as comp_n,
        sum(n_total) as total_n
    from _09_mstable
    where age_stratum ne 'Unknown';
quit;

%put NOTE: [09 Section 8] Manuscript table complete.;
%put NOTE: Expected candidate N: 307,336 | Expected non-candidate N: 283,434;
%put NOTE: If sums above do not match, review Section 3 audit output to identify source of discrepancy.;


/* ═══════════════════════════════════════════════════════════════════════════
   SECTION 9: ADDITIONAL DIAGNOSTICS FOR MANUSCRIPT
   These address the remaining open questions from Scott's review.
   ═══════════════════════════════════════════════════════════════════════════ */

%put NOTE: [09 Section 9] Running additional diagnostics...;

/* 9a: Distribution of days-supply remaining (Table 5 clarification)
   Confirms whether 22-23 days is a patient-level median or drug-specific range */
/* NOTE: This requires the prescription-level data from the washout analysis.
   If coh.ibog_06a_active_v2 or the equivalent washout table is available,
   run the following. Otherwise comment out. */

/*
proc means data=coh.ibog_06a_active_v2 n median p25 p75;
    where cohort_group = "&candidate_flag";
    class drug_name;
    var days_remaining;
    title "09 Diagnostic: Median days remaining by drug - clarifies Table 5 22-23 day range";
run;
*/

/* 9b: Verify 2+ concurrent inhibitor count in non-candidates
   Addresses Scott's "Not applicable" vs "Not reported" question */
proc sql;
    create table _09_concurrent_check as
    select
        primary_group_psych,
        count(*) as n_with_any_active,
        sum(case when active_allstrong_primary >= 2 then 1 else 0 end)
            as n_two_plus_concurrent,
        sum(case when active_allstrong_primary >= 2 then 1 else 0 end) /
            count(*) * 100 as pct_two_plus
    from _09_analytic
    where active_primary = 1
      and age_implausible = 0;
quit;

title "09 Diagnostic: 2+ concurrent active inhibitors - both groups";
title2 "Addresses whether 'Not applicable' or 'Not reported' is correct for non-candidates";
proc print data=_09_concurrent_check noobs; run;
title;

/* 9c: Implausible age counts - both groups */
proc sql;
    select primary_group_psych,
           sum(age_implausible) as n_implausible,
           min(age_at_index) as age_min,
           max(age_at_index) as age_max
    from _09_analytic
    group by primary_group_psych;
quit;

%put NOTE: [09 Section 9] Additional diagnostics complete.;


/* ═══════════════════════════════════════════════════════════════════════════
   SECTION 10: CLEAN UP WORK TABLES
   ═══════════════════════════════════════════════════════════════════════════ */

proc datasets library=work nolist;
    delete _09_base_raw _09_analytic _09_bene_age
           _09_audit_groups _09_contents _09_mstable
           _09_pr_stacked _09_pr_u65_adj _09_pr_65p_adj
           _09_pe_u65_adj _09_pe_65p_adj
           _09_interaction_pe _09_interaction_info
           _09_concurrent_check;
quit;

%put NOTE: ============================================================;
%put NOTE: ibogaine_09_age_interaction_audit.sas COMPLETE;
%put NOTE: Permanent outputs written to COH library:;
%put NOTE:   coh.ibog_09_age_audit        -- N reconciliation audit;
%put NOTE:   coh.ibog_09_age_base         -- full analytic dataset;
%put NOTE:   coh.ibog_09_age_summary      -- descriptive summary;
%put NOTE:   coh.ibog_09_age_strat_pr     -- stratum-specific PRs;
%put NOTE:   coh.ibog_09_age_interaction  -- interaction model output;
%put NOTE: ============================================================;


proc sql; 
create table _audit_extra as
select a.bene_id, a.primary_group_psych
from coh.ibog_fp_analysis_fp_full_v001 a
where a.primary_group_psych in ('CANDIDATE', 'COMPARATOR')
	and a.bene_id not in 
		(select bene_id from coh.ibog_07a_patientlevel);


select primary_group_psych, count(*) as n_extra
from _audit_extra
group by 1;

quit;

proc sql;
select cohort_group, count(*) as n_inprimaryonly
from coh.ibog_07a_patientlevel
where bene_id not in (select bene_id 
	from coh.ibog_fp_analysis_fp_full_v001
		where primary_group_psych in  ('CANDIDATE', 'COMPARATOR'))
group by 1;
quit;

proc sql;
select primary_group_psych, count(*) as n_extra
from coh.ibog_fp_analysis_fp_full_v001
where primary_group_psych in  ('CANDIDATE', 'COMPARATOR')
	and cats(bene_id) not in (select cats(bene_id) from coh.ibog_07a_patientlevel)
group by 1;
quit;
		

proc sql;
select  count(*) as n_inprimaryonly
from coh.ibog_07a_patientlevel
where cats(bene_id) not in (select cats(bene_id )
	from coh.ibog_fp_analysis_fp_full_v001
		where primary_group_psych in  ('CANDIDATE', 'COMPARATOR'));
quit;	


proc sql;
select 'fp_full' as tbl,
count(*) as n_rows,
count(distinct bene_id) as n_unq
from coh.ibog_fp_analysis_fp_full_v001
where primary_group_psych in  ('CANDIDATE', 'COMPARATOR')
union all
select 'patientlevel' as tbl,
count(*) as n_rows,
count(distinct bene_id) as n_unq
from coh.ibog_07a_patientlevel;
quit;