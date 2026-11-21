/* ============================================================
   ibog_demog_stratified_pr_v2.sas
   Ibogaine Paper 2 - Medicare FFS demographic subgroup PRs
   Stratified modified Poisson (GEE) - one model per stratum

   SELF-CONTAINED: builds work._ibog_demog from scratch.
   Requires: out1 libname and &ds. macro variable already set
   in your SAS session (same as ibogaine_demographic_analysis_v6.sas).

   CHANGES FROM v1:
     - work._ibog_demog creation block integrated at top
     - Macro now takes svarname= (SAS var) + sval= (value, no quotes)
       instead of wfilt= (%bquote), eliminating all WHERE quoting issues
     - CLASS statement is conditional: only lists a demographic var
       when it actually appears in modvars, so age-stratum models
       do not list age_grp_dem (which has 1 level in the subset
       and caused "Invalid reference value" / GEEEmpPEst not created)

   OUTPUT:
     work._all_strat_results  (stacked summary, all 20 models)
     outp.ibog_strat_pr_v1    (permanent save)
     PROC PRINT in Results window for quick review

   Author:  James Green, MS -- Rutgers SHP
   Version: v2
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

/* ── NOTE: out1 libname and &ds. macro variable must already be  ── */
/* ── defined in this SAS session before running (same as v6.sas) ── */


/* ============================================================
   SECTION A: Build work._ibog_demog (self-contained)
   ============================================================ */

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
            case when a.primary_group_psych = 'CANDIDATE' then 1
                 when a.primary_group_psych = 'COMPARATOR' then 0
                 else . end as candidate
    from &ds. a
    left join (select bene_id, sex_ident_cd, rti_race_cd
               from out1.enrollment_raw
               group by 1
               having bene_enrollmt_ref_yr = max(bene_enrollmt_ref_yr)
              ) b
        on  a.bene_id = b.bene_id
    left join out1.bene_birthdate c
        on a.bene_id = c.bene_id;
quit;

proc sort data=work._ibog_demog;
    by bene_id descending bene_birth_dt;
run;

proc sort data=work._ibog_demog nodupkey;
    by bene_id;
run;

/* Derive age_grp_dem from age_at_anchor */
data work._ibog_demog;
    set work._ibog_demog;
    length age_grp_dem $10;
    if age_at_anchor < 65 then age_grp_dem = '1_lt65';
    else if age_at_anchor >= 65 then age_grp_dem = '2_ge65';
    /* Rows with missing age_at_anchor get missing age_grp_dem */
run;


/* ── Quick validation before running 20 models ──────────────── */
proc sql;
    title "Validation: row counts by stratum (primary_comparison_flag=1)";
    select
        primary_comparison_flag,
        count(*)                                   as n_total,
        sum(not missing(active_allstrong_primary)) as n_strong_nonmiss,
        sum(not missing(active_primary))           as n_comp_nonmiss
    from work._ibog_demog
    group by primary_comparison_flag;

    title "Validation: age_grp_dem distribution";
    select age_grp_dem, count(*) as n
    from work._ibog_demog
    where primary_comparison_flag = 1
    group by age_grp_dem
    order by age_grp_dem;

    title "Validation: sex_grp distribution";
    select sex_grp, count(*) as n
    from work._ibog_demog
    where primary_comparison_flag = 1
    group by sex_grp;

    title "Validation: race_grp distribution";
    select race_grp, count(*) as n
    from work._ibog_demog
    where primary_comparison_flag = 1
    group by race_grp;
quit;
title;

%put NOTE: Review the four validation tables above before proceeding.;
%put NOTE: age_grp_dem should show 1_lt65 and 2_ge65 with non-zero counts.;
%put NOTE: If all age_grp_dem counts are 0 or missing, bene_birth_dt did not join.;


