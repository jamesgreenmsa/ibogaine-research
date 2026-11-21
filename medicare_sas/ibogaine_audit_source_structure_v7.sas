/*===========================================================================
  ibogaine_audit_source_structure_v7.sas
  IFH Citrix Server - crdw-ifhsas02-prod-asb.rad.rutgers.edu
  Author : James Green
  Created: August 2026

  OUTCOME-BLINDING RULE
  =====================
  This program inspects metadata, enrollment structure, exposure and
  covariate sources, and the code used to define the cardiac endpoint.
  It does NOT display or summarize any cardiac outcome observations.
  No record-level cardiac outcome data are printed or aggregated.

  Changes from v6:
  - PD libname: removed guessed path assignment. Replaced with
    'libname pd list' to verify whether PD is already assigned, plus
    a clear instruction to copy the path from the cohort-builder program.
    A wrong PD path could miss the actual Part D source tables entirely.
  - Section E: stale 307,326 comment removed. SQL is authoritative.
  - A2/A3 frequency macros: each yearly call now checks that the
    variable exists in that specific year before running PROC FREQ.
    Prevents an ERROR if a variable is renamed or absent in one year.

  Libnames:
    libname coh  "/path/to/your/working/directory\Working\Cohorts";
    libname ibog "/path/to/your/working/directory\Ibogaine_Extraction\Output";
    libname iben "/path/to/your/working/directory\Ibogaine_Extraction\Output\Enrollment";
    libname pd   (confirm path - likely same root as ibog)

  Source code directory:
    %let pgm_dir = /path/to/your/working/directory\Ibogaine_Extraction\i_code;
    NOTE: If dopen fails on this server, D4b outputs an error message
    and the program continues. Check the log for that message and
    locate the source program manually if needed.
===========================================================================*/

options nodate nonumber mprint;

libname coh  "/path/to/your/working/directory\Working\Cohorts";
libname ibog "/path/to/your/working/directory\Ibogaine_Extraction\Output";
libname iben "/path/to/your/working/directory\Ibogaine_Extraction\Output\Enrollment";

/* PD library - DO NOT GUESS THE PATH.
   Copy the exact libname pd statement from the cohort-builder program
   (likely one of the 99c or first-pass programs) and paste it here.
   Until confirmed, the PD libname is intentionally left unassigned.
   If PD is already assigned by a server autoexec or cascaded libname,
   the dictionary queries in B10 will find it automatically.
   The libname list below (run before B10) will confirm whether PD
   is already available in this session. */
%put NOTE: Checking whether PD libname is already assigned in this session...;
libname pd list;

/* Source code directory for endpoint program discovery */
%let pgm_dir = /path/to/your/working/directory\Ibogaine_Extraction\i_code;


/* ═══════════════════════════════════════════════════════════════════════════
   SECTION A: ENROLLMENT FILE STRUCTURE - ALL SEVEN YEARS
   ═══════════════════════════════════════════════════════════════════════════ */

%put NOTE: ============================================================;
%put NOTE: SECTION A: ENROLLMENT FILE STRUCTURE - ALL SEVEN YEARS;
%put NOTE: ============================================================;

/* A: Extract metadata from all seven enrollment years */
%macro enroll_contents(yr);
    proc contents data=iben.master_1&yr out=_ec_&yr noprint; run;
    data _ec_&yr; set _ec_&yr; year = &yr; run;
%mend;
%enroll_contents(2016);
%enroll_contents(2017);
%enroll_contents(2018);
%enroll_contents(2019);
%enroll_contents(2020);
%enroll_contents(2021);
%enroll_contents(2022);

data _enroll_all_years;
    set _ec_2016 _ec_2017 _ec_2018 _ec_2019 _ec_2020 _ec_2021 _ec_2022;
run;

/* A1-A3: Death, buy-in, Part D variables - all years */
title "A1-A3: Death / buy-in / Part D variables across all enrollment years";
proc sql;
    select year, name, type, length, format, label
    from _enroll_all_years
    where upcase(name) like '%DEATH%'
       or upcase(name) like '%BUYIN%'
       or upcase(name) like '%ENROLL%'
       or upcase(name) like '%PTDB%'
       or upcase(name) like '%PART_D%'
       or upcase(name) like '%PARTD%'
       or upcase(name) like '%DUAL%'
       or upcase(name) like '%HMO%'
       or upcase(name) like '%COVG%'
       or upcase(name) like '%STATUS%'
       or upcase(name) like '%MDCR%'
    order by name, year;
