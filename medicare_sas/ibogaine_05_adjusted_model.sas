/******************************************************************************
PROGRAM  : ibogaine_05_adjusted_model.sas
VERSION  : v1.8 (2026-08-13)
PURPOSE  : Adjusted prevalence ratio for Medicare FFS ibogaine first-pass
           analysis. Modified Poisson model with robust variance comparing
           strong CYP2D6 inhibitor exposure (active at index) between
           candidates (>=2 psych qualifiers) and comparators (0 qualifiers),
           adjusted for age, sex, RTI race, and dual eligibility.
******************************************************************************/

libname coh "/path/to/your/working/directory\Working\Cohorts";
libname res "/path/to/your/working/directory\Working\Ibogaine_FirstPass";
libname en  "/path/to/your/working/directory\Ibogaine_Extraction\Output\Enrollment";

/* -----------------------------------------------------------------------
   STEP 0: Preflight - confirm expected variables exist; abort if absent.
   Wrapped in a macro for server-compatibility with macro control flow.
   ----------------------------------------------------------------------- */
%macro preflight;
   %local _n _abort;
   %let _abort = 0;

   %macro _chkvar(ds, var);
      %local _n;
      proc sql noprint;
         select count(*) into :_n trimmed
         from dictionary.columns
         where upcase(libname) = upcase(scan("&ds.", 1, '.'))
           and upcase(memname)  = upcase(scan("&ds.", 2, '.'))
           and upcase(name)     = upcase("&var.");
      quit;
      %if &_n = 0 %then %do;
         %put ERROR: [preflight] &var. not found in &ds.;
         %let _abort = 1;
      %end;
   %mend;

   %_chkvar(coh.ibog_fp_analysis_fp_full_v001, bene_id)
   %_chkvar(coh.ibog_fp_analysis_fp_full_v001, index_dt)
   %_chkvar(coh.ibog_fp_analysis_fp_full_v001, primary_group_psych)
   %_chkvar(coh.ibog_fp_analysis_fp_full_v001, active_primary)

   %if &_abort = 1 %then %do;
      %put ERROR: Preflight failed. Check table/variable names and rerun.;
      %put ERROR: Expected table: coh.ibog_fp_analysis_fp_full_v001;
      %put ERROR: Confirm run_id=fp_full_v001 in res.ibog_run_manifest_fp_full_v001.;
      %put ERROR: If 99c used a different run_id, update the table name above.;
      %abort cancel;
   %end;
   %put NOTE: Preflight passed.;
%mend preflight;
%preflight;

/* -----------------------------------------------------------------------
   STEP 1: Build analytic cohort - candidates and comparators, classifiable
   ----------------------------------------------------------------------- */
proc sql;
   create table _cohort as
   select bene_id,
          primary_group_psych,
          active_primary as exposed,
          index_dt,
          year(index_dt) as index_yr,
          month(index_dt) as index_mo
   from coh.ibog_fp_analysis_fp_full_v001
   where primary_group_psych in ('CANDIDATE','COMPARATOR')
     and not missing(active_primary);
quit;

/* Report N using PROC SQL to avoid leaving file handle open */
proc sql noprint;
   select count(*) into :_cohort_n trimmed from _cohort;
quit;
%put NOTE: Analytic cohort N = &_cohort_n.;

/* Confirm group sizes and crude exposure rates */
proc freq data=_cohort;
   tables primary_group_psych * exposed / norow nocol nopercent missing;
   title "Cohort: group x exposure (confirms primary result before adjustment)";
run;

/* -----------------------------------------------------------------------
   STEP 2: Build bene_id + index_year lookup keys for hash join
   This avoids stacking all 7 years of enrollment into WORK.
   ----------------------------------------------------------------------- */
proc sort data=_cohort (keep=bene_id index_yr) out=_keys nodupkey;
   by bene_id index_yr;
run;

/* -----------------------------------------------------------------------
   STEP 3: Read only needed enrollment records using hash lookup
   For each enrollment row, check whether (bene_id, year) is in _keys.
   Only those rows are output - typically ~1 row per analytic beneficiary.
   ----------------------------------------------------------------------- */