/* ============================================================
   MACRO: run_strat  (v2 -- no %bquote, conditional CLASS)

   Parameters:
     outcome  = SAS variable name (e.g. active_allstrong_primary)
     olabel   = short label for output (e.g. Strong_Inhibitor)
     svar     = display domain (Sex | Age | Race) -- label only
     slbl     = display stratum label (Female | lt65 | White ...) -- label only
     svarname = actual SAS variable to filter on (sex_grp | age_grp_dem | race_grp)
     sval     = value of svarname to keep (e.g. Female | 1_lt65 | 1_White)
                do NOT include quotes -- the macro adds them
     modvars  = adjustment vars in the MODEL statement (space-separated)
                must NOT include the stratifying variable
                CLASS is built dynamically -- only vars in modvars get a CLASS entry

   Example:
     %run_strat(outcome=active_allstrong_primary, olabel=Strong_Inhibitor,
         svar=Sex, slbl=Female, svarname=sex_grp, sval=Female,
         modvars=race_grp age_grp_dem);
   ============================================================ */

%macro run_strat(outcome=, olabel=, svar=, slbl=, svarname=, sval=, modvars=);

    %put ===== run_strat: &olabel. / &svar. = &slbl. =====;

    proc genmod data=work._ibog_demog(
        where=(primary_comparison_flag = 1
               and not missing(&outcome.)
               and &svarname. = "&sval." ));

        class
			bene_id
            candidate   (ref='0')
            %if %index(&modvars., sex_grp)     > 0 %then sex_grp    (ref='Male')    ;
            %if %index(&modvars., race_grp)    > 0 %then race_grp   (ref='1_White') ;
            %if %index(&modvars., age_grp_dem) > 0 %then age_grp_dem(ref='1_lt65')  ;
			;
        model &outcome. = candidate &modvars.
              / dist=poisson link=log wald;

        repeated subject=bene_id / type=ind;

        ods output GEEEmpPEst = work._tmp_pe;

        title "Modified Poisson GEE -- &olabel., &svar. = &slbl. (exploratory)";
    run;

	%if %sysfunc(exist(work._tmp_pe)) %then %do ;

    /* Tag the candidate row and exponentiate to PR scale */
    data work._tmp_tagged;
        set work._tmp_pe(where=(upcase(strip(parm)) = 'CANDIDATE'));
        length outcome_lbl $40 strat_var $20 strat_lbl $30;
        outcome_lbl = "&olabel.";
        strat_var   = "&svar.";
        strat_lbl   = "&slbl.";
        PR          = exp(Estimate);
        PR_LCL      = exp(LowerCL);
        PR_UCL      = exp(UpperCL);
        label
            PR     = 'Prevalence Ratio'
            PR_LCL = 'Lower 95% CI'
            PR_UCL = 'Upper 95% CI';
    run;

    /* Append to running results */
    proc append base=work._all_strat_results
                data=work._tmp_tagged
                force;
    run;

    proc datasets lib=work nolist;
        delete _tmp_pe _tmp_tagged;
    quit;

	%end ;
	%else %put WARNING, ISSUE FOUND, STRATUM SKIPPED;

%mend run_strat;


/* ── Initialize results dataset ─────────────────────────────── */
%if %sysfunc(exist(work._all_strat_results)) %then %do;
    proc datasets lib=work nolist; delete _all_strat_results; quit;
%end;


/*===========================================================================
  OUTCOME 1: STRONG CYP2D6 INHIBITOR (active_allstrong_primary)
  Tier 1 strong inhibitors: bupropion, paroxetine, fluoxetine
===========================================================================*/

/* -- Sex strata -- */
%run_strat(outcome=active_allstrong_primary, olabel=Strong_Inhibitor,
    svar=Sex, slbl=Female, svarname=sex_grp, sval=Female,
    modvars=race_grp age_grp_dem);

%run_strat(outcome=active_allstrong_primary, olabel=Strong_Inhibitor,
    svar=Sex, slbl=Male, svarname=sex_grp, sval=Male,
    modvars=race_grp age_grp_dem);

/* -- Age strata (modvars does NOT include age_grp_dem -- CLASS built accordingly) -- */
%run_strat(outcome=active_allstrong_primary, olabel=Strong_Inhibitor,
    svar=Age, slbl=lt65, svarname=age_grp_dem, sval=1_lt65,
    modvars=sex_grp race_grp);

%run_strat(outcome=active_allstrong_primary, olabel=Strong_Inhibitor,
    svar=Age, slbl=ge65, svarname=age_grp_dem, sval=2_ge65,
    modvars=sex_grp race_grp);