quit;
title;

/* A5: Variable name consistency - GROUP BY before HAVING (syntax fix) */
title "A5: Variables NOT present in all seven years (structural changes)";
proc sql;
    select name,
           sum(case when year=2016 then 1 else 0 end) as yr2016,
           sum(case when year=2017 then 1 else 0 end) as yr2017,
           sum(case when year=2018 then 1 else 0 end) as yr2018,
           sum(case when year=2019 then 1 else 0 end) as yr2019,
           sum(case when year=2020 then 1 else 0 end) as yr2020,
           sum(case when year=2021 then 1 else 0 end) as yr2021,
           sum(case when year=2022 then 1 else 0 end) as yr2022,
           count(distinct year) as n_years_present
    from _enroll_all_years
    group by name
    having count(distinct year) < 7
    order by name;
quit;
title;

/* A4: Row count per year */
title "A4: Row and unique bene count per enrollment year";
proc sql;
    select '2016' as year, count(*) as n_rows,
           count(distinct bene_id) as n_unique_bene
    from iben.master_12016
    union all
    select '2017', count(*), count(distinct bene_id) from iben.master_12017
    union all
    select '2018', count(*), count(distinct bene_id) from iben.master_12018
    union all
    select '2019', count(*), count(distinct bene_id) from iben.master_12019
    union all
    select '2020', count(*), count(distinct bene_id) from iben.master_12020
    union all
    select '2021', count(*), count(distinct bene_id) from iben.master_12021
    union all
    select '2022', count(*), count(distinct bene_id) from iben.master_12022
    order by year;
quit;
title;

/* A2: Buy-in frequencies - ALL SEVEN YEARS
   Wrapped in %macro/%mend for server reliability.
   Runs only if BUYIN_IND confirmed present in metadata above.
   If variable name differs, update &buyin_var after reviewing A1-A3. */

%macro check_buyin_var;
    proc sql noprint;
        select count(*) into :has_buyin trimmed
        from _enroll_all_years
        where upcase(name) = 'BUYIN_IND' and year = 2016;

        /* Also try common alternate names */
        select count(*) into :has_buyin_alt trimmed
        from _enroll_all_years
        where (upcase(name) like '%BUYIN%'
            or upcase(name) like '%ENROLL%'
            or upcase(name) like '%BENE_MDCR%')
          and year = 2016;
    quit;
    %put NOTE: A2: has_buyin=&has_buyin has_buyin_alt=&has_buyin_alt;
%mend;
%check_buyin_var;

%macro buyin_freq(yr);
    /* Check BUYIN_IND exists in this specific year before running */
    proc contents data=iben.master_1&yr out=_chk_buyin_&yr noprint; run;
    proc sql noprint;
        select count(*) into :has_buyin_&yr trimmed
        from _chk_buyin_&yr
        where upcase(name) = 'BUYIN_IND';
        drop table _chk_buyin_&yr;
    quit;
    %if &&has_buyin_&yr > 0 %then %do;
        title "A2: Buy-in indicator values - &yr";
        proc freq data=iben.master_1&yr;
            tables BUYIN_IND / missing;
        run;
        title;
    %end;
    %else %do;
        %put NOTE: A2: BUYIN_IND not found in iben.master_1&yr -- structural change.;
        %put NOTE: A2: Review A5 output for the correct variable name in &yr.;
    %end;
%mend;

%macro run_buyin_all_years;
    proc sql noprint;
        select count(*) into :has_buyin trimmed
        from _enroll_all_years
        where upcase(name) = 'BUYIN_IND' and year = 2016;
    quit;
    %if &has_buyin > 0 %then %do;
        %buyin_freq(2016);
        %buyin_freq(2017);
        %buyin_freq(2018);
        %buyin_freq(2019);
        %buyin_freq(2020);
        %buyin_freq(2021);
        %buyin_freq(2022);
    %end;
    %else %do;
        %put NOTE: A2: BUYIN_IND not found. Review A1-A3 output for correct name.;
        %put NOTE: A2: Update buyin_freq macro call with correct variable name.;
    %end;
