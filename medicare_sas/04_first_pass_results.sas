/******************************************************************************
PROGRAM  : 04_first_pass_results.sas
VERSION  : fp_v006 (fixes: item 20 prevalence differences/ratios/CIs,
           item 21 sensitivities saved to t_sensitivity, item 22 denominator
           wording, item 23 write t_analysis)
******************************************************************************/

%put NOTE: 04_first_pass_results.sas starting...;
%require_dataset(&t_base.,     context=04_results needs 02_build);
%require_dataset(&t_exposure., context=04_results needs 03_exposure);

%macro run_04_results;

/* Merge and write the analysis table (item 23 fix).
   Explicit 1:1 verification -- not just post-merge uniqueness -- confirms
   every base beneficiary matched exactly one exposure record. */
%local n_base_check n_exp_check n_matched;
proc sql noprint;
   select count(*) into :n_base_check trimmed from &t_base.;
   select count(*) into :n_exp_check trimmed from &t_exposure.;
quit;

/* Direct check: exposure table should have exactly one row per base
   beneficiary. If it has extras (e.g. from an unintended duplicate join
   somewhere upstream), that's a problem worth catching here directly,
   not just inferring indirectly from whether every base row later
   matched something. */
%if &n_exp_check. ne &n_base_check. %then
   %ibog_stop(Exposure table row count &n_exp_check. does not match base table row count &n_base_check. - investigate before merging.);
%put NOTE: PASS -- exposure table row count matches base table row count (&n_base_check.).;

proc sql;
   create table _analysis as
   select b.*, e.active_status, e.active_primary,
          e.active_status_allstrong, e.active_allstrong_primary,
          e.recent_status, e.recent_primary,
          e.historical_status, e.historical_primary,
          e.active_bupropion, e.active_paroxetine, e.active_fluoxetine,
          e.any_unknown, e.partd_active_window_obs, e.partd_full_year_obs
   from &t_base. b
   left join &t_exposure. e on b.bene_id = e.bene_id;
quit;

proc sql noprint;
   select count(*) into :n_matched trimmed
   from _analysis where not missing(active_status);
quit;
%if &n_matched. ne &n_base_check. %then
   %ibog_stop(Merge mismatch -- &n_base_check. base benes but only &n_matched. matched
              an exposure record (exposure table has &n_exp_check. rows). Investigate
              before trusting results.);
%put NOTE: Merge verified 1:1 -- all &n_base_check. base beneficiaries matched exposure.;

%assert_unique(_analysis);

data &t_analysis.;
   set _analysis;
run;
%log_counts(&t_analysis., label=ibog_fp_analysis written);

/* ===========================================================================
   PRIMARY RESULT: Full qualifier-count gradient with explicit denominators
   Reported separately for each exposure measure.
   active_primary, recent_primary, historical_primary are MISSING (not 0)
   for unknown cases, so mean() over them gives prevalence among classifiable
   only -- which is the right denominator for a clinical estimate.
   ===========================================================================*/

/* Helper macro: gradient table for one exposure variable and qualifier def */
%macro gradient_table(exp_var=, exp_label=, qual_var=, qual_label=, outds=);
   proc sql;
      create table &outds. as
      select "&qual_label." as qualifier_definition length=20,
             "&exp_label."  as exposure_measure     length=32,
             &qual_var.     as qualifier_count,
             count(*)       as n_total,
             sum(&exp_var. = 1)      as n_exposed,
             sum(&exp_var. = 0)      as n_unexposed,
             count(&exp_var.)        as n_classifiable,
             (count(*) - count(&exp_var.)) as n_unknown,
             mean(&exp_var.)         as pct_exposed_classifiable format=percent8.1
      from _analysis
      group by &qual_var.;
   quit;
%mend;

%gradient_table(exp_var=active_primary, exp_label=Active at index,
                qual_var=n_qualifiers_psych, qual_label=PSYCH_ONLY,
                outds=_g1);
%gradient_table(exp_var=recent_primary, exp_label=Recent 90d,
                qual_var=n_qualifiers_psych, qual_label=PSYCH_ONLY,
                outds=_g2);
