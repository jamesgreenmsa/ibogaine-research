/* ============================================================
   ibog_demog_stratified_pr_v1.sas
   Ibogaine Paper 2 - Medicare FFS demographic subgroup PRs
   Stratified modified Poisson (GEE) - one model per stratum

   REQUIRES: work._ibog_demog already built by v6.sas section A.
   Run immediately after v6.sas in the same EG session.

   APPROACH:
     Each stratum (Female, Male, <65, >=65, White, Black, ...)
     gets its own PROC GENMOD on that stratum's subset.
     Adjustment variables = the other two demographic domains.
     PR and 95% CI come from the 'candidate' row of GEEEmpPEst,
     which does NOT rely on ESTIMATE statements or the Estimates
     ODS table - those are bypassed entirely.

   OUTPUT:
     work._all_strat_results  (stacked summary, all 20 models)
     outp.ibog_strat_pr_v1    (permanent save)
     PROC PRINT in Results window for quick review

   Author:  James Green, MS - Rutgers SHP
   Version: v1
   Date:    September 2026
   ============================================================ */

options dlcreatedir compress=yes nofmterr;
/* -------------------------------------------------------------------------
   Set proj_root to the root of your local working directory before running.
   Example (Windows): %let proj_root = C:\Projects\Ibogaine;
   Example (Unix/Mac): %let proj_root = /data/projects/ibogaine;
   The pipeline expects subdirectories: Output, Working, Ibogaine_Extraction
   ------------------------------------------------------------------------- */
%let proj_root = /path/to/your/working/directory;
libname outp "&proj_root.\Output\Ibogaine_Demographic";
%let workp     = &proj_root.\Working;
libname coh  "&workp.\Cohorts";
libname out1 "&proj_root.\Output"  access=readonly;

/* ── CONFIRMED VARIABLE MAPPINGS ──────────────────────────────────────────*/
%let ds         = coh.ibog_fp_analysis_fp_full_v001;


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
    left join (select bene_id, bene_enrollmt_ref_yr, sex_ident_cd, rti_race_cd
	from out1.enrollment_raw
	group by 1,2
	having monotonic() = min(monotonic())
	) b
		on a.bene_id = b.bene_id
		and b.bene_enrollmt_ref_yr = year(a.anchor_dt)
		left join out1.bene_birthdate c
		 on a.bene_id = c.bene_id;
	quit;

	proc sort data=work._ibog_demog;
    by bene_id descending bene_birth_dt;
	run;

    proc sort data=work._ibog_demog nodupkey;
    by bene_id;
	run;

	data work._ibog_demog;
	set work._ibog_demog;
	length age_grp_dem  $10;
	if age_at_anchor < 65 then age_grp_dem = '1_lt65';
    if age_at_anchor >= 65 then age_grp_dem = '2_ge65';
	run;

/* ── Verify _ibog_demog is available ──────────────────────────── */
%if not %sysfunc(exist(work._ibog_demog)) %then %do;
    %put ERROR: work._ibog_demog does not exist.;
    %put ERROR: Run ibogaine_demographic_analysis_v6.sas (through section A) first.;
    %abort cancel;
%end;

/* Quick count check */
proc sql noprint;
    select count(*) into :n_total trimmed from work._ibog_demog
    where primary_comparison_flag = 1;
quit;
%put NOTE: Binary cohort (primary_comparison_flag=1) N = &n_total. (expected 590770);


/* ──────────────────────────────────────────────────────────────
   MACRO: run_strat
   Runs one stratified GEE model and appends the candidate row
   to the running results dataset work._all_strat_results.
   ────────────────────────────────────────────────────────────── */