/* -- Race strata -- */
%run_strat(outcome=active_allstrong_primary, olabel=Strong_Inhibitor,
    svar=Race, slbl=White, svarname=race_grp, sval=1_White,
    modvars=sex_grp age_grp_dem);

%run_strat(outcome=active_allstrong_primary, olabel=Strong_Inhibitor,
    svar=Race, slbl=Black, svarname=race_grp, sval=2_Black,
    modvars=sex_grp age_grp_dem);

%run_strat(outcome=active_allstrong_primary, olabel=Strong_Inhibitor,
    svar=Race, slbl=Other, svarname=race_grp, sval=3_Other,
    modvars=sex_grp age_grp_dem);

%run_strat(outcome=active_allstrong_primary, olabel=Strong_Inhibitor,
    svar=Race, slbl=Asian, svarname=race_grp, sval=4_Asian,
    modvars=sex_grp age_grp_dem);

%run_strat(outcome=active_allstrong_primary, olabel=Strong_Inhibitor,
    svar=Race, slbl=Hispanic, svarname=race_grp, sval=5_Hispanic,
    modvars=sex_grp age_grp_dem);

%run_strat(outcome=active_allstrong_primary, olabel=Strong_Inhibitor,
    svar=Race, slbl=AmIndian, svarname=race_grp, sval=6_AmIndian,
    modvars=sex_grp age_grp_dem);


/*===========================================================================
  OUTCOME 2: COMPOSITE TIER 1-3 (active_primary)
===========================================================================*/

/* -- Sex strata -- */
%run_strat(outcome=active_primary, olabel=Composite,
    svar=Sex, slbl=Female, svarname=sex_grp, sval=Female,
    modvars=race_grp age_grp_dem);

%run_strat(outcome=active_primary, olabel=Composite,
    svar=Sex, slbl=Male, svarname=sex_grp, sval=Male,
    modvars=race_grp age_grp_dem);

/* -- Age strata -- */
%run_strat(outcome=active_primary, olabel=Composite,
    svar=Age, slbl=lt65, svarname=age_grp_dem, sval=1_lt65,
    modvars=sex_grp race_grp);

%run_strat(outcome=active_primary, olabel=Composite,
    svar=Age, slbl=ge65, svarname=age_grp_dem, sval=2_ge65,
    modvars=sex_grp race_grp);

/* -- Race strata -- */
%run_strat(outcome=active_primary, olabel=Composite,
    svar=Race, slbl=White, svarname=race_grp, sval=1_White,
    modvars=sex_grp age_grp_dem);

%run_strat(outcome=active_primary, olabel=Composite,
    svar=Race, slbl=Black, svarname=race_grp, sval=2_Black,
    modvars=sex_grp age_grp_dem);

%run_strat(outcome=active_primary, olabel=Composite,
    svar=Race, slbl=Other, svarname=race_grp, sval=3_Other,
    modvars=sex_grp age_grp_dem);

%run_strat(outcome=active_primary, olabel=Composite,
    svar=Race, slbl=Asian, svarname=race_grp, sval=4_Asian,
    modvars=sex_grp age_grp_dem);

%run_strat(outcome=active_primary, olabel=Composite,
    svar=Race, slbl=Hispanic, svarname=race_grp, sval=5_Hispanic,
    modvars=sex_grp age_grp_dem);

%run_strat(outcome=active_primary, olabel=Composite,
    svar=Race, slbl=AmIndian, svarname=race_grp, sval=6_AmIndian,
    modvars=sex_grp age_grp_dem);


/*===========================================================================
  SUMMARY AND SAVE
===========================================================================*/

proc sort data=work._all_strat_results;
    by outcome_lbl strat_var strat_lbl;
run;

proc print data=work._all_strat_results noobs label;
    var outcome_lbl strat_var strat_lbl PR PR_LCL PR_UCL ProbZ;
    format PR PR_LCL PR_UCL 8.3 ProbZ 8.4;
    title "Ibogaine Paper 2 -- Stratified Prevalence Ratios (Candidate vs Comparator)";
    title2 "All 20 models: Sex / Age / Race x Strong Inhibitor / Composite";
run;

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
%put NOTE: Review PROC PRINT output for PR and 95 CI by stratum.;
%put NOTE: AmIndian stratum may have sparse data -- check for convergence warnings.;
