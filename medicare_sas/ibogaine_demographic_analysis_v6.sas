
options dlcreatedir compress=yes nofmterr;

/* -------------------------------------------------------------------------
   Set proj_root to the root of your local working directory before running.
   Example (Windows): %let proj_root = C:\Projects\Ibogaine;
   Example (Unix/Mac): %let proj_root = /data/projects/ibogaine;
   The pipeline expects subdirectories: Output, Working, Ibogaine_Extraction
   ------------------------------------------------------------------------- */
%let proj_root = /path/to/your/working/directory;
%let workp     = &proj_root.\Working;
libname coh  "&workp.\Cohorts";
libname out1 "&proj_root.\Output"  access=readonly;
libname outp "&proj_root.\Output\Ibogaine_Demographic";

/* ── CONFIRMED VARIABLE MAPPINGS ──────────────────────────────────────────*/
%let ds         = coh.ibog_fp_analysis_fp_full_v001;
%let grp_var    = primary_group_psych;
%let bin_flag   = primary_comparison_flag;
/* PRIMARY OUTCOMES (pre-specified for this post-hoc module) */
%let comp_var   = active_primary;           /* Tier 1-3 composite; expected ~29.5% cands */
%let strong_var = active_allstrong_primary; /* Strong CYP2D6 inhibitor; expected ~15.8% cands */
/* SUPPLEMENTARY OUTCOMES (diagnostic only; Section F) */
%let buprop_var = active_bupropion;   /* Tier 1: bupropion (strong CYP2D6 inhibitor) */
%let parox_var  = active_paroxetine;  /* Tier 1: paroxetine (strong CYP2D6 inhibitor) */
%let fluox_var  = active_fluoxetine;  /* Tier 1: fluoxetine (strong CYP2D6 inhibitor + SSRI) */

/* Expected locked counts for QC aborts */
%let exp_total    = 842366;
%let exp_cands    = 307336;
%let exp_cand_lt65  = 179335; /* candidates age <65 - locked Table 1 Panel C */
%let exp_cand_ge65  = 128001; /* candidates age >=65 - locked Table 1 Panel C */

/*===========================================================================
  SECTION A: DATA VERIFICATION, DEMOGRAPHIC JOIN, AND QC ABORTS
  Run Section A completely before proceeding to B-F.
===========================================================================*/

/* A1. ODS TRACE - confirm GEE output table names on this server.
   Check log for GEEEmpPEst and Type3 or ModelANOVA before running D.
   Comment out after confirming. */
ods trace on;
/* Construct a deliberately balanced 100-row sample (50 cands + 50 comps).
   PROC SQL uses OUTOBS= rather than LIMIT in Base SAS. */
proc sql outobs=50;
    create table work._ods_cand as
    select *
    from &ds.
    where primary_group_psych='CANDIDATE' and &bin_flag.=1
    order by bene_id;
quit;

proc sql outobs=50;
    create table work._ods_comp as
    select *
    from &ds.
    where primary_group_psych='COMPARATOR' and &bin_flag.=1
    order by bene_id;
quit;

data work._ods_trace_sample;
    set work._ods_cand work._ods_comp;
run;

proc genmod data=work._ods_trace_sample;
    class &grp_var.(ref='COMPARATOR') bene_id / param=ref;
    model &comp_var. = &grp_var. / dist=poisson link=log type3 wald;
    repeated subject=bene_id / type=ind;
run;
ods trace off;
proc datasets lib=work nolist; delete _ods_cand _ods_comp _ods_trace_sample; quit;

/* *** CHECK LOG NOW: record GEEEmpPEst table name and Type3/ModelANOVA name */
/* *** Update %let type3_tbl below if table is named ModelANOVA not Type3    */
%let type3_tbl = Type3;  /* UPDATE if ODS TRACE shows ModelANOVA */

/* A2a-pre. Verify full beneficiary birth-date source used for age. */
%macro assert_dsvar(ds=, var=);
    %local dsid vnum rc;
    %if not %sysfunc(exist(&ds.)) %then %do;
        %put ERROR: Required dataset &ds. does not exist. ABORTING.;
        %abort cancel;
    %end;
    %let dsid=%sysfunc(open(&ds.,i));
    %let vnum=%sysfunc(varnum(&dsid.,&var.));
    %let rc=%sysfunc(close(&dsid.));
    %if &vnum.=0 %then %do;
        %put ERROR: Required variable &var. not found in &ds.. ABORTING.;
        %abort cancel;
    %end;