%mend;
%run_buyin_all_years;

/* A3: Part D coverage - ALL SEVEN YEARS */
%macro ptdb_freq(yr);
    /* Check that PTDB_IND exists in this specific year before running */
    proc contents data=iben.master_1&yr out=_chk_ptdb_&yr noprint; run;
    proc sql noprint;
        select count(*) into :has_ptdb_&yr trimmed
        from _chk_ptdb_&yr
        where upcase(name) = 'PTDB_IND';
        drop table _chk_ptdb_&yr;
    quit;
    %if &&has_ptdb_&yr > 0 %then %do;
        title "A3: Part D coverage indicator - &yr";
        proc freq data=iben.master_1&yr;
            tables PTDB_IND / missing;
        run;
        title;
    %end;
    %else %do;
        %put NOTE: A3: PTDB_IND not found in iben.master_1&yr -- structural change detected.;
        %put NOTE: A3: Review A5 output to identify the correct variable name for &yr.;
    %end;
%mend;

%macro run_ptdb_all_years;
    proc sql noprint;
        select count(*) into :has_ptdb trimmed
        from _enroll_all_years
        where upcase(name) = 'PTDB_IND' and year = 2016;
    quit;
    %if &has_ptdb > 0 %then %do;
        %ptdb_freq(2016);
        %ptdb_freq(2017);
        %ptdb_freq(2018);
        %ptdb_freq(2019);
        %ptdb_freq(2020);
        %ptdb_freq(2021);
        %ptdb_freq(2022);
    %end;
    %else %do;
        %put NOTE: A3: PTDB_IND not found. Review A1-A3 output for correct name.;
        %put NOTE: A3: Update ptdb_freq macro call with correct variable name.;
    %end;
%mend;
%run_ptdb_all_years;


/* ═══════════════════════════════════════════════════════════════════════════
   SECTION B: FIRST-PASS TABLE - COVARIATE AVAILABILITY
   ═══════════════════════════════════════════════════════════════════════════ */

%put NOTE: ============================================================;
%put NOTE: SECTION B: FIRST-PASS TABLE COVARIATE AVAILABILITY;
%put NOTE: ============================================================;

title "B: Full variable list - coh.ibog_fp_analysis_fp_full_v001";
proc contents data=coh.ibog_fp_analysis_fp_full_v001 varnum;
    ods select Variables;
run;
title;

proc contents data=coh.ibog_fp_analysis_fp_full_v001
    out=_audit_fp noprint; run;