%gradient_table(exp_var=historical_primary, exp_label=Historical class. yr,
                qual_var=n_qualifiers_psych, qual_label=PSYCH_ONLY,
                outds=_g3);
%gradient_table(exp_var=active_primary, exp_label=Active at index,
                qual_var=n_qualifiers_psych_moud_class, qual_label=PSYCH_PLUS_MOUD,
                outds=_g4);

data &t_gradient.;
   set _g1 _g2 _g3 _g4;
run;

proc print data=&t_gradient. noobs label;
   title "FIRST-PASS RESULT: Exposure gradient by qualifier count";
   title2 "pct_exposed_classifiable = among classifiable only (excludes unknown Part D)";
run;

/* ===========================================================================
   ITEM 20 FIX (and item 7 correction): Candidate vs comparator contrast.
   CI is an approximate (unpooled Wald) interval for the difference --
   NOT an exact or Newcombe/Wilson interval; labeled accurately below.
   No ratio CI is computed (would need a log-scale derivation not done here).
   The comparator row is the REFERENCE and does not get a self-comparison
   difference/ratio/CI -- only the candidate row shows those, computed
   against the comparator's prevalence.
   =========================================================================== */
%macro contrast_table(exp_var=, exp_label=, qual_var=, qual_label=, outds=);
   proc sql;
      create table _ct_&exp_var. as
      select &qual_var. as group length=12, "&qual_label." as qual_def length=20,
             "&exp_label." as exposure length=32,
             count(*) as n_total,
             sum(&exp_var. = 1) as n_exposed,
             count(&exp_var.) as n_classifiable,
             (count(*) - count(&exp_var.)) as n_unknown,
             ((count(*) - count(&exp_var.)) / count(*)) as pct_unknown format=percent8.1,
             mean(&exp_var.) as prev format=best12.
      from _analysis
      where &qual_var. in ('CANDIDATE','COMPARATOR')
      group by &qual_var.;
   quit;

   /* Group-existence and nonzero-classifiable safeguard -- without this,
      a test sample with no comparator (or no classifiable comparator)
      would silently produce an empty or divide-by-zero contrast. */
   %local n_cand_rows n_comp_rows n_cand_class n_comp_class;
   proc sql noprint;
      select count(*) into :n_cand_rows trimmed from _ct_&exp_var. where group='CANDIDATE';
      select count(*) into :n_comp_rows trimmed from _ct_&exp_var. where group='COMPARATOR';
      select coalesce(n_classifiable,0) into :n_cand_class trimmed
         from _ct_&exp_var. where group='CANDIDATE';
      select coalesce(n_classifiable,0) into :n_comp_class trimmed
         from _ct_&exp_var. where group='COMPARATOR';
   quit;
   %if &n_cand_rows. = 0 or &n_comp_rows. = 0 %then %do;
      %put WARNING: contrast_table &outds. -- CANDIDATE or COMPARATOR group has;
      %put WARNING: zero beneficiaries for &qual_var./&exp_var.. Skipping this contrast.;
      data &outds.; length group $12 qual_def $20 exposure $32; stop; run;
      %return;
   %end;
   %if &n_cand_class. = 0 or &n_comp_class. = 0 %then %do;
      %put WARNING: contrast_table &outds. -- CANDIDATE or COMPARATOR has zero;
      %put WARNING: CLASSIFIABLE beneficiaries for &qual_var./&exp_var. (all unknown).;
      %put WARNING: Prevalence/CI would divide by zero -- skipping this contrast.;
      data &outds.; length group $12 qual_def $20 exposure $32; stop; run;
      %return;
   %end;

   proc sql;
      create table &outds. as
      select c.group,
             /* Neutral label per review -- prevents the output from being
                read as evidence these beneficiaries sought or qualified
                for ibogaine. */
             case when c.group = 'CANDIDATE' then '2+ psych qualifiers'
                  when c.group = 'COMPARATOR' then '0 psych qualifiers'
             end as group_label length=24,
             c.qual_def, c.exposure,
             c.n_total, c.n_exposed, c.n_classifiable, c.n_unknown,
             c.pct_unknown,
             c.prev as prevalence format=percent8.1,
             case when c.group = 'CANDIDATE' then (c.prev - r.prev) else . end
                as prev_diff format=percent8.1,
             case when c.group = 'CANDIDATE' and r.prev > 0 then c.prev / r.prev else . end
                as prev_ratio format=8.2,
             /* Approximate (unpooled Wald) 95% CI for the difference --
                not exact, not Newcombe/Wilson. Adequate for a first-pass
                descriptive estimate; a manuscript-grade analysis should
                use a modified Poisson model with robust variance instead. */
             case when c.group = 'CANDIDATE' then
                (c.prev - r.prev) - 1.96 * sqrt(
                   c.prev*(1-c.prev)/c.n_classifiable +
                   r.prev*(1-r.prev)/r.n_classifiable)
             else . end as diff_ci_lo_wald format=percent8.1,
             case when c.group = 'CANDIDATE' then
                (c.prev - r.prev) + 1.96 * sqrt(
                   c.prev*(1-c.prev)/c.n_classifiable +
                   r.prev*(1-r.prev)/r.n_classifiable)
             else . end as diff_ci_hi_wald format=percent8.1,
             case when c.group = 'COMPARATOR' then 'REFERENCE' else '' end
                as group_role length=10
      from _ct_&exp_var. c
      cross join (select prev, n_classifiable from _ct_&exp_var.
                  where group = 'COMPARATOR') r
      order by group;
   quit;