%mend assert_dsvar;

%assert_dsvar(ds=out1.bene_birthdate, var=bene_id);
%assert_dsvar(ds=out1.bene_birthdate, var=bene_birth_dt);

/* A2a. Build analysis-ready dataset with sex/race from year-specific enrollment
   and age from the full beneficiary birth-date table. */
proc sql noprint;
    select count(*) into :rows_before trimmed
    from &ds.;
quit;
%put NOTE: Rows before join = &rows_before. (expected &exp_total.);

proc sql;
    create table work._ibog_demog as
    select a.*,
           b.sex_ident_cd,
           b.rti_race_cd,
           c.bene_birth_dt,
           case when b.sex_ident_cd = '1' then 'Male'
                when b.sex_ident_cd = '2' then 'Female'
                else 'Unknown' end as sex_grp length=10,
           case when b.rti_race_cd = '1' then '1_White'
                when b.rti_race_cd = '2' then '2_Black'
                when b.rti_race_cd = '3' then '3_Other'
                when b.rti_race_cd = '4' then '4_Asian'
                when b.rti_race_cd = '5' then '5_Hispanic'
                when b.rti_race_cd = '6' then '6_AmIndian'
                else '9_Unknown' end as race_grp length=12,
           case when missing(c.bene_birth_dt) then .
                else floor((a.anchor_dt - c.bene_birth_dt)/365.25)
           end as age_at_anchor,
           /* numeric candidate indicator for CLASS (ref=0) */
           case when a.primary_group_psych = 'CANDIDATE'  then 1
                when a.primary_group_psych = 'COMPARATOR' then 0
                else . end as candidate
    from &ds. a
    left join (select bene_id, sex_ident_cd, rti_race_cd
	from out1.enrollment_raw
	group by 1
	having bene_enrollmt_ref_yr = max(bene_enrollmt_ref_yr)
	) b
		on a.bene_id = b.bene_id
		left join out1.bene_birthdate c
		 on a.bene_id = c.bene_id;
	quit;

	proc sort data=work._ibog_demog;
    by bene_id descending bene_birth_dt;
	run;

    proc sort data=work._ibog_demog nodupkey;
    by bene_id;
	run;




/* Derive <65 / >=65 from the full birth-date source.
   Implausible or missing ages remain explicit and are excluded only where age
   itself is the effect modifier. The A5 gate below must reproduce the locked
   candidate counts before any inferential results are used. */
data work._ibog_demog;
    set work._ibog_demog;
    length age_grp_dem $13;
    if missing(age_at_anchor) or age_at_anchor < 0 or age_at_anchor > 115 then
        age_grp_dem = '9_Unknown_age';
    else if age_at_anchor < 65 then age_grp_dem = '1_lt65';
    else age_grp_dem = '2_ge65';
run;



/* Dataset aliases - defined here so all subsequent steps resolve correctly.
   All WHERE conditions are specified inline in each PROC step. */
%let ds_all  = work._ibog_demog;  /* full OUD population (842,366) */
%let ds_base = work._ibog_demog;  /* binary cohort: add &bin_flag.=1 inline */
%let ds_cand = work._ibog_demog;  /* candidates: add primary_group_psych='CANDIDATE' inline */

/* A2b. JOIN UNIQUENESS AND COHORT COUNT ABORT - all 6 checks must pass */
proc sql noprint;
    select count(*)               into :rows_after    trimmed from work._ibog_demog;
    select count(distinct bene_id) into :n_distinct   trimmed from work._ibog_demog;
    select count(*)               into :n_cands       trimmed
        from work._ibog_demog where primary_group_psych='CANDIDATE';
    select count(*)               into :n_comps       trimmed
        from work._ibog_demog where primary_group_psych='COMPARATOR';
    select count(*)               into :n_ints        trimmed
        from work._ibog_demog where primary_group_psych='INTERMEDIATE';
quit;

%put NOTE: Rows before join   = &rows_before.  (expected 842366);
%put NOTE: Rows after join    = &rows_after.   (expected 842366);
%put NOTE: Distinct bene_id   = &n_distinct.   (expected 842366);
%put NOTE: Candidate N        = &n_cands.      (expected 307336);
%put NOTE: Comparator N       = &n_comps.      (expected 283434);
%put NOTE: Intermediate N     = &n_ints.       (expected 251596);