title "B1-B9: Required covariate availability flags (1=present, 0=missing)";
proc sql;
    select
        max(case when upcase(name) in ('AGE','AGE_AT_INDEX','BENE_AGE')
            then 1 else 0 end)                              as has_age,
        max(case when upcase(name) = 'BENE_BIRTH_DT'
            then 1 else 0 end)                              as has_birthdt,
        max(case when upcase(name) in ('SEX','BENE_SEX_IDENT_CD','BENE_SEX')
            then 1 else 0 end)                              as has_sex,
        max(case when upcase(name) like '%RTI%'
                  or upcase(name) like '%RACE%'
            then 1 else 0 end)                              as has_race,
        max(case when upcase(name) like '%PTSD%'
            then 1 else 0 end)                              as has_ptsd,
        max(case when upcase(name) like '%DEPRESS%'
                  or upcase(name) like '%MDD%'
            then 1 else 0 end)                              as has_depression,
        max(case when upcase(name) like '%ANXI%'
            then 1 else 0 end)                              as has_anxiety,
        max(case when upcase(name) like '%HEART_FAIL%'
                  or upcase(name) in ('PRIOR_HF','DX_HF','HF_IND')
            then 1 else 0 end)                              as has_hf,
        max(case when upcase(name) like '%ISCHEMIC%'
                  or upcase(name) like '%AMI%'
                  or upcase(name) in ('PRIOR_MI','DX_IHD','IHD_IND')
            then 1 else 0 end)                              as has_ischemic,
        max(case when upcase(name) like '%CARDIOMY%'
            then 1 else 0 end)                              as has_cardiomyop,
        max(case when upcase(name) like '%AFIB%'
                  or upcase(name) like '%ATRIAL_FIB%'
            then 1 else 0 end)                              as has_afib,
        max(case when upcase(name) like '%HYPERT%'
                  or upcase(name) like '%HTN%'
            then 1 else 0 end)                              as has_htn,
        max(case when upcase(name) like '%DIABET%'
            then 1 else 0 end)                              as has_diabetes,
        max(case when upcase(name) like '%CKD%'
                  or upcase(name) like '%RENAL%'
            then 1 else 0 end)                              as has_ckd,
        max(case when upcase(name) like '%LQT%'
                  or upcase(name) like '%LONG_QT%'
                  or upcase(name) like '%SYNCOPE%'
            then 1 else 0 end)                              as has_lqt_syncope,
        max(case when upcase(name) like '%METHADON%'
            then 1 else 0 end)                              as has_methadone,
        max(case when upcase(name) like '%BUPREN%'
            then 1 else 0 end)                              as has_buprenorphine,
        max(case when upcase(name) like '%NALTREX%'
            then 1 else 0 end)                              as has_naltrexone,
        max(case when upcase(name) like '%ANTIPSY%'
                  or upcase(name) like '%QT_MED%'
                  or upcase(name) like '%QT_DRUG%'
            then 1 else 0 end)                              as has_antipsych,
        max(case when upcase(name) like '%INPAT%'
                  or upcase(name) like '%IP_CLAIM%'
            then 1 else 0 end)                              as has_inpatient_ct,
        max(case when upcase(name) like '%OUTPAT%'
                  or upcase(name) like '%OP_CLAIM%'
            then 1 else 0 end)                              as has_outpatient_ct,
        max(case when upcase(name) like '%N_DRUG%'
                  or upcase(name) like '%N_MED%'
                  or upcase(name) like '%N_INGRED%'
                  or upcase(name) like '%POLYPHARM%'
                  or upcase(name) like '%TOTAL_MED%'
                  or upcase(name) like '%DISTINCT%'
            then 1 else 0 end)                              as has_polypharm_ct
    from _audit_fp;
quit;
title;

title "B: Variables matching covariate name patterns - manual review";
proc sql;
    select name, type, length, label
    from _audit_fp
    where upcase(name) like '%AGE%'
       or upcase(name) like '%SEX%'
       or upcase(name) like '%RACE%'
       or upcase(name) like '%RTI%'
       or upcase(name) like '%PTSD%'
       or upcase(name) like '%DEPRESS%'
       or upcase(name) like '%MDD%'
       or upcase(name) like '%ANXI%'
       or upcase(name) like '%HEART%'
       or upcase(name) like '%CARDIAC%'
       or upcase(name) like '%LQT%'
       or upcase(name) like '%SYNCOPE%'
       or upcase(name) like '%AFIB%'
       or upcase(name) like '%ISCHEMIC%'
       or upcase(name) like '%CARDIOMY%'
       or upcase(name) like '%AMI%'
       or upcase(name) like '%HTN%'
       or upcase(name) like '%HYPERT%'
       or upcase(name) like '%CKD%'
       or upcase(name) like '%RENAL%'
       or upcase(name) like '%DIABET%'
       or upcase(name) like '%METHADON%'
       or upcase(name) like '%BUPREN%'
       or upcase(name) like '%NALTREX%'
       or upcase(name) like '%MOUD%'
       or upcase(name) like '%ANTIPSY%'
       or upcase(name) like '%QT%'
       or upcase(name) like '%DRUG%'
       or upcase(name) like '%INGRED%'
       or upcase(name) like '%INPAT%'
       or upcase(name) like '%OUTPAT%'
       or upcase(name) like '%CLAIM%'
       or upcase(name) like '%DEATH%'
       or upcase(name) like '%BIRTH%'
       or upcase(name) like '%PART_D%'
       or upcase(name) like '%PARTD%'
       or upcase(name) like '%PTDB%'
    order by name;
quit;
title;