data _enroll_needed;
   length bene_id $15;
   if _N_ = 1 then do;
      declare hash h(dataset:'_keys');
      h.defineKey('bene_id','index_yr');
      h.defineDone();
   end;

   set en.master_12016 - en.master_12022
      (keep=bene_id bene_enrollmt_ref_yr bene_birth_dt
            sex_ident_cd rti_race_cd
            dual_stus_cd_01-dual_stus_cd_12);

   index_yr = bene_enrollmt_ref_yr;
   if h.find() = 0 then output;
   drop index_yr;
run;

%macro log_enroll_n;
   %local _n_matched;
   proc sql noprint;
      select count(*) into :_n_matched trimmed from _enroll_needed;
   quit;
   %put NOTE: Enrollment records matched = &_n_matched.;
%mend log_enroll_n;
%log_enroll_n;

/* Assert uniqueness of enrollment records (one per bene_id + year).
   Hard abort if duplicates found - an annual MBSF should not contain
   two different demographic rows for the same bene/year. */
proc sort data=_enroll_needed nodupkey dupout=_enroll_dups;
   by bene_id bene_enrollmt_ref_yr;
run;

%macro check_enroll_dups;
   %local _ndups;
   proc sql noprint;
      select count(*) into :_ndups trimmed from _enroll_dups;
   quit;
   %if &_ndups > 0 %then %do;
      %put ERROR: &_ndups. duplicate enrollment records found for same bene/year.;
      %put ERROR: Annual MBSF should be unique by bene_id + year.;
      %put ERROR: Investigate _enroll_dups before proceeding.;
      %abort cancel;
   %end;
   %else %put NOTE: Enrollment uniqueness confirmed - no duplicates.;
%mend check_enroll_dups;
%check_enroll_dups;

/* -----------------------------------------------------------------------
   STEP 4: Join demographics to cohort on bene_id + index year
   ----------------------------------------------------------------------- */
proc sql;
   create table _analytic as
   select c.bene_id,
          c.primary_group_psych,
          c.exposed,
          c.index_dt,
          c.index_yr,
          c.index_mo,
          /* Age: floor((index_dt - birth_dt)/365.25) - consistent with
             02_covariates.sas convention and compatible with all SAS versions.
             intck('year',...,'continuous') requires SAS 9.3+ and behaves
             differently from the floor/365.25 approach used elsewhere. */
          case when missing(e.bene_birth_dt) then .
               else floor((c.index_dt - e.bene_birth_dt) / 365.25)
          end as age_at_index,
          e.sex_ident_cd,
          e.rti_race_cd,
          /* Dual eligibility: index-month indicator only (pre-index).
             Uses the monthly MBSF field corresponding to the index month.
             Values not in ('00','**',' ','') = dual eligible.
             Missing enrollment record = UNKNOWN. */
          case
            when missing(e.bene_id) then 'UNKNOWN'
            /* CMS DUAL_STUS_CD values per ResDAC documentation:
               01-09 = specific dual-eligible categories (QMB-only, SLMB, etc.)
               10    = other dual eligible
               00    = Medicare enrolled but NOT Medicaid dual
               NA    = Medicare enrolled, non-Medicaid (NOT_DUAL)
               99    = unknown dual status
               00/99/blank/** = treat as UNKNOWN (investigate, not silently NOT_DUAL)
               v1.5: replaced NOT IN (00,**,blank) with explicit dual-code list */
            when c.index_mo = 1  and e.dual_stus_cd_01 in ('01','02','03','04','05','06','07','08','09','10') then 'DUAL'
            when c.index_mo = 2  and e.dual_stus_cd_02 in ('01','02','03','04','05','06','07','08','09','10') then 'DUAL'
            when c.index_mo = 3  and e.dual_stus_cd_03 in ('01','02','03','04','05','06','07','08','09','10') then 'DUAL'
            when c.index_mo = 4  and e.dual_stus_cd_04 in ('01','02','03','04','05','06','07','08','09','10') then 'DUAL'
            when c.index_mo = 5  and e.dual_stus_cd_05 in ('01','02','03','04','05','06','07','08','09','10') then 'DUAL'
            when c.index_mo = 6  and e.dual_stus_cd_06 in ('01','02','03','04','05','06','07','08','09','10') then 'DUAL'
            when c.index_mo = 7  and e.dual_stus_cd_07 in ('01','02','03','04','05','06','07','08','09','10') then 'DUAL'
            when c.index_mo = 8  and e.dual_stus_cd_08 in ('01','02','03','04','05','06','07','08','09','10') then 'DUAL'
            when c.index_mo = 9  and e.dual_stus_cd_09 in ('01','02','03','04','05','06','07','08','09','10') then 'DUAL'
            when c.index_mo = 10 and e.dual_stus_cd_10 in ('01','02','03','04','05','06','07','08','09','10') then 'DUAL'
            when c.index_mo = 11 and e.dual_stus_cd_11 in ('01','02','03','04','05','06','07','08','09','10') then 'DUAL'
            when c.index_mo = 12 and e.dual_stus_cd_12 in ('01','02','03','04','05','06','07','08','09','10') then 'DUAL'
            when c.index_mo = 1  and e.dual_stus_cd_01 = 'NA' then 'NOT_DUAL'
            when c.index_mo = 2  and e.dual_stus_cd_02 = 'NA' then 'NOT_DUAL'
            when c.index_mo = 3  and e.dual_stus_cd_03 = 'NA' then 'NOT_DUAL'
            when c.index_mo = 4  and e.dual_stus_cd_04 = 'NA' then 'NOT_DUAL'
            when c.index_mo = 5  and e.dual_stus_cd_05 = 'NA' then 'NOT_DUAL'
            when c.index_mo = 6  and e.dual_stus_cd_06 = 'NA' then 'NOT_DUAL'
            when c.index_mo = 7  and e.dual_stus_cd_07 = 'NA' then 'NOT_DUAL'
            when c.index_mo = 8  and e.dual_stus_cd_08 = 'NA' then 'NOT_DUAL'
            when c.index_mo = 9  and e.dual_stus_cd_09 = 'NA' then 'NOT_DUAL'
            when c.index_mo = 10 and e.dual_stus_cd_10 = 'NA' then 'NOT_DUAL'
            when c.index_mo = 11 and e.dual_stus_cd_11 = 'NA' then 'NOT_DUAL'
            when c.index_mo = 12 and e.dual_stus_cd_12 = 'NA' then 'NOT_DUAL'
            else 'UNKNOWN'  /* 00, 99, **, blank, unexpected code, or no enrollment record */
          end as dual_grp length=10  /* NOT_DUAL=8 chars; $10 provides margin */
   from _cohort c
   left join _enroll_needed e
      on  c.bene_id  = e.bene_id
      and c.index_yr = e.bene_enrollmt_ref_yr;