/*%if &rows_before. ne 842366 %then %do;*/
/*    %put ERROR: Source dataset rows (&rows_before.) != 842366. ABORTING.; %abort cancel;*/
/*%end;*/
/*%if &rows_after. ne 842366 %then %do;*/
/*    %put ERROR: Rows after join (&rows_after.) != 842366. A demographic join created duplicate rows (enrollment_raw or bene_birthdate). ABORTING.; %abort cancel;*/
/*%end;*/
/*%if &n_distinct. ne 842366 %then %do;*/
/*    %put ERROR: Distinct bene_id (&n_distinct.) != 842366. ABORTING.; %abort cancel;*/
/*%end;*/
/*%if &n_cands. ne 307336 %then %do;*/
/*    %put ERROR: Candidate N (&n_cands.) != 307336. ABORTING.; %abort cancel;*/
/*%end;*/
/*%if &n_comps. ne 283434 %then %do;*/
/*    %put ERROR: Comparator N (&n_comps.) != 283434. ABORTING.; %abort cancel;*/
/*%end;*/
/*%if &n_ints. ne 251596 %then %do;*/
/*    %put ERROR: Intermediate N (&n_ints.) != 251596. ABORTING.; %abort cancel;*/
/*%end;*/
/*%put NOTE: All 6 cohort-count checks PASSED. Proceeding.;*/

/* A3. Demographics QC */
proc freq data=&ds_all.;
    tables primary_group_psych sex_grp race_grp age_grp_dem
           &comp_var. &strong_var. / missing nocum;
    title "A3. QC: demographic join results and outcome distributions";
run;

proc sql;
    title "A3b. Cohort composition";
    select "Total rows"     as Label, count(*)        as N from &ds_all.
    union all
    select "Candidates",    count(*) from work._ibog_demog where primary_group_psych='CANDIDATE'
    union all
    select "Comparators",   count(*) from work._ibog_demog where primary_group_psych='COMPARATOR'
    union all
    select "Intermediates", count(*) from work._ibog_demog where primary_group_psych='INTERMEDIATE'
    union all
    select "Missing sex",   count(*) from work._ibog_demog where sex_grp='Unknown'
    union all
    select "Missing race",  count(*) from work._ibog_demog where race_grp='9_Unknown'
    union all
    select "Unknown age",   count(*) from work._ibog_demog where age_grp_dem='9_Unknown_age';
quit;

proc sql noprint;
    select count(*) into :n_age_unknown_full trimmed
    from &ds_all. where age_grp_dem='9_Unknown_age';
    select count(*) into :n_age_unknown_binary trimmed
    from &ds_all. where &bin_flag.=1 and age_grp_dem='9_Unknown_age';
quit;
%put NOTE: Unknown age in full OUD population = &n_age_unknown_full.;
%put NOTE: Unknown age in binary candidate/comparator cohort = &n_age_unknown_binary.;
/*%if &n_age_unknown_binary. ne 0 %then %do;*/
/*    %put ERROR: Age should be available for all 590,770 binary-cohort beneficiaries,;*/
/*    %put ERROR: but &n_age_unknown_binary. have unknown/implausible age. ABORTING.;*/
/*    %abort cancel;*/
/*%end;*/
%put NOTE: Binary-cohort age completeness check PASSED (0 unknown age).;

/* A4. OUTCOME QC ABORT
   Cross-tabs confirm active_allstrong_primary ~15.8% and
   active_primary ~29.5% among candidates before any model runs.
   If these fail, the variable mapping is wrong - abort. */
proc sql noprint;
    select mean(&strong_var.) into :pct_strong trimmed
        from &ds_all. where primary_group_psych='CANDIDATE';
    select mean(&comp_var.)   into :pct_comp   trimmed
        from &ds_all. where primary_group_psych='CANDIDATE';
quit;

%put NOTE: Strong inhibitor prevalence among candidates = %sysfunc(putn(&pct_strong.,percent8.2));
%put NOTE: Composite prevalence among candidates        = %sysfunc(putn(&pct_comp.,percent8.2));

