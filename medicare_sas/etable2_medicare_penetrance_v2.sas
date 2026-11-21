/*============================================================
  eTable 2 - Medicare FFS Penetrance by Demographic Group
  Sections B1 (Sex), B2 (Age Group 3-cat), B3 (Race/Ethnicity)

  PURPOSE:
    Clean penetrance output for eTable 2. Runs after
    ibogaine_demographic_analysis_v2_fixed.sas has been
    executed (needs the coh and out1 libnames already open),
    OR run this as a standalone program - libnames are set here.

  INSTRUCTIONS FOR IT:
    Run the full program top to bottom. No editing needed.
    Send the printed output (or ODS HTML/RTF output) back to
    James Green (jamesgreenmsa@gmail.com).

  NOTE: This program rebuilds the demographic join with a
    3-category age group (18-44 / 45-64 / 65+).
    The original program only computed <65 vs >=65.
    Age is derived as: year(anchor_dt) - year(bene_birth_dt).
    If bene_birth_dt is missing, patient is excluded from
    age-group rows only.
============================================================*/

options dlcreatedir compress=yes nofmterr nodate nonumber
        pagesize=80 linesize=120;

/* ── Libnames (same as ibogaine_demographic_analysis_v2_fixed.sas) ── */
/* -------------------------------------------------------------------------
   Set proj_root to the root of your local working directory before running.
   Example (Windows): %let proj_root = C:\Projects\Ibogaine;
   Example (Unix/Mac): %let proj_root = /data/projects/ibogaine;
   The pipeline expects subdirectories: Output, Working, Ibogaine_Extraction
   ------------------------------------------------------------------------- */
%let proj_root = /path/to/your/working/directory;
%let workp     = &proj_root.\Working;
libname coh  "&workp.\Cohorts";
libname out1 "&proj_root.\Output" access=readonly;

/* ── Source dataset and candidate variable ─────────────────────────── */
%let ds      = coh.ibog_fp_analysis_fp_full_v001;
%let grp_var = primary_group_psych;   /* CANDIDATE / COMPARATOR / INTERMEDIATE */

/*==============================================================
  STEP 1: Rebuild demographic join with 3-category age group
  (anchor year minus birth year from out1.enrollment_raw)
==============================================================*/
/*proc contents data=&ds. varnum; run;*/
/*proc contents data=out1.enrollment_raw; run;*/

proc sql;
create table work._bene_demog as
select bene_id,
	max(bene_birth_dt) as bene_birth_dt format = date9.,
	max(case when sex_ident_cd in ('1','2') then sex_ident_cd end) as sex_ident_cd,
	max(case when rti_race_cd between '1' and '6' then rti_race_cd end) as rti_race_cd
from out1.enrollment_raw
group by 1;
quit;

data work._cohort_yr;
 set &ds.;
 anchor_yr_c = year(anchor_dt);
run;



proc sql;
    create table work._etbl2 as
    select a.&grp_var.,
           /* Primary candidate indicator */
           case when a.&grp_var. = 'CANDIDATE' then 1 else 0
                end as is_cand,
           /* Sex */
           case when b.sex_ident_cd = '2' then 'Female'
                when b.sex_ident_cd = '1' then 'Male'
                else 'Unknown' end as sex_grp length=10,
           /* Age group - 3 categories */
           case
             when b.bene_birth_dt is null then '9_Unknown'
             when (year(a.anchor_dt) - year(b.bene_birth_dt)) < 45
                  then '1_18to44'
             when (year(a.anchor_dt) - year(b.bene_birth_dt)) < 65
                  then '2_45to64'
             else '3_65plus'
           end as age_grp_3cat length=10,
           /* Race/ethnicity (RTI coding) */
           case when b.rti_race_cd = '1' then 'NH White'
                when b.rti_race_cd = '2' then 'NH Black'
                when b.rti_race_cd = '5' then 'Hispanic/Latino'
                when b.rti_race_cd = '4' then 'NH Asian'
                when b.rti_race_cd in ('3','6') then 'Other/Unknown'
                else '9_Missing' end as race_grp length=20
    from work._cohort_yr a
    left join work._bene_demog b
        on  a.bene_id = b.bene_id;
/*        and b.bene_enrollmt_ref_yr = a.anchor_yr_c;*/
/*in ('2015', '2016', '2017', '2018', '2019', '2020', '2021');*/
quit;

/*==============================================================
  STEP 2: QC - confirm Ns and distributions
==============================================================*/
title "QC: Overall candidate counts";
proc sql;
    select &grp_var.,
           count(*)     as N          format=comma12.,
           100*mean(is_cand) as Pct_Cand format=8.1
    from work._etbl2
    group by &grp_var.;