quit;

%macro assert_analytic_unique;
   %local _nanalytic _nuniq;
   proc sql noprint;
      select count(*), count(distinct bene_id)
         into :_nanalytic trimmed, :_nuniq trimmed
      from _analytic;
   quit;
   %if &_nanalytic ne &_nuniq %then %do;
      %put ERROR: _analytic has &_nanalytic. rows but &_nuniq. unique bene_ids.;
      %put ERROR: Enrollment join produced duplicates. Check _enroll_needed.;
      %abort cancel;
   %end;
   %else
      %put NOTE: _analytic uniqueness confirmed: &_nanalytic. rows = &_nuniq. benes.;
%mend assert_analytic_unique;
%assert_analytic_unique;

/* Check merge quality */
proc freq data=_analytic;
   tables sex_ident_cd rti_race_cd dual_grp / missing;
   title "Demographic merge quality - % missing indicates unmatched enrollment";
run;

/* -----------------------------------------------------------------------
   STEP 5: Derive analysis variables
   Missing handled explicitly before range comparisons.
   ----------------------------------------------------------------------- */
data _analytic;
   set _analytic;
   /* v1.4: explicit lengths prevent SAS from truncating to first
      assignment value (e.g. sex_grp length 6 from "1_Male" would
      truncate "2_Female" to "2_Femal"). */
   length age_grp $9 sex_grp $9 race_grp $12 dual_grp $10;

   candidate = (primary_group_psych = 'CANDIDATE');

   /* Age groups - missing first */
   /* v1.8: guard for missing, negative, or implausibly large age
      (data anomaly - negative result from missing/garbled birth date,
      or age > 115 indicating a date processing error). */
   if      missing(age_at_index)             then age_grp = '9_Missing';
   else if age_at_index < 0 or age_at_index > 115 then age_grp = '9_Missing'; /* implausible */
   else if age_at_index < 35                 then age_grp = '1_lt35';
   else if age_at_index < 50                 then age_grp = '2_35to49';
   else if age_at_index < 65                 then age_grp = '3_50to64';
   else                                           age_grp = '4_65plus';

   /* RTI race - matches 02_covariates convention */
   /* RTI race: code 3 = Other (explicitly distinct from missing/unknown) */
   if      rti_race_cd = '1' then race_grp = '1_White';
   else if rti_race_cd = '2' then race_grp = '2_Black';
   else if rti_race_cd = '5' then race_grp = '3_Hispanic';
   else if rti_race_cd = '6' then race_grp = '4_AIAN';
   else if rti_race_cd = '4' then race_grp = '5_Asian_PI';
   else if rti_race_cd = '3' then race_grp = '6_Other';
   else                           race_grp = '9_Unknown';  /* missing or unrecognized code */

   /* Sex */
   if      sex_ident_cd = '1' then sex_grp = '1_Male';
   else if sex_ident_cd = '2' then sex_grp = '2_Female';
   else                            sex_grp = '9_Unknown';