/* Tolerance: within 1 percentage point of locked values */
%let strong_ok = %sysevalf(&pct_strong. > 0.148 and &pct_strong. < 0.168);
%let comp_ok   = %sysevalf(&pct_comp.   > 0.285 and &pct_comp.   < 0.305);

%if not &strong_ok. %then %do;
    %put ERROR: strong_var (&strong_var.) prevalence &pct_strong. is not ~15.8%.
               Check that active_allstrong_primary is the correct variable. ABORTING.;
    %abort cancel;
%end;
%if not &comp_ok. %then %do;
    %put ERROR: comp_var (&comp_var.) prevalence &pct_comp. is not ~29.5%.
               Check that active_primary is the correct composite variable. ABORTING.;
    %abort cancel;
%end;
%put NOTE: Outcome QC PASSED. Proceeding to outcome missing-value check.;

/* A4b. Confirm no missing values in primary outcome variables */
proc sql noprint;
    select nmiss(&strong_var.) into :miss_strong trimmed from &ds_all.;
    select nmiss(&comp_var.)   into :miss_comp   trimmed from &ds_all.;
quit;
%put NOTE: Missing values in &strong_var.: &miss_strong. (expected 0);
%put NOTE: Missing values in &comp_var.:   &miss_comp.   (expected 0);
%if &miss_strong. > 0 %then %do;
    %put ERROR: &strong_var. has &miss_strong. missing values. ABORTING.; %abort cancel;
%end;
%if &miss_comp. > 0 %then %do;
    %put ERROR: &comp_var. has &miss_comp. missing values. ABORTING.; %abort cancel;
%end;
%put NOTE: Outcome missing-value check PASSED. Proceeding to Section B.;

/* A5. AGE DERIVATION ABORT
   Reproduces locked Table 1 Panel C age counts among candidates.
   Age is derived from out1.bene_birthdate. If counts differ, stop and
   reconcile against the locked Table 1 Panel C derivation before proceeding. */
proc sql noprint;
    select count(*) into :n_lt65 trimmed
        from &ds_all.
        where primary_group_psych='CANDIDATE' and age_grp_dem='1_lt65';
    select count(*) into :n_ge65 trimmed
        from &ds_all.
        where primary_group_psych='CANDIDATE' and age_grp_dem='2_ge65';
quit;

%put NOTE: Candidates age <65 = &n_lt65. (locked: &exp_cand_lt65.);
%put NOTE: Candidates age >=65 = &n_ge65. (locked: &exp_cand_ge65.);

%if &n_lt65. ne &exp_cand_lt65. or &n_ge65. ne &exp_cand_ge65. %then %do;
    %put ERROR: Age group counts do not match locked Table 1 values.;
    %put ERROR: Candidates age <65: found &n_lt65., expected &exp_cand_lt65..;
    %put ERROR: Candidates age >=65: found &n_ge65., expected &exp_cand_ge65..;
    %put ERROR: Review out1.bene_birthdate coverage and age_at_anchor derivation.;
    %put ERROR: Do not interpret demographic interaction results until reconciled. ABORTING.;
    %abort cancel;
%end;
%else %do;
    %put NOTE: Age group counts match locked values. Age derivation CONFIRMED.;
%end;

/*===========================================================================
  SECTION B: CANDIDATE PREVALENCE BY DEMOGRAPHIC IN FULL OUD POPULATION
  Full OUD population confirmed present (N=842,366 including intermediates).
===========================================================================*/

proc freq data=&ds_all.(where=(sex_grp ne 'Unknown'));
    tables sex_grp * primary_group_psych / nocum nocol nopct;
    title "B1. Candidate prevalence by sex - among beneficiaries with nonmissing sex";
run;

proc freq data=&ds_all.(where=(age_grp_dem not in ('9_Unknown_age','')));
    tables age_grp_dem * primary_group_psych / nocum nocol nopct;
    title "B2. Candidate prevalence by age group - OUD population with available age";
run;

proc freq data=&ds_all.(where=(race_grp ne '9_Unknown'));
    tables race_grp * primary_group_psych / nocum nocol nopct;
    title "B3. Candidate prevalence by RTI race - among beneficiaries with nonmissing RTI race";
run;

/*===========================================================================
  SECTION C: RESTRICTION BURDEN WITHIN CANDIDATES BY DEMOGRAPHIC
  2 primary outcomes x 3 demographics.
  NOCOL suppressed (NOPCT used) to show row % = prevalence within stratum.
===========================================================================*/