/* ── B10: Part D source file audit ──────────────────────────────────────
   Search IBOG, COH, and PD libraries for Part D prescription tables.
   PD library added because raw Part D files often read as pd.partd_1YYYY.
   If PD libname fails to assign above, those rows will be absent - check log.
   dictionary.columns may run for several minutes across large libraries.
   If it times out, add: and memname = '[confirmed PDE table name]'
   ─────────────────────────────────────────────────────────────────────*/

title "B10a: Part D datasets in IBOG, COH, and PD libraries";
proc sql;
    select libname, memname, nobs, nvar,
           crdate format=datetime20.
    from dictionary.tables
    where libname in ('IBOG','COH','PD')
      and ( upcase(memname) like '%PDE%'
         or upcase(memname) like '%PARTD%'
         or upcase(memname) like '%PART_D%'
         or upcase(memname) like '%RX%'
         or upcase(memname) like '%DRUG%'
         or upcase(memname) like '%PRSCRPTN%'
         or upcase(memname) like '%PRESC%' )
    order by libname, memname;
quit;
title;

title "B10b: Part D key fields across IBOG, COH, and PD libraries";
proc sql;
    select libname, memname, name, type, length, label
    from dictionary.columns
    where libname in ('IBOG','COH','PD')
      and ( upcase(name) like '%PROD_SRVC%'
         or upcase(name) like '%GNN%'
         or upcase(name) like '%BRND_NM%'
         or upcase(name) like '%INGRED%'
         or upcase(name) like '%NDC%'
         or upcase(name) like '%SRVC_DT%'
         or upcase(name) like '%DAYS_SUPLY%'
         or upcase(name) like '%DAYS_SUPPLY%'
         or upcase(name) like '%FILL_DT%'
         or upcase(name) like '%DSPNSNG%'
         or upcase(name) like '%PDE_ID%'
         or upcase(name) like '%CLM_ID%' )
    order by libname, memname, name;
quit;
title;

%put NOTE: B10: If dictionary.columns times out, add a table filter.;
%put NOTE: Replace the B10b query WHERE clause with:;
%put NOTE:   where libname in ('IBOG','COH','PD') and memname = '[table from B10a]';
%put NOTE: and rerun just the B10b block.;


/* ═══════════════════════════════════════════════════════════════════════════
   SECTION C: PATIENT-LEVEL TABLE
   ═══════════════════════════════════════════════════════════════════════════ */

%put NOTE: ============================================================;
%put NOTE: SECTION C: PATIENT-LEVEL TABLE (coh.ibog_07a_patientlevel);
%put NOTE: ============================================================;

title "C: Full variable list - coh.ibog_07a_patientlevel";
proc contents data=coh.ibog_07a_patientlevel varnum;
    ods select Variables;
run;
title;

title "C: Cohort group frequencies";
proc freq data=coh.ibog_07a_patientlevel;
    tables cohort_group / missing;
run;
title;


/* ═══════════════════════════════════════════════════════════════════════════
   SECTION D: CARDIAC ENDPOINT - METADATA AND SOURCE PROGRAM DISCOVERY
   No record-level cardiac outcome data printed or summarized.
   ═══════════════════════════════════════════════════════════════════════════ */

%put NOTE: ============================================================;
%put NOTE: SECTION D: CARDIAC FLAGS - METADATA AND SOURCE CODE DISCOVERY;
%put NOTE: No cardiac outcome observations are displayed.;
%put NOTE: ============================================================;

title "D1: Variable list - ibog._cardiac_outcome_flags (metadata only)";
proc contents data=ibog._cardiac_outcome_flags varnum;
    ods select Variables;
run;
title;

proc contents data=ibog._cardiac_outcome_flags
    out=_audit_cardiac noprint; run;

title "D2: Claim source, setting, and ICD-related variables";
proc sql;
    select name, type, length, label
    from _audit_cardiac
    where upcase(name) like '%CLM_TYPE%'
       or upcase(name) like '%SETTING%'
       or upcase(name) like '%INPAT%'
       or upcase(name) like '%SOURCE%'
       or upcase(name) like '%DRG%'
       or upcase(name) like '%ICD%'
       or upcase(name) like '%DGNS%'
       or upcase(name) like '%DIAG%'
       or upcase(name) like '%CLM_FROM%'
       or upcase(name) like '%FAC_TYPE%'
       or upcase(name) like '%PROV%'
    order by name;