run;

/* Save demographic table */
data res.ibog_adj_demog_v1;
   set _analytic (keep=bene_id primary_group_psych candidate exposed
                       age_at_index age_grp sex_grp race_grp dual_grp);
run;
%put NOTE: Demographic table saved to res.ibog_adj_demog_v1;

proc freq data=_analytic;
   tables candidate * (age_grp sex_grp race_grp dual_grp) / norow nocol nopercent;
   title "Demographic distribution by candidate/comparator status";
run;

/* -----------------------------------------------------------------------
   STEP 5b: QC check on derived analysis variables before modeling
   ----------------------------------------------------------------------- */
proc freq data=_analytic;
   tables age_grp sex_grp race_grp dual_grp / missing;
   title "QC: derived variable distribution before modeling";
   title2 "Flag: 9_Missing/9_Unknown > 5% may indicate enrollment merge failure";
run;

/* -----------------------------------------------------------------------
   STEP 6: Unadjusted prevalence ratio - modified Poisson, robust variance
   ----------------------------------------------------------------------- */
proc genmod data=_analytic;
   class bene_id candidate (ref='0') / param=ref;
   model exposed = candidate / dist=poisson link=log;
   repeated subject=bene_id / type=ind;
   estimate 'Candidate vs Comparator (unadjusted)' candidate 1 / exp;
   ods output estimates=_unadj_pr ;
   title "Unadjusted prevalence ratio - Medicare FFS ibogaine cohort";
run;

/* -----------------------------------------------------------------------
   STEP 7: Two adjusted models
   Model 1: age + sex + race only - harmonized with AoU for cross-cohort
            comparison in the three-cohort table
   Model 2: age + sex + race + dual eligibility - Medicare-specific;
            dual is a meaningful socioeconomic confounder in this population
   Both exclude missing-demographic rows.
   ----------------------------------------------------------------------- */
/* v1.4: also exclude 9_Unknown race for transparency.
   Save the N included vs excluded for reporting. */
/* v1.6: separate N counts for each model's exclusion criteria */
%macro save_adj_n;
   %local _n1_incl _n1_excl _n2_incl _n2_excl;
   proc sql noprint;
      /* Model 1: excludes missing age/sex/race only */
      select count(*) into :_n1_incl trimmed from _analytic
         where age_grp ne '9_Missing' and sex_grp ne '9_Unknown'
           and race_grp ne '9_Unknown';
      select count(*) into :_n1_excl trimmed from _analytic
         where not(age_grp ne '9_Missing' and sex_grp ne '9_Unknown'
           and race_grp ne '9_Unknown');
      /* Model 2: also excludes unknown dual */
      select count(*) into :_n2_incl trimmed from _analytic
         where age_grp ne '9_Missing' and sex_grp ne '9_Unknown'
           and race_grp ne '9_Unknown' and dual_grp ne 'UNKNOWN';
      select count(*) into :_n2_excl trimmed from _analytic
         where not(age_grp ne '9_Missing' and sex_grp ne '9_Unknown'
           and race_grp ne '9_Unknown' and dual_grp ne 'UNKNOWN');
   quit;
   %put NOTE: Model 1 N included = &_n1_incl., excluded = &_n1_excl.;
   %put NOTE: Model 2 N included = &_n2_incl., excluded = &_n2_excl.;
%mend save_adj_n;
%save_adj_n;