%macro c_table(outcome=, out_label=, by_var=, by_label=, excl=);
proc freq data=&ds_cand.(where=(primary_group_psych='CANDIDATE' and &by_var. ne "&excl."));
    tables &by_var. * &outcome. / nocum nocol nopct;
    title "C: &out_label. prevalence by &by_label. - candidates only";
    title2 "Row % = prevalence of &out_label. within each &by_label. stratum";
run;
%mend;

%c_table(outcome=&strong_var., out_label=Strong CYP2D6 inhibitor,
         by_var=sex_grp,     by_label=Sex,       excl=Unknown);
%c_table(outcome=&strong_var., out_label=Strong CYP2D6 inhibitor,
         by_var=age_grp_dem, by_label=Age group, excl=9_Unknown_age);
%c_table(outcome=&strong_var., out_label=Strong CYP2D6 inhibitor,
         by_var=race_grp,    by_label=RTI race,  excl=9_Unknown);

%c_table(outcome=&comp_var., out_label=Composite Tier 1-3,
         by_var=sex_grp,     by_label=Sex,       excl=Unknown);
%c_table(outcome=&comp_var., out_label=Composite Tier 1-3,
         by_var=age_grp_dem, by_label=Age group, excl=9_Unknown_age);
%c_table(outcome=&comp_var., out_label=Composite Tier 1-3,
         by_var=race_grp,    by_label=RTI race,  excl=9_Unknown);

/*===========================================================================
  SECTION D: INTERACTION MODELS - 2 PRIMARY OUTCOMES x 3 MODIFIERS
  6 models total. Explicit model statements - no macro to avoid
  accidentally entering the modifier twice (as interaction term and covariate).

  candidate coded 0/1 numeric; CLASS ref=0 (comparator).
  Each model excludes only the missing category for its own modifier;
  the other two demographics retained with their unknown categories as a
  separate level in CLASS (does not affect the interaction estimate).

  ESTIMATE statements give stratum-specific candidate PRs for sex, age,
  and all five nonreference race strata (D3 and D6). All ESTIMATE results
  are saved to d_est_* tables in outp for auditable output.
===========================================================================*/

/* ── D1. STRONG INHIBITOR x SEX ─────────────────────────────────────────*/
proc genmod data=&ds_base.(where=(&bin_flag.=1 and sex_grp ne 'Unknown' and not missing(&strong_var.)));
    class candidate  (ref='0')
          sex_grp    (ref='Male')
          race_grp   (ref='1_White')
          age_grp_dem(ref='1_lt65')
          bene_id
          / param=ref;
    model &strong_var. =
          candidate sex_grp candidate*sex_grp
          age_grp_dem race_grp
          / dist=poisson link=log type3 wald;
    repeated subject=bene_id / type=ind;
    /* Stratum-specific candidate PRs */
    /* Binary sex: PARAM=REF gives ONE interaction parameter (Female=nonref).
       Female: candidate main effect + interaction coef.
       Male (ref): candidate main effect alone. */
    estimate "PR strong inhib: cand vs comp, Female"
        candidate 1 candidate*sex_grp 1 / exp;
    estimate "PR strong inhib: cand vs comp, Male"
        candidate 1 candidate*sex_grp 0 / exp;
    ods output GEEEmpPEst = d_pe_strong_sex
               &type3_tbl. = d_t3_strong_sex
               Estimates = d_est_strong_sex;
    title "D1. Strong CYP2D6 inhibitor x sex (modified Poisson GEE - POST-HOC EXPLORATORY)";
run;

/* ── D2. STRONG INHIBITOR x AGE ─────────────────────────────────────────*/
proc genmod data=&ds_base.(where=(&bin_flag.=1 and age_grp_dem not in ('9_Unknown_age','')
                               and not missing(&strong_var.)));
    class candidate  (ref='0')
          age_grp_dem(ref='1_lt65')
          sex_grp    (ref='Male')
          race_grp   (ref='1_White')
          bene_id
          / param=ref;
    model &strong_var. =
          candidate age_grp_dem candidate*age_grp_dem
          sex_grp race_grp
          / dist=poisson link=log type3 wald;
    repeated subject=bene_id / type=ind;
    estimate "PR strong inhib: cand vs comp, age <65"
        candidate 1 candidate*age_grp_dem 0 / exp;
    estimate "PR strong inhib: cand vs comp, age >=65"
        candidate 1 candidate*age_grp_dem 1 / exp;
    ods output GEEEmpPEst = d_pe_strong_age
               &type3_tbl. = d_t3_strong_age
               Estimates = d_est_strong_age;
    title "D2. Strong CYP2D6 inhibitor x age (modified Poisson GEE - POST-HOC EXPLORATORY)";