%mend;

%contrast_table(exp_var=active_primary, exp_label=Active at index,
                qual_var=primary_group_psych, qual_label=PSYCH_ONLY, outds=_c1);
%contrast_table(exp_var=recent_primary, exp_label=Recent 90d,
                qual_var=primary_group_psych, qual_label=PSYCH_ONLY, outds=_c2);
%contrast_table(exp_var=historical_primary, exp_label=Historical class. yr,
                qual_var=primary_group_psych, qual_label=PSYCH_ONLY, outds=_c3);

data &t_table1.;
   set _c1 _c2 _c3;
run;

proc print data=&t_table1. noobs label;
   title "FIRST-PASS RESULT: 2+ Psychiatric Qualifiers vs 0 Psychiatric Qualifiers (psych-only, classifiable benes)";
   title2 "(item 22 fix) Each group row uses its own classifiable denominator";
run;

/* ===========================================================================
   ITEM 21 FIX: Prespecified sensitivities -- all saved to t_sensitivity.
   ITEM 6 FIX: group_var= parameter added so the psych+MOUD sensitivity
   actually groups by primary_group_psych_moud instead of silently using
   primary_group_psych for every scenario regardless of what was intended.
   =========================================================================== */
%macro sens_contrast(filter_where=, scenario=, exp_var=, group_var=primary_group_psych, outds=);
   proc sql;
      create table _s_&outds. as
      select "&scenario." as scenario length=60,
             &group_var. as group length=12,
             count(*) as n_total,
             sum(&exp_var. = 1) as n_exposed,
             count(&exp_var.) as n_classifiable,
             mean(&exp_var.) as prevalence format=percent8.1
      from _analysis
      where &group_var. in ('CANDIDATE','COMPARATOR')
        and (&filter_where.)
      group by &group_var.;
   quit;

   /* Lighter-weight than contrast_table's guard since these are
      exploratory sensitivities, not the primary result -- warn if a
      group is missing rather than hard-stop, since a small test sample
      not exercising every sensitivity branch is expected and informative. */
   %local n_rows_&outds.;
   proc sql noprint;
      select count(*) into :n_rows_&outds. trimmed from _s_&outds.;
   quit;
   %if &&n_rows_&outds.. < 2 %then %do;
      %put WARNING: sens_contrast &outds. (&scenario.) -- fewer than 2 groups;
      %put WARNING: present. This sensitivity may be uninterpretable for this run.;
   %end;
%mend;

%sens_contrast(filter_where=anchor_type = 'OUD_DX',
               scenario=OUD-diagnosis anchor only,
               exp_var=active_primary, outds=s1);
%sens_contrast(filter_where=(anchor_type = 'MOUD' or anchor_type = 'BOTH'),
               scenario=MOUD anchor shown separately,
               exp_var=active_primary, outds=s2);