%macro run_strat(
    outcome  = ,    /* SAS variable name:  active_allstrong_primary | active_primary     */
    olabel   = ,    /* short label:        Strong_Inhibitor | Composite                  */
    svar     = ,    /* stratifying domain: Sex | Age | Race                              */
    slbl     = ,    /* stratum label:      Female | Male | lt65 | ge65 | White | ...     */
    wfilt    = ,    /* WHERE fragment (use %bquote to pass quoted strings):              */
                    /*   e.g., %bquote(sex_grp='Female')                                */
    modvars  =      /* space-separated adjustment vars for MODEL (not the stratum var):  */
                    /*   e.g., race_grp age_grp_dem                                     */
);

    %put ===== run_strat: &olabel. / &svar. = &slbl. =====;

    proc genmod data=work._ibog_demog(
        where=(primary_comparison_flag = 1
               and not missing(&outcome.)
               and %unquote(&wfilt.)));
        class candidate  (ref='0')
              sex_grp    (ref='Male')
              race_grp   (ref='1_White')
              age_grp_dem(ref='1_lt65')
              bene_id / param=ref;
        model &outcome. = candidate &modvars.
              / dist=poisson link=log wald;
        repeated subject=bene_id / type=ind;
        ods output GEEEmpPEst = work._tmp_pe;
        title "Modified Poisson GEE - &olabel., &svar. = &slbl. (exploratory)";
    run;

    /* Tag the candidate row with stratum metadata and exponentiate */
    data work._tmp_tagged;
        set work._tmp_pe(where=(upcase(strip(parm)) = 'CANDIDATE'));
        length outcome_lbl $40 strat_var $20 strat_lbl $30;
        outcome_lbl = "&olabel.";
        strat_var   = "&svar.";
        strat_lbl   = "&slbl.";
        PR          = exp(Estimate);
        PR_LCL      = exp(LowerCL);
        PR_UCL      = exp(UpperCL);
        label PR    = 'Prevalence Ratio'
              PR_LCL= 'Lower 95% CI'
              PR_UCL= 'Upper 95% CI';
    run;

    /* Append to running results */
    proc append base=work._all_strat_results
                data=work._tmp_tagged
                force;
    run;

    proc datasets lib=work nolist;
        delete _tmp_pe _tmp_tagged;
    quit;

%mend run_strat;


/* ── Initialize results dataset ──────────────────────────────── */
%if %sysfunc(exist(work._all_strat_results)) %then %do;
    proc datasets lib=work nolist; delete _all_strat_results; quit;
%end;


/*===========================================================================
  OUTCOME 1: STRONG CYP2D6 INHIBITOR (active_allstrong_primary)
  Tier 1 strong inhibitors: bupropion, paroxetine, fluoxetine
===========================================================================*/

/* -- Sex strata -- */
%run_strat(outcome=active_allstrong_primary, olabel=Strong_Inhibitor,
    svar=Sex, slbl=Female,
    wfilt=%bquote(sex_grp='Female'),
    modvars=race_grp age_grp_dem);

%run_strat(outcome=active_allstrong_primary, olabel=Strong_Inhibitor,
    svar=Sex, slbl=Male,
    wfilt=%bquote(sex_grp='Male'),
    modvars=race_grp age_grp_dem);

/* -- Age strata -- */
%run_strat(outcome=active_allstrong_primary, olabel=Strong_Inhibitor,
    svar=Age, slbl=lt65,
    wfilt=%bquote(age_grp_dem='1_lt65'),
    modvars=sex_grp race_grp);

%run_strat(outcome=active_allstrong_primary, olabel=Strong_Inhibitor,
    svar=Age, slbl=ge65,
    wfilt=%bquote(age_grp_dem='2_ge65'),
    modvars=sex_grp race_grp);

/* -- Race strata (adjust for sex + age within each race group) -- */
%run_strat(outcome=active_allstrong_primary, olabel=Strong_Inhibitor,
    svar=Race, slbl=White,
    wfilt=%bquote(race_grp='1_White'),
    modvars=sex_grp age_grp_dem);

%run_strat(outcome=active_allstrong_primary, olabel=Strong_Inhibitor,
    svar=Race, slbl=Black,
    wfilt=%bquote(race_grp='2_Black'),
    modvars=sex_grp age_grp_dem);

%run_strat(outcome=active_allstrong_primary, olabel=Strong_Inhibitor,
    svar=Race, slbl=Other,
    wfilt=%bquote(race_grp='3_Other'),
    modvars=sex_grp age_grp_dem);

%run_strat(outcome=active_allstrong_primary, olabel=Strong_Inhibitor,
    svar=Race, slbl=Asian,
    wfilt=%bquote(race_grp='4_Asian'),
    modvars=sex_grp age_grp_dem);

%run_strat(outcome=active_allstrong_primary, olabel=Strong_Inhibitor,
    svar=Race, slbl=Hispanic,
    wfilt=%bquote(race_grp='5_Hispanic'),
    modvars=sex_grp age_grp_dem);