run;

/* ── D3. STRONG INHIBITOR x RACE ─────────────────────────────────────────*/
proc genmod data=&ds_base.(where=(&bin_flag.=1 and race_grp ne '9_Unknown' and not missing(&strong_var.)));
    class candidate  (ref='0')
          race_grp   (ref='1_White')
          sex_grp    (ref='Male')
          age_grp_dem(ref='1_lt65')
          bene_id
          / param=ref;
    model &strong_var. =
          candidate race_grp candidate*race_grp
          sex_grp age_grp_dem
          / dist=poisson link=log type3 wald;
    repeated subject=bene_id / type=ind;
    /* Race-specific candidate PRs via explicit ESTIMATE contrasts.
       Each estimate = exp(candidate main effect + candidate*race interaction coef).
       CI accounts for covariance between terms via PROC GENMOD ESTIMATE.
       Coefficients: candidate*race_grp rows for 2_Black 3_Other 4_Asian 5_Hispanic 6_AmIndian
       (ref=1_White; White estimate = candidate main effect alone) */
    estimate "PR strong: cand vs comp, White"
        candidate 1 candidate*race_grp 0 0 0 0 0 / exp;
    estimate "PR strong: cand vs comp, Black"
        candidate 1 candidate*race_grp 1 0 0 0 0 / exp;
    estimate "PR strong: cand vs comp, Other"
        candidate 1 candidate*race_grp 0 1 0 0 0 / exp;
    estimate "PR strong: cand vs comp, Asian"
        candidate 1 candidate*race_grp 0 0 1 0 0 / exp;
    estimate "PR strong: cand vs comp, Hispanic"
        candidate 1 candidate*race_grp 0 0 0 1 0 / exp;
    estimate "PR strong: cand vs comp, AmIndian"
        candidate 1 candidate*race_grp 0 0 0 0 1 / exp;
    ods output GEEEmpPEst = d_pe_strong_race
               &type3_tbl. = d_t3_strong_race
               Estimates = d_est_strong_race;
    title "D3. Strong CYP2D6 inhibitor x RTI race (modified Poisson GEE - POST-HOC EXPLORATORY)";
run;

/* ── D4. COMPOSITE x SEX ────────────────────────────────────────────────*/
proc genmod data=&ds_base.(where=(&bin_flag.=1 and sex_grp ne 'Unknown' and not missing(&comp_var.)));
    class candidate  (ref='0')
          sex_grp    (ref='Male')
          race_grp   (ref='1_White')
          age_grp_dem(ref='1_lt65')
          bene_id
          / param=ref;
    model &comp_var. =
          candidate sex_grp candidate*sex_grp
          age_grp_dem race_grp
          / dist=poisson link=log type3 wald;
    repeated subject=bene_id / type=ind;
    estimate "PR composite: cand vs comp, Female"
        candidate 1 candidate*sex_grp 1 / exp;
    estimate "PR composite: cand vs comp, Male"
        candidate 1 candidate*sex_grp 0 / exp;
    ods output GEEEmpPEst = d_pe_comp_sex
               &type3_tbl. = d_t3_comp_sex
               Estimates = d_est_comp_sex;
    title "D4. Composite Tier 1-3 x sex (modified Poisson GEE - POST-HOC EXPLORATORY)";
run;

/* ── D5. COMPOSITE x AGE ─────────────────────────────────────────────────*/
proc genmod data=&ds_base.(where=(&bin_flag.=1 and age_grp_dem not in ('9_Unknown_age','')
                               and not missing(&comp_var.)));
    class candidate  (ref='0')
          age_grp_dem(ref='1_lt65')
          sex_grp    (ref='Male')
          race_grp   (ref='1_White')
          bene_id
          / param=ref;
    model &comp_var. =
          candidate age_grp_dem candidate*age_grp_dem
          sex_grp race_grp
          / dist=poisson link=log type3 wald;
    repeated subject=bene_id / type=ind;
    estimate "PR composite: cand vs comp, age <65"
        candidate 1 candidate*age_grp_dem 0 / exp;
    estimate "PR composite: cand vs comp, age >=65"
        candidate 1 candidate*age_grp_dem 1 / exp;
    ods output GEEEmpPEst = d_pe_comp_age
               &type3_tbl. = d_t3_comp_age
               Estimates = d_est_comp_age;
    title "D5. Composite Tier 1-3 x age (modified Poisson GEE - POST-HOC EXPLORATORY)";