%sens_contrast(filter_where=partd_active_window_obs = 1,
               scenario=Complete Part D observability,
               exp_var=active_primary, outds=s3);
%sens_contrast(filter_where=1=1,
               scenario=All eligible - recent 90d fill,
               exp_var=recent_primary, outds=s4);
%sens_contrast(filter_where=1=1,
               scenario=All eligible - historical fill,
               exp_var=historical_primary, outds=s5);
/* ITEM 6 FIX: relabeled to accurately describe the logic. This is NOT a
   complete-case analysis that excludes every MOUD_UNKNOWN beneficiary --
   someone with >=2 psychiatric qualifiers is RETAINED as a candidate
   even when their MOUD status is unknown, since psych qualifiers alone
   already determine candidacy regardless of MOUD. Only beneficiaries
   with <2 psych qualifiers AND unknown MOUD become UNCLASSIFIED (and are
   excluded via the group_var filter below). The previous label
   "MOUD_UNKNOWN excluded" overstated this as a full complete-case
   exclusion, which it is not. */
%sens_contrast(filter_where=1=1,
               scenario=Psych+MOUD grouping - MOUD-unknown retained when psych alone determines candidacy,
               exp_var=active_primary, group_var=primary_group_psych_moud, outds=s6);
/* MOUD-present sensitivity: genuine within-MOUD-present comparison now --
   both candidate and comparator rows are restricted to moud_status=
   MOUD_PRESENT. A psych-only comparator (zero psychiatric qualifiers) can
   still have an observed MOUD fill, so this comparison is meaningful. */
%sens_contrast(filter_where=moud_status = 'MOUD_PRESENT',
               scenario=Within MOUD-present only,
               exp_var=active_primary, outds=s7);
/* Item 9 carry-through: all-strong-tier sensitivity vs. target-drug primary */
%sens_contrast(filter_where=1=1,
               scenario=All-strong-tier exposure (vs target-drug primary),
               exp_var=active_allstrong_primary, outds=s8);

data &t_sensitivity.;
   set _s_s1 _s_s2 _s_s3 _s_s4 _s_s5 _s_s6 _s_s7 _s_s8;
run;

/* PTSD/depression/anxiety/MOUD presence-absence: NOT forced into the
   candidate-vs-comparator framework, since a psych-only comparator has
   zero psychiatric qualifiers by definition and can never have PTSD --
   a "PTSD present vs comparator" contrast isn't a within-PTSD comparison.
   This is a simple presence/absence table per individual qualifier instead. */
%macro qualifier_presence(flag_var=, qual_label=, outds=);
   proc sql;
      create table _q_&outds. as
      select "&qual_label." as qualifier length=20,
             case when &flag_var. = 1 then 'PRESENT' else 'ABSENT' end as status length=12,
             count(*) as n_total,
             sum(active_primary = 1) as n_active,
             count(active_primary) as n_classifiable,
             mean(active_primary) as pct_active format=percent8.1
      from _analysis
      group by calculated status;
   quit;
%mend;

%qualifier_presence(flag_var=flag_ptsd_w, qual_label=PTSD, outds=ptsd);
%qualifier_presence(flag_var=flag_depression_w, qual_label=Depression, outds=dep);
%qualifier_presence(flag_var=flag_anxiety_w, qual_label=Anxiety, outds=anx);

proc sql;
   create table _q_moud as
   select "MOUD" as qualifier length=20,
          moud_status as status length=24,
          count(*) as n_total,
          sum(active_primary = 1) as n_active,
          count(active_primary) as n_classifiable,
          mean(active_primary) as pct_active format=percent8.1
   from _analysis
   group by moud_status;
quit;

data &t_qualpres.;
   length qualifier $20 status $24;
   set _q_ptsd _q_dep _q_anx _q_moud;
run;
proc print data=&t_qualpres. noobs;
   title "Active exposure by individual qualifier presence/absence (all eligible benes, not restricted to candidate/comparator)";
run;

proc print data=&t_sensitivity. noobs;
   title "FIRST-PASS RESULT: Sensitivity analyses";
run;

/* Drug-specific prevalence -- now saved permanently, with classifiable
   denominators shown explicitly (mean() already excludes the missing
   values set in 03_exposure item 8, but the denominator should be visible) */