quit;
title;

title "D3: ICD code and diagnosis position variables";
proc sql;
    select name, type, length, label
    from _audit_cardiac
    where upcase(name) like '%ICD%'
       or upcase(name) like '%DGNS%'
       or upcase(name) like '%DIAG%'
       or upcase(name) like '%PRNCPAL%'
       or upcase(name) like '%PRNCPL%'
    order by name;
quit;
title;

/* D4a: Dataset inventory via dictionary.tables */
title "D4a: All datasets in IBOG library";
proc sql;
    select memname, nobs, nvar,
           crdate format=datetime20.
    from dictionary.tables
    where libname = 'IBOG'
    order by memname;
quit;
title;

/* D4b: Source program discovery via directory read */
/* dopen/dread may fail on this server depending on UNC mount.
   If it fails, output says "ERROR: Cannot open directory" and
   the program continues. Locate the source program manually
   using the D4a dataset list as a guide.                       */
title "D4b: SAS source programs in ibogaine code directory";
data _pgm_list;
    length fname $ 256;
    rc  = filename('pgmdir', "&pgm_dir");
    did = dopen('pgmdir');
    if did = 0 then do;
        fname = "ERROR: Cannot open &pgm_dir -- locate source manually";
        output;
        stop;
    end;
    n = dnum(did);
    do i = 1 to n;
        fname = dread(did, i);
        if upcase(substr(reverse(trim(fname)),1,4)) = 'SAS.' then output;
    end;
    rc = dclose(did);
    keep fname;
run;

proc print data=_pgm_list noobs;
    title "D4b: SAS programs in &pgm_dir";
run;
title;

/* D4c: Search source programs for _cardiac_outcome_flags reference
   Reads each .sas file and checks whether it contains the string
   '_cardiac_outcome_flags'. Prints filenames of matching programs.
   Only runs if D4b successfully found files.                         */