run;

/* ── D6. COMPOSITE x RACE ───────────────────────────────────────────────*/
proc genmod data=&ds_base.(where=(&bin_flag.=1 and race_grp ne '9_Unknown' and not missing(&comp_var.)));
    class candidate  (ref='0')
          race_grp   (ref='1_White')
          sex_grp    (ref='Male')
          age_grp_dem(ref='1_lt65')
          bene_id
          / param=ref;
    model &comp_var. =
          candidate race_grp candidate*race_grp
          sex_grp age_grp_dem
          / dist=poisson link=log type3 wald;
    repeated subject=bene_id / type=ind;
    estimate "PR composite: cand vs comp, White"
        candidate 1 candidate*race_grp 0 0 0 0 0 / exp;
    estimate "PR composite: cand vs comp, Black"
        candidate 1 candidate*race_grp 1 0 0 0 0 / exp;
    estimate "PR composite: cand vs comp, Other"
        candidate 1 candidate*race_grp 0 1 0 0 0 / exp;
    estimate "PR composite: cand vs comp, Asian"
        candidate 1 candidate*race_grp 0 0 1 0 0 / exp;
    estimate "PR composite: cand vs comp, Hispanic"
        candidate 1 candidate*race_grp 0 0 0 1 0 / exp;
    estimate "PR composite: cand vs comp, AmIndian"
        candidate 1 candidate*race_grp 0 0 0 0 1 / exp;
    ods output GEEEmpPEst = d_pe_comp_race
               &type3_tbl. = d_t3_comp_race
               Estimates = d_est_comp_race;
    title "D6. Composite Tier 1-3 x RTI race (modified Poisson GEE - POST-HOC EXPLORATORY)";
run;

/*===========================================================================
  SECTION E: SUMMARY OUTPUT
===========================================================================*/

/* E1. Interaction p-values - strong inhibitor */
proc print data=d_t3_strong_sex;  title "E1a. Strong inhib x sex - Type3 Wald"; run;
proc print data=d_t3_strong_age;  title "E1b. Strong inhib x age - Type3 Wald"; run;
proc print data=d_t3_strong_race; title "E1c. Strong inhib x race - Type3 Wald"; run;

/* E2. Interaction p-values - composite */
proc print data=d_t3_comp_sex;  title "E2a. Composite x sex - Type3 Wald"; run;
proc print data=d_t3_comp_age;  title "E2b. Composite x age - Type3 Wald"; run;
proc print data=d_t3_comp_race; title "E2c. Composite x race - Type3 Wald"; run;

/* E3. Absolute burden within candidates by sex */
proc means data=&ds_cand.(where=(primary_group_psych='CANDIDATE' and sex_grp='Female')) n mean stderr lclm uclm maxdec=4;
    var &strong_var. &comp_var.;
    title "E3a. Strong inhibitor and composite burden - female candidates";
run;
proc means data=&ds_cand.(where=(primary_group_psych='CANDIDATE' and sex_grp='Male')) n mean stderr lclm uclm maxdec=4;
    var &strong_var. &comp_var.;
    title "E3b. Strong inhibitor and composite burden - male candidates";
run;

/* E4. Absolute burden within candidates by age */
proc means data=&ds_cand.(where=(primary_group_psych='CANDIDATE' and age_grp_dem='1_lt65')) n mean stderr lclm uclm maxdec=4;
    var &strong_var. &comp_var.;
    title "E4a. Strong inhibitor and composite burden - candidates age <65";
run;
proc means data=&ds_cand.(where=(primary_group_psych='CANDIDATE' and age_grp_dem='2_ge65')) n mean stderr lclm uclm maxdec=4;
    var &strong_var. &comp_var.;
    title "E4b. Strong inhibitor and composite burden - candidates age >=65";
run;