proc genmod data=_analytic
      (where=(age_grp ne '9_Missing' and sex_grp ne '9_Unknown'
              and race_grp ne '9_Unknown'));
   class bene_id candidate  (ref='0')
         age_grp    (ref='1_lt35')
         sex_grp    (ref='1_Male')
         race_grp   (ref='1_White')
         / param=ref;
   model exposed = candidate age_grp sex_grp race_grp
                   / dist=poisson link=log;
   repeated subject=bene_id / type=ind;
   estimate 'Candidate vs Comparator (Model 1: age+sex+race)' candidate 1 / exp;
   ods output estimates=_adj_pr1 ;
   title "Model 1 (harmonized): Adjusted PR - age, sex, RTI race";
run;

/* Model 2: age + sex + race + dual (Medicare-specific sensitivity) */
proc genmod data=_analytic
      (where=(age_grp ne '9_Missing' and sex_grp ne '9_Unknown'
              and race_grp ne '9_Unknown' and dual_grp ne 'UNKNOWN'));
   class bene_id candidate  (ref='0')
         age_grp    (ref='1_lt35')
         sex_grp    (ref='1_Male')
         race_grp   (ref='1_White')
         dual_grp   (ref='NOT_DUAL')
         / param=ref;
   model exposed = candidate age_grp sex_grp race_grp dual_grp
                   / dist=poisson link=log;
   repeated subject=bene_id / type=ind;
   estimate 'Candidate vs Comparator (Model 2: +dual)' candidate 1 / exp;
   ods output estimates=_adj_pr2 ;
   title "Model 2 (Medicare-specific): Adjusted PR - age, sex, RTI race, dual";
run;

/* -----------------------------------------------------------------------
   STEP 8: Print and save results
   ----------------------------------------------------------------------- */
proc print data=_unadj_pr noobs label;
   title "Unadjusted PR - Medicare FFS ibogaine (modified Poisson)";
run;
proc print data=_adj_pr1 noobs label;
   title "Model 1 (harmonized): Adjusted PR - age, sex, RTI race";
run;
proc print data=_adj_pr2 noobs label;
   title "Model 2 (Medicare-specific): Adjusted PR - age, sex, RTI race, dual";
run;


data res.ibog_adj_pr_v1;
   length model $35;
   set _unadj_pr (in=u) _adj_pr1 (in=a1) _adj_pr2 (in=a2);
   if u  then model = 'Unadjusted';
   if a1 then model = 'Adjusted_Model1_age_sex_race';
   if a2 then model = 'Adjusted_Model2_age_sex_race_dual';
run;
/* Append model metadata row with N included/excluded */
%macro append_adj_meta;
   %local _n1_incl _n1_excl _n2_incl _n2_excl;
   proc sql noprint;
      select count(*) into :_n1_incl trimmed from _analytic
         where age_grp ne '9_Missing' and sex_grp ne '9_Unknown'
           and race_grp ne '9_Unknown';
      select count(*) into :_n1_excl trimmed from _analytic
         where not(age_grp ne '9_Missing' and sex_grp ne '9_Unknown'
           and race_grp ne '9_Unknown');
      select count(*) into :_n2_incl trimmed from _analytic
         where age_grp ne '9_Missing' and sex_grp ne '9_Unknown'
           and race_grp ne '9_Unknown' and dual_grp ne 'UNKNOWN';
      select count(*) into :_n2_excl trimmed from _analytic
         where not(age_grp ne '9_Missing' and sex_grp ne '9_Unknown'
           and race_grp ne '9_Unknown' and dual_grp ne 'UNKNOWN');
   quit;
   data _meta;
      length model $35 label $200;
      model = 'Metadata';
      label = cats("Model1 N included: ", &_n1_incl., " excluded: ", &_n1_excl.,
                   " | Model2 N included: ", &_n2_incl., " excluded: ", &_n2_excl.);
      MeanEstimate = .;
   run;
   proc append base=res.ibog_adj_pr_v1 data=_meta force; run;
%mend append_adj_meta;
%append_adj_meta;
%put NOTE: PR results saved to res.ibog_adj_pr_v1;

/* Cleanup */
proc datasets lib=work nolist;
   delete _cohort _keys _enroll_needed _enroll_dups _analytic
          _unadj_pr _unadj_pe _adj_pr1 _adj_pe1 _adj_pr2 _adj_pe2 _meta;
quit;

/* end ibogaine_05_adjusted_model.sas v1.8 */