%macro search_pgm_for_flag;
    %local nfiles found_any;
    %let found_any = 0;

    proc sql noprint;
        select count(*) into :nfiles trimmed
        from _pgm_list
        where fname not like '%ERROR%';
    quit;

    %if &nfiles = 0 %then %do;
        %put NOTE: D4c: No source programs found. Skipping source search.;
    %end;
    %else %do;
        %put NOTE: D4c: Searching &nfiles programs for _cardiac_outcome_flags...;

        data _source_hits;
            length fname $ 256 match $ 3;
            set _pgm_list (where=(fname not like '%ERROR%'));

            /* Open each .sas file and scan for the target string */
            full_path = cats("&pgm_dir", '\', trim(fname));
            rc = filename('pgmfile', full_path);
            fid = fopen('pgmfile', 'i', 32767, 'b');

            if fid <= 0 then do;
                match = 'ERR';
                output;
            end;
            else do;
                match = 'NO';
                do while (fread(fid) = 0);
                    length line $ 32767;
                    rc2 = fget(fid, line, 32767);
                    if index(upcase(line), '_CARDIAC_OUTCOME_FLAGS') > 0 then do;
                        match = 'YES';
                        leave;
                    end;
                end;
                rc3 = fclose(fid);
                if match = 'YES' then output;
            end;
            keep fname match;
        run;

        title "D4c: Source programs containing _cardiac_outcome_flags";
        proc print data=_source_hits noobs; run;
        title;
    %end;
%mend;
%search_pgm_for_flag;


/* ═══════════════════════════════════════════════════════════════════════════
   SECTION E: PRIMARY COHORT N VERIFICATION
   ═══════════════════════════════════════════════════════════════════════════ */

%put NOTE: ============================================================;
%put NOTE: SECTION E: PRIMARY COHORT N VERIFICATION;
%put NOTE: ============================================================;

/* N: let the SQL return the authoritative count - do not hardcode */
title "E: Candidate and comparator Ns - SQL output is the authoritative count";
proc sql;
    select primary_group_psych,
           count(*) as n_rows,
           count(distinct bene_id) as n_unique_bene
    from coh.ibog_fp_analysis_fp_full_v001
    where primary_group_psych in ('CANDIDATE','COMPARATOR')
    group by primary_group_psych;

    select 'TOTAL' as primary_group_psych,
           count(*) as n_rows,
           count(distinct bene_id) as n_unique_bene
    from coh.ibog_fp_analysis_fp_full_v001
    where primary_group_psych in ('CANDIDATE','COMPARATOR');
quit;
title;


/* ═══════════════════════════════════════════════════════════════════════════
   SECTION F: CARDIOVASCULAR COVARIATE AVAILABILITY
   ═══════════════════════════════════════════════════════════════════════════ */

%put NOTE: ============================================================;
%put NOTE: SECTION F: CARDIOVASCULAR COVARIATE AVAILABILITY;
%put NOTE: ============================================================;

title "F: Cardiovascular replacement covariate variables in fp table";
proc sql;
    select name, type, length, label
    from _audit_fp
    where upcase(name) like '%HF%'
       or upcase(name) like '%HEART_FAIL%'
       or upcase(name) like '%ISCHEMIC%'
       or upcase(name) like '%AMI%'
       or upcase(name) like '%CARDIOMY%'
       or upcase(name) like '%AFIB%'
       or upcase(name) like '%ATRIAL%'
       or upcase(name) like '%HYPERT%'
       or upcase(name) like '%HTN%'
       or upcase(name) like '%DIABET%'
       or upcase(name) like '%CKD%'
       or upcase(name) like '%RENAL%'
       or upcase(name) like '%LQT%'
       or upcase(name) like '%SYNCOPE%'
    order by name;
quit;
title;


/* ═══════════════════════════════════════════════════════════════════════════
   SECTION G: SUMMARY CHECKLIST
   ═══════════════════════════════════════════════════════════════════════════ */

%put NOTE: ============================================================;
%put NOTE: SECTION G: AUDIT COMPLETE;
%put NOTE: Record answers before writing ibogaine_10_v3:;
%put NOTE: ;
%put NOTE: A1.  Death variable name + stable 2016-2022:    [Section A];
%put NOTE: A2.  Buy-in variable + FFS A+B values (all yrs):[Section A];
%put NOTE: A3.  Part D coverage variable + values (all yrs):[Section A];
%put NOTE: A4.  Enrollment file row structure per year:    [Section A];
%put NOTE: A5.  Any variable name changes 2016-2022:       [Section A];
%put NOTE: B1.  Age or birth date in fp table:             [Section B];
%put NOTE: B2.  Sex variable name:                         [Section B];
%put NOTE: B3.  Race variable name:                        [Section B];
%put NOTE: B4.  PTSD/depression/anxiety flags:             [Section B];
%put NOTE: B5.  CV risk factor flags:                      [Sections B/F];
%put NOTE: B6.  MOUD type indicators:                      [Section B];
%put NOTE: B7.  Antipsychotic/QT flag:                     [Section B];
%put NOTE: B8.  Utilization counts:                        [Section B];
%put NOTE: B9.  Polypharmacy variable present:             [Section B];
%put NOTE: B10. Part D PDE table name + key fields:        [Section B10];
%put NOTE: D2.  Claim source variable for endpoint:        [Section D];
%put NOTE: D3.  ICD code variables accessible:             [Section D];
%put NOTE: D4b. Source program directory found:            [Section D4b];
%put NOTE: D4c. Program building _cardiac_outcome_flags:   [Section D4c];
%put NOTE: ;
%put NOTE: NEXT: Share full output with Scott Parrott.;
%put NOTE: Write ibogaine_10_v3 only after all answers confirmed.;
%put NOTE: ============================================================;

/* Cleanup */
proc datasets library=work nolist;
    delete _ec_2016 _ec_2017 _ec_2018 _ec_2019 _ec_2020 _ec_2021 _ec_2022
           _enroll_all_years _audit_fp _audit_cardiac
           _pgm_list _source_hits;
quit;

%put NOTE: ibogaine_audit_source_structure_v7.sas complete.;
%put NOTE: No cardiac outcome data were examined.;