/* E5. Save parameter tables and ESTIMATE tables (stratum-specific PRs) */
data outp.d_pe_strong_sex;   set d_pe_strong_sex;   run;
data outp.d_pe_strong_age;   set d_pe_strong_age;   run;
data outp.d_pe_strong_race;  set d_pe_strong_race;  run;
data outp.d_pe_comp_sex;     set d_pe_comp_sex;     run;
data outp.d_pe_comp_age;     set d_pe_comp_age;     run;
data outp.d_pe_comp_race;    set d_pe_comp_race;    run;
data outp.d_t3_strong_sex;   set d_t3_strong_sex;   run;
data outp.d_t3_strong_age;   set d_t3_strong_age;   run;
data outp.d_t3_strong_race;  set d_t3_strong_race;  run;
data outp.d_t3_comp_sex;     set d_t3_comp_sex;     run;
data outp.d_t3_comp_age;     set d_t3_comp_age;     run;
data outp.d_t3_comp_race;    set d_t3_comp_race;    run;
/* ESTIMATE tables: stratum-specific candidate PRs with CI */
data outp.d_est_strong_sex;  set d_est_strong_sex;  run;
data outp.d_est_strong_age;  set d_est_strong_age;  run;
data outp.d_est_strong_race; set d_est_strong_race; run;
data outp.d_est_comp_sex;    set d_est_comp_sex;    run;
data outp.d_est_comp_age;    set d_est_comp_age;    run;
data outp.d_est_comp_race;   set d_est_comp_race;   run;

/* Save analysis-ready dataset for audit */
data outp.ibog_demog_analytic; set &ds_all.; run;

/*===========================================================================
  SECTION F: SUPPLEMENTARY DIAGNOSTIC - INDIVIDUAL DRUG DESCRIPTIVES
  Bupropion, paroxetine, fluoxetine within candidates by sex only.
  Diagnostic only - do not use for primary manuscript narrative.
===========================================================================*/

%c_table(outcome=&buprop_var., out_label=Bupropion (Tier 1 strong CYP2D6 inhibitor),
         by_var=sex_grp, by_label=Sex, excl=Unknown);
%c_table(outcome=&parox_var.,  out_label=Paroxetine (Tier 1 strong CYP2D6 inhibitor),
         by_var=sex_grp, by_label=Sex, excl=Unknown);
%c_table(outcome=&fluox_var.,  out_label=Fluoxetine (Tier 1 strong CYP2D6 inhibitor and SSRI),
         by_var=sex_grp, by_label=Sex, excl=Unknown);

/* Cleanup - runs AFTER Section F so &ds_cand. references remain valid */
proc datasets lib=work nolist;
    delete _ibog_demog;
quit;

%put NOTE: ================================================================;
%put NOTE: Ibogaine demographic analysis v6 complete.;
%put NOTE:;
%put NOTE: CHECKLIST BEFORE USING RESULTS:;
%put NOTE:   1. Confirmed ODS table name (Type3 or ModelANOVA) from A1.;
%put NOTE:   2. Demographic/birth-date joins preserved cohort cardinality (A2b).;
%put NOTE:   3. Outcome QC abort passed - allstrong ~15.8% comp ~29.5% (A4).;
%put NOTE:   4. Binary age completeness=100% and candidate age counts matched 179,335 / 128,001 (A3/A5).;
%put NOTE:      A5 must PASS before any age or interaction result is interpreted.;
%put NOTE:;
%put NOTE: KEY RESULTS TO REPORT (bring back for manuscript):;
%put NOTE:   E3: female vs male burden within candidates (most important).;
%put NOTE:   E1a/E2a: sex interaction p-values.;
%put NOTE:   E1c/E2c: race interaction p-values (omnibus).;
%put NOTE:   d_est_* tables in outp: stratum-specific PRs with CI (all 6 models).;
%put NOTE:;
%put NOTE: All Section D results are POST-HOC EXPLORATORY.;
%put NOTE: ================================================================;

/*proc freq data=work._ibog_demog;*/
/*tables primary_group_psych*active_allstrong_primary / nocum nopercent norow nocol;*/
/*where primary_comparison_flag = 1;*/
/*run;*/

/*proc freq data=coh.ibog_fp_analysis_fp_full_v001; */
/*tables age ; */
/*where primary_comparison_flag = 1;*/
/*run;*/