proc sql;
   create table &t_drugspec. as
   select primary_group_psych as group,
          case when primary_group_psych = 'CANDIDATE' then '2+ psychiatric qualifiers'
               when primary_group_psych = 'COMPARATOR' then '0 psychiatric qualifiers'
          end as group_label length=28,
          count(active_bupropion) as n_classifiable_bupropion,
          sum(active_bupropion) as n_bupropion,
          mean(active_bupropion) as pct_bupropion format=percent8.1,
          count(active_paroxetine) as n_classifiable_paroxetine,
          sum(active_paroxetine) as n_paroxetine,
          mean(active_paroxetine) as pct_paroxetine format=percent8.1,
          count(active_fluoxetine) as n_classifiable_fluoxetine,
          sum(active_fluoxetine) as n_fluoxetine,
          mean(active_fluoxetine) as pct_fluoxetine format=percent8.1
   from _analysis
   where primary_group_psych in ('CANDIDATE','COMPARATOR')
   group by primary_group_psych;
quit;
proc print data=&t_drugspec. noobs;
   title "Drug-specific active prevalence (classifiable denominators shown)";
run;

/* Summary -- now explicitly states test_mode and run_id so a test-sample
   result can never be mistaken for a full-cohort result */
%local n_total n_cand n_comp p_act_cand p_act_comp p_unk;
proc sql noprint;
   select count(*) into :n_total trimmed from _analysis;
   select count(*) into :n_cand trimmed from _analysis where primary_group_psych='CANDIDATE';
   select count(*) into :n_comp trimmed from _analysis where primary_group_psych='COMPARATOR';
   select put(mean(active_primary), percent8.1) into :p_act_cand trimmed
      from _analysis where primary_group_psych='CANDIDATE';
   select put(mean(active_primary), percent8.1) into :p_act_comp trimmed
      from _analysis where primary_group_psych='COMPARATOR';
   select put(mean(any_unknown), percent8.1) into :p_unk trimmed from _analysis;
quit;

data &t_summary.;
   length finding $200;
   finding = "RUN ID: &run_id.  |  TEST_MODE: &test_mode."; output;
   finding = "Landmark-eligible beneficiaries: &n_total."; output;
   finding = "2+ Psychiatric Qualifiers: &n_cand."; output;
   finding = "0 Psychiatric Qualifiers: &n_comp."; output;
   finding = "Active CYP2D6 inhibitor, target drugs (among classifiable): 2+ qualifiers &p_act_cand., 0 qualifiers &p_act_comp."; output;
   finding = "Unclassifiable exposure status on at least one measure: &p_unk."; output;
   finding = "Note: prevalences above are among classifiable benes only (not all eligible)"; output;
   finding = "Note: primary exposure = target drugs (bupropion/paroxetine/fluoxetine); all-strong-tier is a sensitivity"; output;
   finding = "Note: cardiac outcomes not assessed in first pass"; output;
   %if %upcase(&test_mode.) = Y %then %do;
   finding = "*** THIS IS A TEST-MODE RESULT ON A STRATIFIED SAMPLE, NOT THE FULL COHORT ***"; output;
   %end;
run;
proc print data=&t_summary. noobs; title "FIRST-PASS RESULTS SUMMARY"; run;

/* Mark the run manifest ANALYSIS_DONE (not COMPLETED -- that status is
   reserved for 99c, after branch coverage and full validation both pass).
   If the script errors out before this point, run_status stays STARTED,
   which flags an incomplete/failed run for anyone checking
   res.ibog_run_manifest&version_tag. later. */
%assert_clean_run(stage=first-pass analysis)
proc sql;
   update res.ibog_run_manifest&version_tag.
   set run_status = "ANALYSIS_DONE";
quit;

%put NOTE: 04_first_pass_results.sas complete. run_status=ANALYSIS_DONE.;
%put NOTE: Review gradient before candidate/comparator contrast.;
%put NOTE: If unknown Part D is large, classifiable-only estimates are;
%put NOTE: more reliable than total-eligible estimates.;

%mend run_04_results;
%run_04_results;

/* end 04_first_pass_results.sas */