quit;
title;

title "QC: Sex distribution";
proc freq data=work._etbl2; tables sex_grp / missing; run; title;

title "QC: Age group (3-cat) distribution";
proc freq data=work._etbl2; tables age_grp_3cat / missing; run; title;

title "QC: Race/ethnicity distribution";
proc freq data=work._etbl2; tables race_grp / missing; run; title;

/*==============================================================
  STEP 3: Penetrance helper macro
  Prints:  Category | N_OUD | N_Candidates | Penetrance(%)
==============================================================*/
%macro pen_table(data=, group=, label=);
  proc sql;
      create table _pen as
      select
          "&label"            as Section  length=30,
          strip(&group.)      as Category length=25,
          count(*)            as N_OUD    format=comma12.,
          sum(is_cand)        as N_Cand   format=comma12.,
          100*mean(is_cand)   as Pct_Cand format=8.1
      from &data.
      group by calculated Section, calculated Category
      order by calculated Section, calculated Category;
  quit;
  /* prepend Overall row */
  proc sql;
      insert into _pen_all
          select * from _pen;
      insert into _pen_all
          select "&label" as Section,
                 'Overall (within filter)' as Category,
                 count(*) as N_OUD,
                 sum(is_cand) as N_Cand,
                 100*mean(is_cand) as Pct_Cand
          from &data.;
  quit;
  title "PENETRANCE: &label";
  proc print data=_pen noobs label;
      var Section Category N_OUD N_Cand Pct_Cand;
      label Section   = "Section"
            Category  = "Demographic Category"
            N_OUD     = "N (Full OUD)"
            N_Cand    = "N Candidates"
            Pct_Cand  = "Penetrance (%)";
  run;
  title;
%mend;

/* Initialize accumulator table */
proc sql;
    create table _pen_all
        (Section   char(30),
         Category  char(25),
         N_OUD     num  format=comma12.,
         N_Cand    num  format=comma12.,
         Pct_Cand  num  format=8.1);
quit;

/*==============================================================
  SECTION B1: Sex
==============================================================*/
%pen_table(
    data = work._etbl2(where=(sex_grp in ('Female','Male'))),
    group = sex_grp,
    label = B1 Primary - Sex
);

/*==============================================================
  SECTION B2: Age Group (3 categories)
==============================================================*/
%pen_table(
    data = work._etbl2(where=(age_grp_3cat ne '9_Unknown')),
    group = age_grp_3cat,
    label = B2 Primary - Age Group
);

/*==============================================================
  SECTION B3: Race/Ethnicity
==============================================================*/
%pen_table(
    data = work._etbl2(where=(race_grp ne '9_Missing')),
    group = race_grp,
    label = B3 Primary - Race/Ethnicity
);

/*==============================================================
  FINAL SUMMARY - all sections in one table
==============================================================*/
title "FINAL SUMMARY: Medicare FFS Penetrance for eTable 2";
proc print data=_pen_all noobs label;
    var Section Category N_OUD N_Cand Pct_Cand;
    label Section  = "Section"
          Category = "Demographic Category"
          N_OUD    = "N (Full OUD)"
          N_Cand   = "N Candidates"
          Pct_Cand = "Penetrance (%)";
run;
title;

proc sql;
create table work._panelB as
select primary_group_psych, 
	case when a.active_bupropion =1 or a.active_paroxetine = 1 or a.active_fluoxetine =1
	  then 1 else 0 end as strong_inhib,
 	case when b.sex_ident_cd = '2' then 'Female'
 	  when b.sex_ident_cd = '1' then 'Male'
	  else 'Unknown' end as sex_grp length = 10
from coh.ibog_fp_analysis_fp_full_v001 a
left join work._bene_demog b
on a.bene_id = b.bene_id;
/*where primary_group_psych = 'CANDIDATE' AND calculated sex_grp in ('Female', 'Male');*/
quit;

proc freq data=work._panelB; 
where primary_group_psych = 'CANDIDATE' AND sex_grp in ('Female', 'Male') ;
tables sex_grp * strong_inhib / norow nocol nopercent; run;

/* Cleanup */
proc datasets lib=work nolist; delete _etbl2 _pen _pen_all _bene_demog; quit;

%put NOTE: Done. Send the FINAL SUMMARY table to James Green.;
%put NOTE: NOTE: psych-only (>=2 of PTSD/dep/anx only) not computed;
%put NOTE:       here - requires individual qualifier flags not confirmed;
%put NOTE:       on coh.ibog_fp_analysis_fp_full_v001. Check with James.;

proc contents 
data=coh.ibog_fp_analysis_fp_full_v001
varnum; run;