%run_strat(outcome=active_allstrong_primary, olabel=Strong_Inhibitor,
    svar=Race, slbl=AmIndian,
    wfilt=%bquote(race_grp='6_AmIndian'),
    modvars=sex_grp age_grp_dem);


/*===========================================================================
  OUTCOME 2: COMPOSITE TIER 1-3 (active_primary)
===========================================================================*/

/* -- Sex strata -- */
%run_strat(outcome=active_primary, olabel=Composite,
    svar=Sex, slbl=Female,
    wfilt=%bquote(sex_grp='Female'),
    modvars=race_grp age_grp_dem);

%run_strat(outcome=active_primary, olabel=Composite,
    svar=Sex, slbl=Male,
    wfilt=%bquote(sex_grp='Male'),
    modvars=race_grp age_grp_dem);

/* -- Age strata -- */
%run_strat(outcome=active_primary, olabel=Composite,
    svar=Age, slbl=lt65,
    wfilt=%bquote(age_grp_dem='1_lt65'),
    modvars=sex_grp race_grp);

%run_strat(outcome=active_primary, olabel=Composite,
    svar=Age, slbl=ge65,
    wfilt=%bquote(age_grp_dem='2_ge65'),
    modvars=sex_grp race_grp);

/* -- Race strata -- */
%run_strat(outcome=active_primary, olabel=Composite,
    svar=Race, slbl=White,
    wfilt=%bquote(race_grp='1_White'),
    modvars=sex_grp age_grp_dem);

%run_strat(outcome=active_primary, olabel=Composite,
    svar=Race, slbl=Black,
    wfilt=%bquote(race_grp='2_Black'),
    modvars=sex_grp age_grp_dem);

%run_strat(outcome=active_primary, olabel=Composite,
    svar=Race, slbl=Other,
    wfilt=%bquote(race_grp='3_Other'),
    modvars=sex_grp age_grp_dem);

%run_strat(outcome=active_primary, olabel=Composite,
    svar=Race, slbl=Asian,
    wfilt=%bquote(race_grp='4_Asian'),
    modvars=sex_grp age_grp_dem);

%run_strat(outcome=active_primary, olabel=Composite,
    svar=Race, slbl=Hispanic,
    wfilt=%bquote(race_grp='5_Hispanic'),
    modvars=sex_grp age_grp_dem);

%run_strat(outcome=active_primary, olabel=Composite,
    svar=Race, slbl=AmIndian,
    wfilt=%bquote(race_grp='6_AmIndian'),
    modvars=sex_grp age_grp_dem);


/*===========================================================================
  SUMMARY AND SAVE
===========================================================================*/

/* Sort and print for quick review */
proc sort data=work._all_strat_results;
    by outcome_lbl strat_var strat_lbl;
run;

proc print data=work._all_strat_results noobs label;
    var outcome_lbl strat_var strat_lbl PR PR_LCL PR_UCL ProbChiSq;
    format PR PR_LCL PR_UCL 8.3 ProbChiSq 8.4;
    title "Ibogaine Paper 2 - Stratified Prevalence Ratios (Candidate vs Comparator)";
    title2 "All 20 models: Sex / Age / Race x Strong Inhibitor / Composite";
run;

/* Save wide-format results with raw log-scale columns too */
data outp.ibog_strat_pr_v1;
    set work._all_strat_results;
    label
        outcome_lbl = 'Outcome'
        strat_var   = 'Stratifying Variable'
        strat_lbl   = 'Stratum'
        Estimate    = 'Log-scale Estimate'
        StdErr      = 'Robust SE'
        LowerCL     = 'Log-scale LCL'
        UpperCL     = 'Log-scale UCL'
        ProbChiSq   = 'P-value (Wald)'
        PR          = 'Prevalence Ratio'
        PR_LCL      = 'PR Lower 95% CI'
        PR_UCL      = 'PR Upper 95% CI';
run;

%put ===== STRATIFIED PR ANALYSIS COMPLETE =====;
%put NOTE: 20 models run (10 strata x 2 outcomes).;
%put NOTE: Results in work._all_strat_results and outp.ibog_strat_pr_v1.;
%put NOTE: Check the PROC PRINT output for PR and 95 CI by stratum.;
%put NOTE: Check each PROC GENMOD log section for convergence warnings.;
%put NOTE: AmIndian stratum may have sparse data -- flag if model did not converge.;
