
/* 00_libnames.sas v1.2 -- comments stripped for server compatibility (2026-08-14) */



/* -------------------------------------------------------------------------
   Set proj_root to the root of your local working directory before running.
   Example (Windows): %let proj_root = C:\Projects\Ibogaine;
   Example (Unix/Mac): %let proj_root = /data/projects/ibogaine;
   The pipeline expects subdirectories: Output, Working, Ibogaine_Extraction
   ------------------------------------------------------------------------- */
%let proj_root = /path/to/your/working/directory;
%let outp      = &proj_root\Output;
%let workp = &proj_root\Working;

libname out1  "&outp"                                             access=readonly;
libname ptdyr    "&outp\Part D yearly"                               access=readonly;
libname coh   "&workp\Cohorts";

options mprint mlogic symbolgen;

%macro require_exists(libds, label);
    %if not %sysfunc(exist(&libds.)) %then %do;
        %put ERROR: &label. (&libds.) does not exist. Aborting.;
        %abort cancel;
    %end;
    %else %put OK: &label. (&libds.) found.;
%mend require_exists;

%macro require_nonzero_rows(libds, label);
    %local dsid nobs rc;
    %let dsid = %sysfunc(open(&libds.));
    %if &dsid. = 0 %then %do;
        %put ERROR: Cannot open &libds. for row check. Aborting.;
        %abort cancel;
    %end;
    %let nobs = %sysfunc(attrn(&dsid., nobs));
    %let rc = %sysfunc(close(&dsid.));
    %if &nobs. = 0 %then %do;
        %put ERROR: &label. (&libds.) has zero rows. Aborting.;
        %abort cancel;
    %end;
    %else %put OK: &label. (&libds.) has &nobs. rows.;
%mend require_nonzero_rows;

%macro require_count(libds, wherecond, expected, label);
    %local cnt;
    proc sql noprint;
        select count(*) into :cnt trimmed
        from &libds.
        %if %length(&wherecond.) %then %do; where &wherecond.; %end;
        ;
    quit;
    %if &cnt. ne &expected. %then %do;
        %put ERROR: &label. expected &expected. but found &cnt.. Aborting.;
        %abort cancel;
    %end;
    %else %put OK: &label. matches expected count &expected..;
%mend require_count;

%macro require_var_exists(libds, varname, label);
    %local vtype;
    proc sql noprint;
        select type into :vtype trimmed
        from dictionary.columns
        where libname = %upcase(%str(%'%scan(&libds.,1,.)%'))
          and memname = %upcase(%str(%'%scan(&libds.,2,.)%'))
          and upcase(name) = %upcase("&varname.");
    quit;
    %if %length(&vtype.) = 0 %then %do;
        %put ERROR: &label. (&varname. on &libds.) does not exist.;
        %put ERROR: &varname. is a placeholder field name, not confirmed;
        %put ERROR: anywhere in this project's available code. See the;
        %put ERROR: field scan just printed above (or run one against;
        %put ERROR: &libds. directly) to find the real PTSD/depression/;
        %put ERROR: anxiety qualifier field names, edit this script to;
        %put ERROR: use them, and rerun. Aborting now, with a clear;
        %put ERROR: message, rather than letting PROC SQL fail on this;
        %put ERROR: later with a less obvious error. ;
        %abort cancel;
    %end;
    %else %put OK: &label. (&varname. on &libds.) exists (type=&vtype.).;
%mend require_var_exists;

%macro require_var_not_numeric(libds, varname, label);
    %local vtype;
    %let vtype = ;
    proc sql noprint;
        select type into :vtype trimmed
        from dictionary.columns
        where libname = %upcase(%str(%'%scan(&libds.,1,.)%'))
          and memname = %upcase(%str(%'%scan(&libds.,2,.)%'))
          and upcase(name) = %upcase("&varname.");
    quit;
    /* REVISION NOTE (v10): an eighth review pointed out that if
       &varname. does not exist on &libds. at all, the SELECT above
       matches no rows and :vtype is left blank, not 'NUM' or 'CHAR'.
       The %if below only ever tested for ='NUM', so a blank vtype
       fell through to the %else branch and printed a false "OK ...
       is not numeric" for a field that was not merely non-numeric but
       entirely MISSING. A %length check now catches that case first,
       with its own distinct abort, before the numeric-type test runs. */
    %if %length(&vtype.) = 0 %then %do;
        %put ERROR: &label. (&varname. on &libds.) was NOT FOUND at all;
        %put ERROR: on &libds. (dictionary.columns returned no match).;
        %put ERROR: This is not a type problem; the field is missing;
        %put ERROR: entirely. Confirm the table/field name and structure;
        %put ERROR: before proceeding. Aborting.;
        %abort cancel;
    %end;
    %else %if %upcase(&vtype.) = NUM %then %do;
        %put ERROR: &label. (&varname. on &libds.) was imported/stored as;
        %put ERROR: NUMERIC. Leading zeros are almost certainly already;
        %put ERROR: unrecoverable. Fix the source/import and rerun. Aborting.;
        %abort cancel;
    %end;
    %else %put OK: &label. (&varname. on &libds.) is not numeric (type=&vtype.).;
%mend require_var_not_numeric;


/* ── STEP 0: Confirm Part D PDE table, date coverage, enrollment structure ── */
%put =====================================================;
%put STEP 0: Locate Part D PDE source, check date coverage and;
%put STEP 0: enrollment-table structure;
%put =====================================================;

/* There is no single out1.pde_raw table (confirmed on Citrix): Part D
   PDE data is one table per calendar year, partd_1<yyyy>, in the
   ptdyr library. Discover the member list from dictionary.tables
   rather than hardcoding the year range, since newer years will be
   added over time.

   Which years are actually NEEDED is also derived from the data, not
   hardcoded.

   REVISION NOTE (v9): this range previously assumed STEP 3's window
   looked BACKWARD 24 months from anchor_dt (year(min(anchor_dt))-2
   through year(max(anchor_dt))). That assumption no longer holds: the
   MOUD ascertainment window is now classification_start_dt (=
   anchor_dt) through classification_end_dt (= anchor_dt + 364), a
   FORWARD-looking window confirmed directly from 02_build_landmark_
   population.sas. Leaving the old backward range in place after that
   change would have silently excluded whichever later-year PDE
   tables the corrected window actually needs -- not a crash, just
   quietly incomplete MOUD ascertainment for anyone whose window
   crosses into a year never loaded. The range now comes directly
   from classification_end_dt itself (a real field on the cohort
   table, not recomputed here), so it tracks the actual window even if
   the project's classification_days parameter ever changes: the
   earliest needed year is the earliest anchor_dt's own calendar year,
   and the latest is the latest classification_end_dt's calendar year.
   Restricting both this preflight scan and STEP 3's matching loop to
   that range, rather than every discovered yearly table regardless of
   relevance, avoids scanning years that could not affect any
   beneficiary's result, and avoids a masking risk: scanning every
   discovered table unconditionally would let an irrelevant LATER table
   (say 2023, not needed by this cohort) sit alongside a truncated
   NEEDED table (say an incomplete 2022 refresh), and the resulting
   global MAX date would reflect the irrelevant table, hiding the gap
   in the one that actually matters. */
%require_exists(coh.ibog_fp_analysis_fp_full_v001, PRIMARY cohort table)

proc sql noprint;
    select year(min(anchor_dt)), year(max(classification_end_dt))
        into :pde_needed_min_yr trimmed, :pde_needed_max_yr trimmed
    from coh.ibog_fp_analysis_fp_full_v001;
quit;
%put NOTE: Cohort classification-window range requires Part D PDE years;
%put NOTE: &pde_needed_min_yr. through &pde_needed_max_yr. (the earliest;
%put NOTE: anchor_dt's own calendar year, through the latest;
%put NOTE: classification_end_dt's calendar year).;

proc sql noprint;
    select count(*) into :n_pde_year_tables trimmed
    from dictionary.tables
    where libname = 'PTDYR' and upcase(memname) like 'PARTD_1%'
      and input(substr(memname, length(memname)-3), 4.)
          between &pde_needed_min_yr. and &pde_needed_max_yr.;
quit;
%if &n_pde_year_tables. = 0 %then %do;
    %put ERROR: No partd_1<yyyy> tables found in the ptdyr library;
    %put ERROR: (Output\Part D yearly) for the needed year range;
    %put ERROR: &pde_needed_min_yr.-&pde_needed_max_yr.. Confirm the ptdyr;
    %put ERROR: libname is assigned and points at the right folder.;
    %put ERROR: Aborting.;
    %abort cancel;
%end;

proc sql noprint;
    select catx('.', 'ptdyr', memname) into :pde_year_dslist separated by ' '
    from dictionary.tables
    where libname = 'PTDYR' and upcase(memname) like 'PARTD_1%'
      and input(substr(memname, length(memname)-3), 4.)
          between &pde_needed_min_yr. and &pde_needed_max_yr.
    order by memname;
quit;
%put NOTE: &n_pde_year_tables. Part D yearly PDE table(s) in the needed;
%put NOTE: range will be processed:;
%put NOTE: &pde_year_dslist.;

/* Hard check: every needed year must have its own table. Checking only
   that the filtered list above is non-empty would silently tolerate a
   gap in the middle of the needed range (say 2019 missing from a
   needed 2014-2022 span); this checks each needed year explicitly. */
%macro check_needed_pde_years;
    %local yr found;
    %do yr = &pde_needed_min_yr. %to &pde_needed_max_yr.;
        proc sql noprint;
            select count(*) into :found trimmed
            from dictionary.tables
            where libname = 'PTDYR' and upcase(memname) = "PARTD_1&yr.";
        quit;
        %if &found. = 0 %then %do;
            %put ERROR: Part D PDE table PARTD_1&yr. was not found in the;
            %put ERROR: ptdyr library, but the cohort's anchor_dt range;
            %put ERROR: (&pde_needed_min_yr.-&pde_needed_max_yr.) needs it.;
            %put ERROR: Aborting rather than silently running with a gap;
            %put ERROR: in needed PDE coverage.;
            %abort cancel;
        %end;
    %end;
    %put OK: All needed Part D PDE years (&pde_needed_min_yr.-&pde_needed_max_yr.);
    %put OK: have a corresponding yearly table.;
%mend check_needed_pde_years;
%check_needed_pde_years

/* Transparency note only, not an error: a discovered yearly table
   outside the needed range is simply not processed. */
proc sql noprint;
    select catx('.', 'ptdyr', memname) into :pde_skipped_dslist separated by ' '
    from dictionary.tables
    where libname = 'PTDYR' and upcase(memname) like 'PARTD_1%'
      and not (input(substr(memname, length(memname)-3), 4.)
               between &pde_needed_min_yr. and &pde_needed_max_yr.);
quit;
%if %length(&pde_skipped_dslist.) > 0 %then %do;
    %put NOTE: The following Part D yearly table(s) exist but fall;
    %put NOTE: outside the needed range and are not processed:;
    %put NOTE: &pde_skipped_dslist..;
%end;

/* Confirm field names/types on the first yearly table. The PDE
   source's NDC-equivalent field is PROD_SRVC_ID (confirmed on
   Citrix), not a field literally named NDC; all references below use
   prod_srvc_id. If a later-added yearly table has a different layout,
   this one-table check will not catch it, but STEP 3's per-year
   numeric-type check (on every yearly table, not just this one) will
   still fail loudly rather than silently. */
%let pde_first_ds = %scan(&pde_year_dslist., 1, %str( ));
proc contents data=&pde_first_ds. varnum short out=work._pde_vars noprint;
run;

proc sql;
    select name, type, length
    from work._pde_vars
    where upcase(name) like '%BENE_ID%'
       or upcase(name) like '%PROD_SRVC_ID%'
       or upcase(name) like '%SRVC_DT%'
       or upcase(name) like '%DAYS_SUPLY%'
    order by name;
quit;
%put STEP 0a complete. Confirmed BENE_ID, PROD_SRVC_ID (the NDC-;
%put equivalent field), SRVC_DT, and DAYS_SUPLY_NUM on &pde_first_ds..;

/* Earliest/latest PDE service date and total row count, reduced across
   years in the macro processor rather than by first stacking every
   yearly table into one physical copy, and now scoped to only the
   needed year range (see above) rather than every discovered table:
   each table in that range still runs well over 100GB, so a single
   UNION would be a terabyte-plus copy just to take a MIN/MAX. */
%let earliest_pde_dt =;
%let latest_pde_dt =;
%let pde_total_n = 0;

/* REVISION NOTE (v10): an eighth review pointed out that this per-year
   scan already computes each yearly table's own min/max srvc_dt (see
   the NOTE lines below), but until now that per-year information was
   used only to roll up the POOLED earliest_pde_dt/latest_pde_dt that
   STEP 3's ptd_observable_adequate actually gates on. A table that is
   truncated in the MIDDLE of the needed range (say PARTD_12020 only
   runs through June) would not be caught by the pooled range at all,
   because an intact earlier year supplies a low-enough earliest_pde_dt
   and an intact later year supplies a high-enough latest_pde_dt -- a
   beneficiary whose whole classification window sits inside the
   truncated year would still pass the pooled check even though 2020's
   own data is incomplete for them. That is exactly the masking
   scenario the review described, so each year's own table is now also
   checked against the calendar year it is supposed to cover.

   pde_year_dslist (built above) is ORDER BY memname, and
   check_needed_pde_years already aborted earlier if any year in the
   needed range were missing its own table, so the i-th entry of this
   gap-free, sorted list corresponds exactly to calendar year
   pde_needed_min_yr + i - 1; that lets the check below name the actual
   year a truncated table belongs to.

   The most recent needed year is held to a looser standard, and only
   on its END date: Medicare Part D PDE data has a real, expected
   submission/run-out lag, so the latest needed year legitimately not
   yet reaching December 31 is not by itself evidence of truncation,
   and is logged as a WARNING rather than aborted. Nothing excuses a
   late START date on any year, including the most recent one -- a
   run-out lag delays which LATE claims have arrived, it does not delay
   which EARLY claims have arrived, so a late start is treated as a
   hard error on every needed year. */
%macro scan_pde_years;
    %local i ds yr yr_min yr_max yr_n yr_start_exp yr_end_exp;
    %do i = 1 %to &n_pde_year_tables.;
        %let ds = %scan(&pde_year_dslist., &i., %str( ));
        %let yr  = %eval(&pde_needed_min_yr. + &i. - 1);
        proc sql noprint;
            select min(srvc_dt), max(srvc_dt), count(*)
                into :yr_min trimmed, :yr_max trimmed, :yr_n trimmed
            from &ds.;
        quit;
        %if %length(&earliest_pde_dt.) = 0 %then %let earliest_pde_dt = &yr_min.;
        %else %if &yr_min. < &earliest_pde_dt. %then %let earliest_pde_dt = &yr_min.;
        %if %length(&latest_pde_dt.) = 0 %then %let latest_pde_dt = &yr_max.;
        %else %if &yr_max. > &latest_pde_dt. %then %let latest_pde_dt = &yr_max.;
        /* REVISION NOTE (v11): %sysevalf(...,integer) instead of %eval,
           which is 32-bit and cannot hold a multi-billion-row pooled
           count (it would error, not wrap, and abort on a logging
           figure). */
        %let pde_total_n = %sysevalf(&pde_total_n. + &yr_n., integer);
        %put NOTE: &ds.: n=&yr_n., srvc_dt %sysfunc(putn(&yr_min.,date9.));
        %put NOTE: to %sysfunc(putn(&yr_max.,date9.));

        %let yr_start_exp = %sysfunc(mdy(1,1,&yr.));
        %let yr_end_exp   = %sysfunc(mdy(12,31,&yr.));

        %if &yr_min. > %eval(&yr_start_exp. + 3) %then %do;
            %put ERROR: ================================================;
            %put ERROR: &ds. (needed year &yr.) starts;
            %put ERROR: %sysfunc(putn(&yr_min.,date9.)), not Jan 1 &yr. as a;
            %put ERROR: complete calendar-year PDE table should. A run-out;
            %put ERROR: lag explains a late-arriving END of year, never a;
            %put ERROR: late START, so this looks like a truncated or;
            %put ERROR: partial-refresh source table, not an expected lag.;
            %put ERROR: Aborting rather than letting the pooled;
            %put ERROR: earliest_pde_dt mask this gap behind other years.;
            %put ERROR: ================================================;
            %abort cancel;
        %end;

        %if &yr. < &pde_needed_max_yr. %then %do;
            %if &yr_max. < %eval(&yr_end_exp. - 3) %then %do;
                %put ERROR: ================================================;
                %put ERROR: &ds. (needed year &yr.) ends;
                %put ERROR: %sysfunc(putn(&yr_max.,date9.)), well short of Dec;
                %put ERROR: 31 &yr.. &yr. is NOT the most recent needed year;
                %put ERROR: (&pde_needed_max_yr. is), so normal claims-runout;
                %put ERROR: lag does not excuse the gap. A beneficiary whose;
                %put ERROR: classification window sits entirely inside &yr.;
                %put ERROR: could be misclassified as PDE-observable by the;
                %put ERROR: pooled earliest_pde_dt/latest_pde_dt check alone,;
                %put ERROR: even though &yr.'s own table is incomplete.;
                %put ERROR: Aborting rather than letting an intact later year;
                %put ERROR: mask this truncated one.;
                %put ERROR: ================================================;
                %abort cancel;
            %end;
        %end;
        %else %do;
            %if &yr_max. < %eval(&yr_end_exp. - 45) %then %do;
                %put WARNING: &ds. (the most recent needed year, &yr.) ends;
                %put WARNING: %sysfunc(putn(&yr_max.,date9.)), well short of;
                %put WARNING: Dec 31 &yr.. This is the final needed year, so;
                %put WARNING: some shortfall can reflect normal Part D;
                %put WARNING: claims run-out lag rather than truncation -- but;
                %put WARNING: confirm that is actually the case, rather than a;
                %put WARNING: partial refresh, before trusting PDE-;
                %put WARNING: observability determinations near the end of;
                %put WARNING: &yr..;
            %end;
        %end;
    %end;
%mend scan_pde_years;
%scan_pde_years

%put NOTE: earliest_pde_dt = %sysfunc(putn(&earliest_pde_dt., date9.));
%put NOTE: latest_pde_dt   = %sysfunc(putn(&latest_pde_dt., date9.));
%put NOTE: pde_total_n (across needed yearly tables) = &pde_total_n.;
%put STEP 0b complete.;

/* Structural check on the Part D enrollment source. Confirmed on
   Citrix: there is no separate out1.ptd_enrollment_raw table. Part D
   monthly enrollment (PTD_CNTRCT_ID_01-12) lives directly on
   out1.enrollment_raw, the same table STEP 2 joins for sex/race, with
   no PTD_CVRG_START_DT/END_DT span fields present. This check is kept
   (rather than hardcoding enr_shape = MONTHLY) in case that changes
   on a future refresh of the table. */
%require_exists(out1.enrollment_raw, Enrollment and Part D monthly-enrollment source table)

proc contents data=out1.enrollment_raw varnum short out=work._ptd_enr_vars noprint;
run;

proc sql noprint;
    select count(*) into :n_monthly_fields trimmed
    from work._ptd_enr_vars
    where upcase(name) like 'PTD_CNTRCT_ID%';

    select count(*) into :n_span_fields trimmed
    from work._ptd_enr_vars
    where upcase(name) in ('PTD_CVRG_START_DT','PTD_CVRG_END_DT');
quit;

/* Row/beneficiary counts come from dictionary.tables metadata (NOBS),
   not a full scan of a 162,977,841-row table, purely for visibility;
   shape determination below relies on the field-presence check above,
   not on this count. */
%let n_enr_rows = 0;
proc sql noprint;
    select nobs into :n_enr_rows trimmed
    from dictionary.tables
    where libname = 'OUT1' and upcase(memname) = 'ENROLLMENT_RAW';
quit;

%put NOTE: out1.enrollment_raw has &n_monthly_fields. PTD_CNTRCT_ID_xx fields,;
%put NOTE: &n_span_fields. pre-built span fields, and &n_enr_rows. total rows;
%put NOTE: (all beneficiaries and years, not just this cohort).;

%macro set_enr_shape;
    %global enr_shape;
    %if &n_span_fields. = 2 %then %do;
        %let enr_shape = SPAN;
        %put NOTE: enr_shape = SPAN (pre-built coverage span fields present).;
    %end;
    %else %if &n_monthly_fields. >= 12 %then %do;
        %let enr_shape = MONTHLY;
        %put NOTE: enr_shape = MONTHLY (MBSF-style ptd_cntrct_id_01-12,;
        %put NOTE: must be collapsed into spans before use). Confirmed on;
        %put NOTE: Citrix as the actual shape of out1.enrollment_raw.;
    %end;
    %else %do;
        %put ERROR: Could not determine the Part D enrollment structure;
        %put ERROR: on out1.enrollment_raw. Neither a clean span shape;
        %put ERROR: nor an MBSF monthly shape was detected. Resolve;
        %put ERROR: manually before proceeding.;
        %abort cancel;
    %end;
%mend set_enr_shape;
%set_enr_shape


/* ── STEP 1: Load validated, historically complete MOUD NDC list ── */
%put =====================================================;
%put STEP 1: Load buprenorphine (OUD-indicated) and naltrexone NDC list;
%put =====================================================;

/* DO NOT populate this with hand-typed NDCs, and do NOT pull only a
   current (2025-2026) measurement-year value set; build a historically
   complete crosswalk spanning back to at least the earliest possible
   index year (2016, per enr_first_year in the ground-truth 00_
   ibogaine_setup.sas). REVISION NOTE (v9): the previous "back to 2014"
   guidance assumed a 24-month backward lookback from anchor_dt; the
   actual MOUD window is classification_start_dt (= anchor_dt) through
   classification_end_dt (= anchor_dt + 364), so there is no need to
   cover years before the earliest anchor_dt itself. A broader
   crosswalk is still harmless, just not required. See the analytic
   plan for the full product scope (buprenorphine OUD-indicated
   formulations included, pain-indicated ones excluded; naltrexone
   included; methadone excluded entirely).

   Required columns: ndc_cd (as supplied, must stay CHARACTER through
   import so leading zeros survive), product_class ('BUP_OUD' or
   'NTX'), product_name (brand/generic label for QC). */

/*
proc import datafile="&path.\moud_ndc_reference_historical.csv"
    out=work._moud_ndc_raw
    dbms=csv replace;
    getnames=yes;
    guessingrows=max;   * prevents numeric auto-type from stripping leading zeros *;
run;
*/

%require_exists(work._moud_ndc_raw, Imported MOUD NDC reference list)
%require_var_not_numeric(work._moud_ndc_raw, ndc_cd, MOUD NDC reference ndc_cd field)

data work._moud_ndc work._moud_ndc_rejected;
    set work._moud_ndc_raw;
    length ndc_norm $11;
    ndc_norm = compress(ndc_cd, , 'kd');
    if lengthn(ndc_norm) = 11 then output work._moud_ndc;
    else output work._moud_ndc_rejected;
run;

proc sql noprint;
    select count(*) into :n_rejected trimmed from work._moud_ndc_rejected;
quit;
%if &n_rejected. > 0 %then %do;
    %put ERROR: &n_rejected. NDC(s) in the reference list are not 11;
    %put ERROR: digits and were excluded rather than padded. This is a;
    %put ERROR: small curated reference list, not raw claims data, so a;
    %put ERROR: rejected entry here is far more likely an import problem;
    %put ERROR: (for example Excel stripping a leading zero) than;
    %put ERROR: expected noise. Review work._moud_ndc_rejected, fix the;
    %put ERROR: source list, and rerun rather than silently dropping;
    %put ERROR: rows from a curated list. Aborting.;
    %abort cancel;
%end;

/* Conflict check: the same NDC must not appear under more than one
   product_class. PROC SORT NODUPKEY would otherwise silently keep an
   arbitrary row and discard the conflicting classification. */
proc sql;
    create table work._ndc_conflicts as
    select ndc_norm, count(distinct product_class) as n_classes
    from work._moud_ndc
    group by ndc_norm
    having calculated n_classes > 1;
quit;

proc sql noprint;
    select count(*) into :n_conflicts trimmed from work._ndc_conflicts;
quit;
%if &n_conflicts. > 0 %then %do;
    %put ERROR: &n_conflicts. NDC(s) are classified under more than one;
    %put ERROR: product_class in the reference list. Aborting; resolve;
    %put ERROR: the conflicts (see work._ndc_conflicts) before rerunning.;
    %abort cancel;
%end;

proc sort data=work._moud_ndc nodupkey;
    by ndc_norm;
run;

%require_nonzero_rows(work._moud_ndc, MOUD NDC reference list)

%macro check_class_counts;
    proc sql noprint;
        select count(*) into :n_bup trimmed from work._moud_ndc where product_class = 'BUP_OUD';
        select count(*) into :n_ntx trimmed from work._moud_ndc where product_class = 'NTX';
    quit;
    %put NOTE: n_bup = &n_bup., n_ntx = &n_ntx.;
    %if &n_bup. = 0 %then %do;
        %put ERROR: Zero BUP_OUD NDCs loaded. Aborting.;
        %abort cancel;
    %end;
    %if &n_ntx. = 0 %then %do;
        %put ERROR: Zero NTX NDCs loaded. Aborting.;
        %abort cancel;
    %end;
%mend check_class_counts;
%check_class_counts
%put STEP 1 complete.;


/* ── STEP 2: Build the full-population demographic/outcome table ── */
%put =====================================================;
%put STEP 2: Build work._bene_demog_full directly from the full source,;
%put STEP 2: replacing the undocumented work._bene_demog_age dependency,;
%put STEP 2: and lock-check it against the published manuscript counts;
%put =====================================================;

%require_exists(coh.ibog_fp_analysis_fp_full_v001, PRIMARY cohort table)
%require_exists(out1.enrollment_raw, Enrollment/demographic source table)
%require_exists(out1.bene_birthdate, Beneficiary birth-date source table)

/* Sex and race still come from the year-specific join to
   out1.enrollment_raw, mirroring etable2_medicare_penetrance_v2.sas:
   coh.ibog_fp_analysis_fp_full_v001 (a) LEFT JOIN out1.enrollment_raw
   (b) on bene_id and the enrollment reference year matching the
   anchor (index) year. sex_ident_cd and rti_race_cd are carried
   through unchanged here; the categorical mapping happens in STEP 4
   (sex_cat, race_eth). PROC CONTENTS on out1.enrollment_raw (Citrix,
   2026-10-06) confirmed both are CHARACTER fields ($1), matching
   medicare_ffs_poisson.sas's own convention of quoting them as
   strings, not etable2_medicare_penetrance_v2.sas's unquoted numeric
   comparisons; STEP 4 compares them against quoted literals ('1',
   '2', etc.) accordingly, which also avoids the automatic character-
   numeric conversion an unquoted comparison would otherwise trigger.

   Age is NOT sourced from that same join. enrollment_raw's own
   bene_birth_dt is tied to the year-specific match that this project
   already knows fails for a documented 79,466 beneficiaries (missing
   sex/RTI race); using it for age would silently listwise-delete the
   same beneficiaries from the Poisson model, since age_years is
   continuous and has no Missing category the way sex_cat/race_eth do.
   Instead, age comes from out1.bene_birthdate, a separate, dedicated
   birth-date source this project already uses for this same analysis
   in ibog_demog_stratified_pr_v3.sas, joined on bene_id alone (not
   year-specific) and deduplicated the same way that script does.

   Formula: floor((anchor_dt - bene_birth_dt)/365.25), matching the
   formula documented in ibogaine_demographic_analysis_v6.sas (which
   independently made this exact same enrollment_raw-to-bene_birthdate
   switch, for the identical 79,466-unmatched reason, and recorded the
   formula explicitly in its own change log). year(anchor_dt) -
   year(bene_birth_dt), used in v5, can be off by a year in either
   direction depending where the beneficiary's birthday falls relative
   to the index date; floor() of the exact day count does not have
   that problem. */
proc sort data=out1.bene_birthdate(keep=bene_id bene_birth_dt)
          out=work._bene_birthdate_dedup;
    by bene_id descending bene_birth_dt;
run;

proc sort data=work._bene_birthdate_dedup nodupkey;
    by bene_id;
run;

proc sql;
    create table work._bene_demog_full as
    select
        a.bene_id,
        a.anchor_dt,
        a.classification_start_dt,
        a.classification_end_dt,
        a.index_dt,
        a.primary_group_psych,
        a.active_primary,
        a.active_bupropion,
        a.active_paroxetine,
        a.active_fluoxetine,
        b.sex_ident_cd,
        b.rti_race_cd,
        f.bene_birth_dt,
        case when missing(f.bene_birth_dt) then .
             else floor((a.anchor_dt - f.bene_birth_dt)/365.25)
        end                                                 as age_years
    from coh.ibog_fp_analysis_fp_full_v001 a
    left join out1.enrollment_raw b
        on a.bene_id = b.bene_id
        and b.bene_enrollmt_ref_yr = year(a.anchor_dt)
    left join work._bene_birthdate_dedup f
        on a.bene_id = f.bene_id;
quit;

%require_nonzero_rows(work._bene_demog_full, Full-population demographic table)
%require_count(work._bene_demog_full, %str(), 842366,
    Full Medicare FFS demographic table row count)
%require_count(work._bene_demog_full, %str(bene_id is not missing), 842366,
    Full Medicare FFS demographic table non-missing bene_id count)

/* REVISION NOTE (v10): an eighth review suggested carrying index_dt as
   an audit field and asserting its relationship to classification_
   end_dt/anchor_dt, even though nothing downstream recomputes it --
   this script never needed to derive index_dt itself, since CYP2D6
   exposure (active_primary etc.) was already evaluated AT index_dt by
   the upstream 03_define_cyp2d6_exposure.sas program. Pulling the real
   index_dt field (confirmed present on coh.ibog_fp_analysis_fp_full_
   v001 by the PROC CONTENTS screenshot) above and asserting here that
   it equals BOTH classification_end_dt + 1 and anchor_dt + 365, with a
   zero-mismatch hard gate, turns the entire anchor_dt/classification_
   start_dt/classification_end_dt/index_dt hierarchy this revision
   history has debated across several rounds into something a later
   reviewer can confirm directly from the log, rather than re-deriving
   it from 02_build_landmark_population.sas again. A mismatch here
   would mean either this script's own understanding of that hierarchy
   is wrong, or the cohort table's index_dt no longer means what it did
   when that hierarchy was confirmed -- either way, something that must
   stop the run, not a cosmetic check. */
%require_count(work._bene_demog_full,
    %str(index_dt ne classification_end_dt + 1 or index_dt ne anchor_dt + 365
         or classification_start_dt ne anchor_dt),
    0,
    date audit: classification_start_dt = anchor_dt and index_dt = classification_end_dt + 1 = anchor_dt + 365 for every row)

/* REVISION NOTE (v10): an eighth review pointed out that the plan's
   naltrexone-inclusion rationale (that naltrexone is defensible
   because everyone in the source cohort already has documented OUD)
   is only as solid as the frozen cohort's own first_oud_dx_dt field,
   and asked for a one-line provenance check, explicitly NOT a reason
   to reopen the phenotype: if the count of frozen-cohort beneficiaries
   with a missing first_oud_dx_dt is 0, the rationale is empirically
   confirmed; if it is greater than 0, the review's own guidance is to
   soften that rationale and lean more on the buprenorphine-only
   sensitivity (STEP 6), not to treat this as a defect to fix here.
   Reported as a WARNING, not a hard gate, for exactly that reason. */
proc sql noprint;
    select count(*) into :n_missing_first_oud_dx trimmed
    from coh.ibog_fp_analysis_fp_full_v001
    where missing(first_oud_dx_dt);
quit;
%if &n_missing_first_oud_dx. = 0 %then %do;
    %put OK: Naltrexone preflight -- all 842,366 frozen-cohort beneficiaries;
    %put OK: have a non-missing first_oud_dx_dt. The plan's rationale that;
    %put OK: naltrexone is defensible because everyone in the source;
    %put OK: cohort already has documented OUD is confirmed, not merely;
    %put OK: assumed.;
%end;
%else %do;
    %put WARNING: Naltrexone preflight -- &n_missing_first_oud_dx. of;
    %put WARNING: 842,366 frozen-cohort beneficiaries have a MISSING;
    %put WARNING: first_oud_dx_dt (their anchor_dt was set by;
    %put WARNING: first_moud_fill_dt alone, per anchor_type). The plan's;
    %put WARNING: rationale that naltrexone is defensible because everyone;
    %put WARNING: already has documented OUD does not hold without;
    %put WARNING: qualification for these beneficiaries. Not treated as a;
    %put WARNING: hard failure here -- consider softening that rationale in;
    %put WARNING: the plan and leaning more on the buprenorphine-only;
    %put WARNING: sensitivity (STEP 6) for them.;
%end;

proc sql noprint;
    select count(distinct bene_id) into :n_distinct_full trimmed
    from work._bene_demog_full;
quit;
%if &n_distinct_full. ne 842366 %then %do;
    %put ERROR: work._bene_demog_full has 842366 rows but only;
    %put ERROR: &n_distinct_full. distinct bene_id values. There are;
    %put ERROR: duplicate beneficiary rows, likely from the enrollment;
    %put ERROR: join matching more than one year per beneficiary.;
    %put ERROR: Resolve before proceeding. Aborting.;
    %abort cancel;
%end;
%put OK: &n_distinct_full. distinct beneficiaries confirmed.;

/* Group breakdown gate: the source table's own primary_group_psych
   field must reproduce the published manuscript breakdown exactly. */
proc sql noprint;
    select count(*) into :n_cand trimmed
        from work._bene_demog_full where primary_group_psych = 'CANDIDATE';
    select count(*) into :n_comp trimmed
        from work._bene_demog_full where primary_group_psych = 'COMPARATOR';
    select count(*) into :n_int trimmed
        from work._bene_demog_full where primary_group_psych = 'INTERMEDIATE';
quit;
%put NOTE: primary_group_psych breakdown: CANDIDATE=&n_cand., COMPARATOR=&n_comp.,;
%put NOTE: INTERMEDIATE=&n_int..;
%if &n_cand. ne 307336 or &n_comp. ne 283434 or &n_int. ne 251596 %then %do;
    %put ERROR: primary_group_psych breakdown does not match the;
    %put ERROR: published manuscript figures (307336 / 283434 / 251596).;
    %put ERROR: Aborting; investigate before proceeding.;
    %abort cancel;
%end;
%put OK: primary_group_psych breakdown matches the published figures.;

/* Locked Tier 1 strong-inhibitor outcome gate: reproduces the
   manuscript's own reported counts before any MOUD augmentation.

   REVISION NOTE (v9): strong_inhib now pulls active_primary directly
   from coh.ibog_fp_analysis_fp_full_v001 instead of re-deriving it as
   an OR of active_bupropion/active_paroxetine/active_fluoxetine. The
   ground-truth build script (03_define_cyp2d6_exposure.sas, fp_v006,
   received 2026-10-06 along with 00/01/02/04 and the 99a/99b/99c
   drivers) confirms active_primary IS exactly that three-drug
   definition, active at index_dt (= anchor_dt + 365) by drug name,
   independent of cyp2d6_tier coding. Pulling it directly fixes a real
   bug in the OR reconstruction: SAS evaluates a missing numeric
   compared to 1 (e.g. "active_bupropion = 1" when active_bupropion is
   .) as FALSE, not missing. 03_exposure deliberately sets
   active_bupropion/paroxetine/fluoxetine to missing, not 0, whenever
   active_primary itself is unknown (UNKNOWN_NO_PARTD or
   UNKNOWN_DAYS_SUPPLY). The OR reconstruction silently turned every
   one of those genuinely-unknown beneficiaries into strong_inhib = 0
   ("confirmed not exposed") instead of leaving them missing and
   excluded from the modified-Poisson denominator, which is what
   active_primary does correctly on its own.

   strong_inhib_orlogic keeps the OLD (OR-based) definition purely so
   the locked gate below can report both counts if they disagree --
   this script has no way to confirm from here which definition the
   published 56212/13693 figures were actually generated with, so a
   mismatch is surfaced with full context rather than silently
   resolved either way. */
data work._bene_demog_full;
    set work._bene_demog_full;
    strong_inhib         = active_primary;
    strong_inhib_orlogic  = (active_bupropion = 1
                              or active_paroxetine = 1
                              or active_fluoxetine = 1);
run;

proc sql noprint;
    select count(*) into :n_inhib_cand trimmed
        from work._bene_demog_full
        where primary_group_psych = 'CANDIDATE' and strong_inhib = 1;
    select count(*) into :n_inhib_comp trimmed
        from work._bene_demog_full
        where primary_group_psych = 'COMPARATOR' and strong_inhib = 1;
    select count(*) into :n_inhib_cand_or trimmed
        from work._bene_demog_full
        where primary_group_psych = 'CANDIDATE' and strong_inhib_orlogic = 1;
    select count(*) into :n_inhib_comp_or trimmed
        from work._bene_demog_full
        where primary_group_psych = 'COMPARATOR' and strong_inhib_orlogic = 1;
quit;
%put NOTE: Tier 1 strong-inhibitor counts (active_primary): candidates=&n_inhib_cand.,;
%put NOTE: comparators=&n_inhib_comp..;
%put NOTE: Tier 1 strong-inhibitor counts (old OR-logic, diagnostic only):;
%put NOTE: candidates=&n_inhib_cand_or., comparators=&n_inhib_comp_or..;
%if &n_inhib_cand. ne 56212 or &n_inhib_comp. ne 13693 %then %do;
    %put ERROR: Tier 1 strong-inhibitor counts (active_primary) do not;
    %put ERROR: reproduce the published manuscript values (56212;
    %put ERROR: candidates, 13693 comparators, i.e. 18.3%% and 4.8%%).;
    %put ERROR: Found &n_inhib_cand. and &n_inhib_comp..;
    %if &n_inhib_cand_or. = 56212 and &n_inhib_comp_or. = 13693 %then %do;
        %put ERROR: The OLD OR-logic count DOES match 56212/13693. This;
        %put ERROR: means the published manuscript figures may have been;
        %put ERROR: generated with the OR-logic's missing-to-0 behavior;
        %put ERROR: rather than active_primary's correct missing-value;
        %put ERROR: handling. Confirm with the manuscript analysis code;
        %put ERROR: which definition was actually used before deciding;
        %put ERROR: whether to keep strong_inhib = active_primary or;
        %put ERROR: revert to the OR-logic definition. Aborting rather;
        %put ERROR: than silently picking one.;
    %end;
    %else %do;
        %put ERROR: The OLD OR-logic count ALSO does not match;
        %put ERROR: 56212/13693 (found &n_inhib_cand_or./&n_inhib_comp_or.).;
        %put ERROR: Neither definition reproduces the published figures;
        %put ERROR: -- something else has changed. Investigate before;
        %put ERROR: proceeding.;
    %end;
    %abort cancel;
%end;
%put OK: Tier 1 strong-inhibitor counts (active_primary) match the;
%put OK: published manuscript values. (The OR-logic diagnostic above;
%put OK: should also read 56212/13693 in that case; if it does not,;
%put OK: that is expected now that the missing-value bug is fixed, and;
%put OK: is not itself a problem.);

/* Age-availability gate: age_years is continuous in the Poisson
   models below and has no Missing category, unlike sex_cat/race_eth.
   Any modeled beneficiary with missing age_years would be silently
   listwise-deleted by PROC GENMOD, contradicting the validated
   model's own intent to retain beneficiaries rather than drop them
   over incomplete demographics. This is checked against the FULL
   842,366-row population, not just the original CANDIDATE/COMPARATOR
   split: STEP 4's PRIMARY_V2 phenotype can promote an originally-
   INTERMEDIATE beneficiary (exactly 1 psychiatric domain) into the
   STEP 5/STEP 6 model population via MOUD, so scoping this check to
   the original classification alone would miss exactly the
   beneficiaries this sensitivity analysis exists to reclassify. */
proc sql noprint;
    select count(*) into :n_age_missing trimmed
    from work._bene_demog_full
    where missing(age_years);
quit;
%put NOTE: &n_age_missing. of 842366 beneficiaries have missing age_years.;
%if &n_age_missing. > 0 %then %do;
    %put ERROR: age_years is missing for &n_age_missing. of 842366;
    %put ERROR: beneficiaries after joining out1.bene_birthdate.;
    %put ERROR: age_years is continuous with no Missing category, so;
    %put ERROR: PROC GENMOD would silently drop any of these who end;
    %put ERROR: up in a model population (STEP 5, 5b, or 6) rather than;
    %put ERROR: retain them the way sex_cat/race_eth do. This is;
    %put ERROR: checked against the full population, not just the;
    %put ERROR: original CANDIDATE/COMPARATOR split, because STEP 4 can;
    %put ERROR: promote an INTERMEDIATE beneficiary into the model;
    %put ERROR: population via MOUD. Confirm out1.bene_birthdate;
    %put ERROR: coverage for these beneficiaries (and the dedup logic);
    %put ERROR: above) before proceeding, or decide explicitly how to;
    %put ERROR: handle them. Aborting.;
    %abort cancel;
%end;
%else %put OK: age_years is non-missing for all 842366 beneficiaries.;
%put STEP 2 complete.;


/* ── STEP 2b: Self-validate the guessed psychiatric-domain flags ── */
%put =====================================================;
%put STEP 2b: Reconstruct the original group from individual domain flags;
%put STEP 2b: and cross-check against the authoritative primary_group_psych;
%put =====================================================;

/* REVISION NOTE (v9): flag_ptsd_w / flag_depression_w / flag_anxiety_w
   are now CONFIRMED field names, not guesses. 02_build_landmark_
   population.sas (fp_v006, received 2026-10-06) builds exactly these
   three fields in its STEP 6 (plus flag_tbi_w, which exists but is
   not one of the three summed into n_qualifiers_psych / primary_
   group_psych), and a PROC CONTENTS screenshot of coh.ibog_fp_
   analysis_fp_full_v001 confirms all four are present on the actual
   table. The previous guesses (ptsd_flag, depression_flag,
   anxiety_flag) are replaced below. The scan-and-require-exists
   safety net is kept anyway: it costs nothing, and it still protects
   against a future rebuild of the cohort table under a different
   run_id/version_tag using different field names. */
proc contents data=coh.ibog_fp_analysis_fp_full_v001
    varnum short out=work._cohort_vars noprint;
run;

proc sql;
    select name, type, length
    from work._cohort_vars
    where upcase(name) like '%PTSD%'
       or upcase(name) like '%DEPRESS%'
       or upcase(name) like '%ANXI%'
       or upcase(name) like '%TBI%'
       or upcase(name) like '%MOUD%'
       or upcase(name) like '%PSYCH%'
       or upcase(name) like '%QUAL%'
    order by name;
quit;
%put NOTE: Above is the field-name scan of coh.ibog_fp_analysis_fp_full_v001.;
%put NOTE: If flag_ptsd_w/flag_depression_w/flag_anxiety_w below do not match;
%put NOTE: real names in that list, fix the field names in this block;
%put NOTE: before rerunning.;

%require_var_exists(coh.ibog_fp_analysis_fp_full_v001, flag_ptsd_w, Psychiatric-domain qualifier flag)
%require_var_exists(coh.ibog_fp_analysis_fp_full_v001, flag_depression_w, Psychiatric-domain qualifier flag)
%require_var_exists(coh.ibog_fp_analysis_fp_full_v001, flag_anxiety_w, Psychiatric-domain qualifier flag)

proc sql;
    create table work._qual_check as
    select
        a.bene_id,
        a.primary_group_psych,
        (a.flag_ptsd_w + a.flag_depression_w + a.flag_anxiety_w)
                                                           as n_qual_psych,
        case
            when calculated n_qual_psych >= 2 then 'CANDIDATE'
            when calculated n_qual_psych = 0 then 'COMPARATOR'
            else 'INTERMEDIATE'
        end                                                as reconstructed_group
    from coh.ibog_fp_analysis_fp_full_v001 a;
quit;

proc sql noprint;
    select count(*) into :n_mismatch trimmed
    from work._qual_check
    where reconstructed_group ne primary_group_psych;
quit;
%if &n_mismatch. > 0 %then %do;
    %put ERROR: &n_mismatch. beneficiaries have a domain-count-;
    %put ERROR: reconstructed group that does NOT match the authoritative;
    %put ERROR: primary_group_psych field. flag_ptsd_w/flag_depression_w/;
    %put ERROR: flag_anxiety_w are confirmed field names (02_build_;
    %put ERROR: landmark_population.sas STEP 6), so a mismatch here more;
    %put ERROR: likely means the >=2/=0/exactly-1 reconstruction logic,;
    %put ERROR: or the table itself, has changed since that confirmation.;
    %put ERROR: Investigate before proceeding. Do not continue to MOUD;
    %put ERROR: augmentation on unvalidated flags. Aborting.;
    %abort cancel;
%end;
%put OK: Reconstructed psychiatric-domain group matches primary_group_psych;
%put OK: for all 842366 beneficiaries using the confirmed flag_ptsd_w/;
%put OK: flag_depression_w/flag_anxiety_w fields. Proceeding to add MOUD;
%put OK: as a fourth domain on top of them.;
%put STEP 2b complete.;


/* ── STEP 3: Part D coverage spans, observability, and MOUD flag ── */
%put =====================================================;
%put STEP 3: Build Part D coverage spans, compute observability, and;
%put STEP 3: flag MOUD within each beneficiary's own observable window;
%put =====================================================;

%macro build_ptd_spans;
    %if &enr_shape. = SPAN %then %do;
        data work._ptd_spans;
            set out1.enrollment_raw;
            keep bene_id ptd_cvrg_start_dt ptd_cvrg_end_dt;
        run;
    %end;
    %else %if &enr_shape. = MONTHLY %then %do;
        /* Filter to just the 842,366 beneficiaries in scope, and to
           just the enrollment years each beneficiary could actually
           need, before expanding to one row per beneficiary per month.
           out1.enrollment_raw has 162,977,841 rows across all
           beneficiaries and years, not just this cohort or the years
           the MOUD classification window can use; reading it
           unfiltered into a monthly expansion would multiply that by
           12 for no reason, and would also pull enrollment years no
           beneficiary's window ever reaches.

           REVISION NOTE (v9): the MOUD ascertainment window is now
           classification_start_dt through classification_end_dt
           (pulled directly from coh.ibog_fp_analysis_fp_full_v001 in
           STEP 2), not a 24-month lookback ending at anchor_dt.
           02_build_landmark_population.sas (fp_v006) sets
           classification_start_dt = anchor_dt and classification_
           end_dt = anchor_dt + 364, a forward-looking window, so the
           year range needed is year(anchor_dt) through year(
           classification_end_dt) -- at most one calendar year past
           anchor_dt's own year, never before it. Keying the upper
           bound off classification_end_dt directly (rather than a
           hardcoded +1 year) keeps this correct even if the project's
           classification_days parameter (currently 365, set in
           00_ibogaine_setup.sas) ever changes. */
        proc sql;
            create table work._ptd_enr_raw as
            select e.bene_id, e.bene_enrollmt_ref_yr,
                   e.ptd_cntrct_id_01, e.ptd_cntrct_id_02, e.ptd_cntrct_id_03,
                   e.ptd_cntrct_id_04, e.ptd_cntrct_id_05, e.ptd_cntrct_id_06,
                   e.ptd_cntrct_id_07, e.ptd_cntrct_id_08, e.ptd_cntrct_id_09,
                   e.ptd_cntrct_id_10, e.ptd_cntrct_id_11, e.ptd_cntrct_id_12
            from out1.enrollment_raw e
            inner join work._bene_demog_full d
                on e.bene_id = d.bene_id
               and e.bene_enrollmt_ref_yr between year(d.anchor_dt)
                                               and year(d.classification_end_dt);
        quit;

        /* Build the raw monthly expansion FIRST, before the
           confirmation gate below, so that if the gate stops the
           program, work._ptd_monthly_long already exists and the
           analyst has something concrete to spot-check. (v4 built
           this table only after the gate, so its own error message
           pointed at a table that did not exist yet.) The raw
           cntrct_id value is kept, not just a has_ptd flag, so the
           PROC FREQ just below can show the real distinct values. */
        data work._ptd_monthly_long;
            set work._ptd_enr_raw;
            array c[12] ptd_cntrct_id_01-ptd_cntrct_id_12;
            do mm = 1 to 12;
                cntrct_id = c[mm];
                month_dt = mdy(mm, 1, bene_enrollmt_ref_yr);
                output;
            end;
            keep bene_id month_dt cntrct_id;
        run;

        proc sort data=work._ptd_monthly_long; by bene_id month_dt; run;

        /* PTD_CNTRCT_ID_xx is a 5-character field (confirmed on
           Citrix), not the 1-character field an earlier version of
           this script assumed, so a bare '0' sentinel could not have
           been the right "not enrolled" test. Print the distinct
           values actually present, pooled across all months and this
           cohort, as a standing audit trail every run. */
        proc freq data=work._ptd_monthly_long;
            tables cntrct_id / missing;
        run;

        /* has_ptd rule: the first character of PTD_CNTRCT_ID_xx is a
           documented CMS/ResDAC convention (ResDAC "Monthly Part D
           Contract Number" and "Plan Contract ID" variable
           documentation, confirmed directly against resdac.org,
           2026-10-06), not a project-specific guess:
             E = employer direct plan
             H = managed care organization other than regional PPO
                 (local MA-PD, 1876 cost plan, PACE, PFFS, or
                 demonstration organization)
             R = regional PPO
             S = stand-alone prescription drug plan (PDP)
             X = Limited Income Newly Eligible Transition (LI NET) plan
             N = not Part D enrolled
             0 = not Medicare enrolled that month
             blank = enrolled in Medicare A and/or B, no Part D
                     enrollment data
           E/H/R/S/X all denote an active Part D contract of some kind.
           H explicitly includes MA-PD and PACE arrangements, but for
           the question this flag answers, whether the beneficiary's
           Part D dispensing was observable that month, those count the
           same as a stand-alone PDP: Part D PDE claims should exist
           for that month under any of the five active contract types
           if MOUD was dispensed. This resolves the business-rule
           question v7 left open pending manual Citrix confirmation: it
           is a documented CMS convention, not something to spot-check
           beneficiary by beneficiary, so it is encoded directly. */
        data work._ptd_monthly_long;
            set work._ptd_monthly_long;
            length cntrct_first_char $1;
            cntrct_first_char = substr(strip(cntrct_id), 1, 1);
            has_ptd = (cntrct_first_char in ('E','H','R','S','X'));
        run;

        /* Self-validating in place of a manual confirmation gate: abort
           if any non-blank PTD_CNTRCT_ID_xx value has a first character
           outside the documented ResDAC set. That would mean either a
           field layout different from what Citrix confirmed, or a
           data-quality problem, either way worth stopping for rather
           than silently applying the rule above to a value it was not
           built to classify. */
        proc sql noprint;
            select count(*) into :n_unexpected_cntrct trimmed
            from work._ptd_monthly_long
            where not missing(cntrct_id)
              and cntrct_first_char not in ('E','H','R','S','X','N','0');
        quit;
        %if &n_unexpected_cntrct. > 0 %then %do;
            %put ERROR: &n_unexpected_cntrct. work._ptd_monthly_long;
            %put ERROR: row(s) have a PTD_CNTRCT_ID_xx value whose first;
            %put ERROR: character is outside the documented CMS/ResDAC;
            %put ERROR: set (E/H/R/S/X = Part D contract, N = not Part D;
            %put ERROR: enrolled, 0 = not Medicare enrolled, blank = no;
            %put ERROR: Part D data). Review the PROC FREQ output above;
            %put ERROR: for the actual unexpected value(s) before;
            %put ERROR: proceeding. Aborting.;
            %abort cancel;
        %end;
        %put OK: All non-blank PTD_CNTRCT_ID_xx values match the;
        %put OK: documented CMS/ResDAC first-character set. has_ptd = 1;
        %put OK: when the first character is E, H, R, S, or X (any Part D;
        %put OK: contract type, MA-PD and PACE included); 0 otherwise.;

        /* Island-grouping collapse: tag each consecutive run of
           covered months with its own island_id. A new island starts
           whenever the current month is covered and either the prior
           row was not covered, OR the prior row is not literally the
           immediately preceding calendar month. That second condition
           matters because the DO loop above only outputs rows for
           years actually present in out1.enrollment_raw for this
           beneficiary: a beneficiary missing an entire enrollment year
           (e.g. no 2019 row at all) would otherwise have December 2018
           sort directly next to January 2020, and a naive "was the
           previous row covered" check would wrongly bridge that
           13-month gap into one continuous span. */
        data work._ptd_islands;
            set work._ptd_monthly_long;
            by bene_id;
            retain island_id prev_has_ptd prev_month_dt;
            format prev_month_dt date9.;
            if first.bene_id then do;
                island_id = 0;
                prev_has_ptd = 0;
                prev_month_dt = .;
            end;
            if has_ptd and (prev_has_ptd ne 1
                            or missing(prev_month_dt)
                            or intck('month', prev_month_dt, month_dt) ne 1)
                then island_id + 1;
            prev_has_ptd = has_ptd;
            prev_month_dt = month_dt;
            keep bene_id month_dt has_ptd island_id;
        run;

        /* Fixed off-by-one: shift 0 (same month), not 1, so the span
           end lands on the last day of the LAST COVERED month itself,
           not the month after it. */
        proc sql;
            create table work._ptd_spans as
            select
                bene_id,
                min(month_dt) as ptd_cvrg_start_dt format=date9.,
                intnx('month', max(month_dt), 0, 'e')
                                 as ptd_cvrg_end_dt format=date9.
            from work._ptd_islands
            where has_ptd = 1
            group by bene_id, island_id;
        quit;
        %put NOTE: MONTHLY collapse ran via island grouping with the;
        %put NOTE: off-by-one fix applied (shift 0, not 1) and the;
        %put NOTE: calendar-gap fix applied (a missing enrollment year;
        %put NOTE: starts a new island rather than bridging the gap).;
    %end;
%mend build_ptd_spans;
%build_ptd_spans

%require_nonzero_rows(work._ptd_spans, Collapsed Part D coverage spans)

/* Observable window per beneficiary.

   REVISION NOTE (v9): the window is now classification_start_dt
   through classification_end_dt (pulled directly from coh.ibog_fp_
   analysis_fp_full_v001 in STEP 2) instead of a self-derived 24-month
   lookback ending at anchor_dt. 02_build_landmark_population.sas
   (fp_v006, received 2026-10-06) computes classification_start_dt =
   anchor_dt and classification_end_dt = anchor_dt + 364 (a 365-day
   window STARTING at anchor_dt, not ending at it) and uses exactly
   this window to build flag_ptsd_w/flag_depression_w/flag_anxiety_w/
   flag_tbi_w and its own MOUD flag (flag_moud_w_pd, moud_status).
   This script's independent MOUD pull now ascertains over the same
   window, so its result is directly comparable to moud_status on the
   cohort table rather than answering a differently-scoped question.

   has_covering_span now means a single Part D coverage span fully
   contains [classification_start_dt, classification_end_dt] -- since
   work._ptd_spans collapses consecutive covered months into gap-free
   islands, a span whose own start/end bracket both window endpoints
   is equivalent to every month in between also being covered. This
   mirrors 02_build STEP 7's moud_fully_observable (full month-by-
   month coverage required), replacing the prior "at least 12 months
   of whatever coverage exists" threshold, which was a looser, home-
   grown proxy for the same idea. lookback_start_dt/lookback_end_dt
   keep their names (build_moud_claims below still reads them) but
   are now simply classification_start_dt/classification_end_dt
   themselves when covered, not a MAX()-clipped partial window. */
proc sql;
    create table work._ptd_observable as
    select
        d.bene_id,
        d.classification_start_dt format=date9.,
        d.classification_end_dt   format=date9.,
        (e.ptd_cvrg_start_dt is not missing)                as has_covering_span,
        case when calculated has_covering_span = 1
             then d.classification_start_dt
             else .
        end                                                as lookback_start_dt format=date9.,
        case when calculated has_covering_span = 1
             then d.classification_end_dt
             else .
        end                                                as lookback_end_dt format=date9.,
        case when calculated has_covering_span = 1
             then intck('month', d.classification_start_dt,
                                  d.classification_end_dt) + 1
             else .
        end                                                as observable_months,
        /* REVISION NOTE (v10): renamed from index_year. This is the
           calendar year of classification_start_dt (= anchor_dt), not
           of index_dt -- given how much confusion "index" caused
           across this revision history, a name that could be misread
           as "the year of index_dt" is worse than no name at all. */
        year(d.classification_start_dt)             as classification_start_year
    from work._bene_demog_full d
    left join work._ptd_spans e
        on d.bene_id = e.bene_id
        and e.ptd_cvrg_start_dt <= d.classification_start_dt
        and (e.ptd_cvrg_end_dt >= d.classification_end_dt or missing(e.ptd_cvrg_end_dt));
quit;

/* PDE-extract-range adequacy, kept as a requirement distinct from
   Part D enrollment coverage above: a beneficiary whose classification
   window extends past the latest available PDE service date (or
   starts before the earliest one) cannot have a trustworthy MOUD-
   negative result, since "no claim found" may just mean "the PDE
   extract does not reach that far". 02_build's own moud_fully_
   observable has no equivalent check, because it works from Lydia's
   pre-staged pharmacy flags rather than this script's own direct PDE
   pull; this script keeps the check since it is specific to reading
   the raw PDE tables itself. */
data work._ptd_observable;
    set work._ptd_observable;
    ptd_observable_adequate = (has_covering_span = 1
                                and classification_start_dt >= &earliest_pde_dt.
                                and classification_end_dt   <= &latest_pde_dt.);
run;

%require_count(work._ptd_observable, %str(), 842366,
    Part D observability table total row count)

proc sql noprint;
    select count(distinct bene_id) into :n_distinct_observable trimmed
    from work._ptd_observable;
quit;
%if &n_distinct_observable. ne 842366 %then %do;
    %put ERROR: work._ptd_observable has 842366 rows but only;
    %put ERROR: &n_distinct_observable. distinct bene_id values. The;
    %put ERROR: Part D span join likely matched more than one span to;
    %put ERROR: some beneficiaries. Resolve before proceeding. Aborting.;
    %abort cancel;
%end;
%put OK: work._ptd_observable has exactly 842366 rows and 842366 distinct;
%put OK: beneficiaries; the Part D span join did not duplicate anyone.;

proc freq data=work._ptd_observable;
    tables has_covering_span observable_months ptd_observable_adequate;
run;

proc freq data=work._ptd_observable;
    tables classification_start_year * ptd_observable_adequate / norow nocol;
run;
/* REVISION NOTE (v10): this message previously still said "fewer than
   12 observable months" and "index date" -- both described the pre-
   v9 design (a 24-month backward lookback graded by a month count,
   checked against anchor_dt). v9 replaced that with a single-span-
   coverage test against the classification_start_dt/classification_
   end_dt window, so the message is rewritten to describe what
   actually drives ptd_observable_adequate now. */
%put STEP 3a complete. A beneficiary without a single Part D coverage;
%put span fully containing classification_start_dt through;
%put classification_end_dt (has_covering_span=0), or whose;
%put classification window falls outside the PDE extract's own;
%put earliest_pde_dt/latest_pde_dt range, has MOUD status "not;
%put ascertainable", not "MOUD-negative", and is excluded from the;
%put analysis groups below.;

/* Reported separately for visibility even though it is now enforced
   above, not merely warned about: how many beneficiaries were excluded
   specifically for falling beyond the right edge of PDE availability.

   REVISION NOTE (v9): this previously checked anchor_dt >
   latest_pde_dt, which was correct when the window ended AT anchor_dt.
   The window's far edge is now classification_end_dt (= anchor_dt +
   364), which is always later than anchor_dt itself, so checking
   anchor_dt here would under-count: a beneficiary whose anchor_dt is
   within the PDE extract's range but whose classification_end_dt is
   not would have been missed entirely, and the OK message below would
   have been falsely reassuring for them. */
proc sql noprint;
    select count(*) into :n_beyond_pde trimmed
    from work._bene_demog_full
    where classification_end_dt > &latest_pde_dt.;
quit;
%if &n_beyond_pde. > 0 %then %do;
    %put NOTE: &n_beyond_pde. beneficiaries have a classification_end_dt;
    %put NOTE: after the latest available PDE service date;
    %put NOTE: (%sysfunc(putn(&latest_pde_dt.,date9.))). These are now;
    %put NOTE: excluded via ptd_observable_adequate=0 rather than risk;
    %put NOTE: returning a false MOUD-negative for them.;
%end;
%else %put OK: All classification windows fall within available PDE data coverage.;

/* Confirm prod_srvc_id (the PDE source's NDC-equivalent field, see
   STEP 0) is not numeric, on EVERY yearly table, not just one
   representative table: CCW field definitions can drift year to year,
   and this is a metadata-only check (dictionary.columns), not a data
   scan, so checking all of them costs nothing extra. */
%macro check_pde_prod_srvc_id_types;
    %local i ds;
    %do i = 1 %to &n_pde_year_tables.;
        %let ds = %scan(&pde_year_dslist., &i., %str( ));
        %require_var_not_numeric(&ds., prod_srvc_id, PDE source prod_srvc_id/NDC field on &ds.)
    %end;
%mend check_pde_prod_srvc_id_types;
%check_pde_prod_srvc_id_types

/* Normalize prod_srvc_id and match against the curated MOUD NDC list
   and each beneficiary's own observable window, one Part D yearly
   table at a time, appending only the (far smaller) MOUD-relevant
   matches to work._moud_claims. An earlier design normalized every row
   of each yearly table into work._pde_norm_yr/work._pde_rejected_yr
   BEFORE joining to the cohort and the MOUD NDC list; for a 100+GB
   national yearly file, that meant writing a narrowed but still
   essentially complete copy of a year's Part D claims to WORK before
   ever checking whether a claim belonged to one of this study's
   842,366 beneficiaries or matched one of a few dozen curated MOUD
   NDCs. This version uses two in-memory hash objects, the curated MOUD
   NDC list and the covering-span rows of work._ptd_observable, both
   small enough to hold in memory, to do the NDC match and the cohort/
   window membership test inline, in the same single pass that reads
   each yearly table, and writes only the rows that pass both tests.
   Total-scanned and rejected-NDC-format counts are accumulated as
   running totals in that same pass rather than via a separate count(*)
   scan of the same table. */
%if %sysfunc(exist(work._moud_claims)) %then %do;
    proc datasets lib=work nolist; delete _moud_claims; quit;
%end;
%let n_pde_total = 0;
%let n_pde_rejected = 0;

%macro build_moud_claims;
    %local i ds n_this_total n_this_rejected;
    %do i = 1 %to &n_pde_year_tables.;
        %let ds = %scan(&pde_year_dslist., &i., %str( ));
        %put NOTE: STEP 3 MOUD matching, Part D yearly table &i. of;
        %put NOTE: &n_pde_year_tables.: &ds..;

        data work._moud_claims_yr(keep=bene_id srvc_dt product_class);
            length ndc_norm $11;
            if _n_ = 1 then do;
                /* REVISION NOTE (v10): an eighth review flagged that
                   DEFINEDATA's variable names must already exist in the
                   PDV before DEFINEDONE, citing SAS Global Forum paper
                   271-2007, which demonstrates this error occurring even
                   when DATASET: is used. A separate SAS knowledge-base
                   note (24547) suggested the opposite for a variable
                   already present in the DATASET: source, and this
                   script cannot be run here to settle which behavior
                   actually applies on Citrix's SAS version. Since the
                   fix is free, it is applied regardless: product_class
                   and lookback_start_dt/lookback_end_dt are pulled into
                   the PDV, with their exact source attributes, via
                   "if 0 then set" before the hash declarations below. */
                if 0 then set work._moud_ndc(keep=product_class);
                if 0 then set work._ptd_observable(keep=lookback_start_dt lookback_end_dt);

                declare hash hn(dataset: 'work._moud_ndc');
                hn.defineKey('ndc_norm');
                hn.defineData('product_class');
                hn.defineDone();

                declare hash ho(dataset: 'work._ptd_observable(where=(has_covering_span=1))');
                ho.defineKey('bene_id');
                ho.defineData('lookback_start_dt', 'lookback_end_dt');
                ho.defineDone();
            end;

            set &ds.(keep=bene_id srvc_dt prod_srvc_id) end=_eof;

            n_this_total + 1;

            ndc_norm = compress(prod_srvc_id, , 'kd');
            if lengthn(ndc_norm) ne 11 then n_this_rejected + 1;

            /* Totals are finalized here, before any of the filters
               below can exit this iteration early via RETURN, so the
               last row read always gets counted whether or not it
               ultimately matches. */
            if _eof then do;
                call symputx('n_this_total', put(n_this_total, best12.), 'L');
                call symputx('n_this_rejected', put(n_this_rejected, best12.), 'L');
            end;

            if lengthn(ndc_norm) ne 11 then return;      /* malformed prod_srvc_id */
            if hn.find() ne 0 then return;                /* not a MOUD NDC */
            if ho.find() ne 0 then return;                /* not cohort, or no covering span */
            if srvc_dt < lookback_start_dt
                or srvc_dt > lookback_end_dt then return; /* outside observable window */

            output;
        run;

        /* v11: large-count-safe accumulators (see STEP 0 note). */
        %let n_pde_total = %sysevalf(&n_pde_total. + &n_this_total., integer);
        %let n_pde_rejected = %sysevalf(&n_pde_rejected. + &n_this_rejected., integer);

        proc append base=work._moud_claims data=work._moud_claims_yr force;
        run;

        proc datasets lib=work nolist;
            delete _moud_claims_yr;
        quit;
    %end;
%mend build_moud_claims;
%build_moud_claims

%require_nonzero_rows(work._moud_claims, MOUD-matched PDE claims (pooled across all yearly tables))

%if %sysevalf(&n_pde_rejected. > 0) %then %do;
    %let pde_rejected_pct = %sysfunc(round(100 * &n_pde_rejected. / &n_pde_total., 0.1));
    %put WARNING: &n_pde_rejected. of &n_pde_total. PDE record(s), pooled;
    %put WARNING: across all &n_pde_year_tables. yearly tables,;
    %put WARNING: (&pde_rejected_pct.%%) had a prod_srvc_id that was not;
    %put WARNING: 11 digits after stripping non-digit characters and were;
    %put WARNING: excluded from MOUD matching. Expected to be small, not;
    %put WARNING: necessarily zero, in most real PDE extracts. Unlike the;
    %put WARNING: curated reference list, this remains a warning, not an;
    %put WARNING: abort, given the volume of raw claims data involved.;
%end;
%put NOTE: &n_pde_total. total PDE records scanned across;
%put NOTE: &n_pde_year_tables. yearly tables.;

proc sql;
    create table work._moud_flag as
    select distinct
        bene_id,
        1 as moud_partd_flag,
        max(case when product_class = 'BUP_OUD' then 1 else 0 end) as moud_bup_flag,
        max(case when product_class = 'NTX'     then 1 else 0 end) as moud_ntx_flag
    from work._moud_claims
    group by bene_id;
quit;

proc sql;
    create table work._bene_demog_moud as
    select
        d.*,
        o.has_covering_span,
        o.observable_months,
        o.ptd_observable_adequate,
        case when o.ptd_observable_adequate = 1
             then coalesce(m.moud_partd_flag, 0)
             else .                                       end as moud_partd_flag,
        case when o.ptd_observable_adequate = 1
             then coalesce(m.moud_bup_flag, 0)
             else .                                       end as moud_bup_flag,
        case when o.ptd_observable_adequate = 1
             then coalesce(m.moud_ntx_flag, 0)
             else .                                       end as moud_ntx_flag
    from work._bene_demog_full d
    left join work._ptd_observable o on d.bene_id = o.bene_id
    left join work._moud_flag m      on d.bene_id = m.bene_id;
quit;

%require_count(work._bene_demog_moud, %str(), 842366,
    Demographic+MOUD table total row count)

proc sql noprint;
    select count(distinct bene_id) into :n_distinct_moud trimmed
    from work._bene_demog_moud;
quit;
%if &n_distinct_moud. ne 842366 %then %do;
    %put ERROR: work._bene_demog_moud has 842366 rows but only;
    %put ERROR: &n_distinct_moud. distinct bene_id values. Resolve;
    %put ERROR: before proceeding. Aborting.;
    %abort cancel;
%end;
%put OK: work._bene_demog_moud has exactly 842366 rows and 842366;
%put OK: distinct beneficiaries.;

proc freq data=work._bene_demog_moud;
    tables moud_partd_flag moud_bup_flag moud_ntx_flag / missing;
run;
%put STEP 3 complete.;


/* ── STEP 4: Build the validated 3-way PRIMARY_V2 phenotype ──── */
%put =====================================================;
%put STEP 4: Build analysis_group_v2 on the VALIDATED domain-count logic,;
%put STEP 4: with a post-join full-population check before observability;
%put STEP 4: exclusions are applied;
%put =====================================================;

proc sql;
    create table work._poisson_primary_v2 as
    select
        d.bene_id,
        d.strong_inhib,
        d.primary_group_psych,

        (q.n_qual_psych)                                   as n_qual_psych,

        case when d.moud_partd_flag = . then .
             else q.n_qual_psych + d.moud_partd_flag
        end                                                as n_qual_primary_v2,

        case
            when calculated n_qual_primary_v2 = . then .
            when calculated n_qual_primary_v2 >= 2 then 1
            when calculated n_qual_primary_v2 = 0 then 0
            else .
        end                                                as analysis_group_v2,

        d.age_years,

        /* sex_ident_cd/rti_race_cd are CHARACTER fields on
           out1.enrollment_raw (confirmed via PROC CONTENTS on Citrix,
           2026-10-06); compared here against quoted string literals,
           not unquoted numbers, matching medicare_ffs_poisson.sas's
           own convention and avoiding automatic character-numeric
           conversion. */
        case when d.sex_ident_cd = '1' then 'Male'
             when d.sex_ident_cd = '2' then 'Female'
             else 'Missing'                               end as sex_cat,

        case
            when d.rti_race_cd = '1' then 'NH_White'
            when d.rti_race_cd = '2' then 'NH_Black'
            when d.rti_race_cd = '5' then 'Hispanic'
            when d.rti_race_cd = '4' then 'NH_Asian'
            when d.rti_race_cd in ('3','6') then 'Other'
            else 'Missing'
        end                                                as race_eth,

        d.moud_partd_flag,
        d.moud_bup_flag,
        d.moud_ntx_flag,
        d.ptd_observable_adequate

    from work._bene_demog_moud d
    inner join work._qual_check q
        on d.bene_id = q.bene_id;
quit;

%require_nonzero_rows(work._poisson_primary_v2, PRIMARY_V2 analytic table)

/* Post-join full-population check, BEFORE observability exclusions.
   This is the check that actually catches a silent intermediate-
   dropping join, which a check on the source table alone cannot.
   Checks both the row count and the distinct count: distinct count
   alone would still pass if the join duplicated rows for some
   beneficiaries while touching all 842,366 distinct IDs. */
%require_count(work._poisson_primary_v2, %str(), 842366,
    PRIMARY_V2 analytic table total row count)

proc sql noprint;
    select count(distinct bene_id) into :n_distinct_v2 trimmed
    from work._poisson_primary_v2;
quit;
%if &n_distinct_v2. ne 842366 %then %do;
    %put ERROR: work._poisson_primary_v2 has only &n_distinct_v2.;
    %put ERROR: distinct beneficiaries after the joins, not 842366. The;
    %put ERROR: full population, intermediates included, did not survive;
    %put ERROR: the build. Investigate the join keys before proceeding.;
    %put ERROR: Aborting.;
    %abort cancel;
%end;
%put OK: &n_distinct_v2. distinct beneficiaries confirmed post-join,;
%put OK: 842366 total rows confirmed (no duplication), before any Part D;
%put OK: observability exclusions. The full population including;
%put OK: intermediates survived the build.;

proc freq data=work._poisson_primary_v2;
    tables analysis_group_v2 n_qual_primary_v2 sex_cat race_eth / missing;
run;
%put STEP 4 complete. analysis_group_v2 should show three outcomes: 0;
%put (comparator), 1 (candidate), missing (intermediate or MOUD-;
%put unascertainable, both excluded from the models below).;


/* ── STEP 4a: Gold-standard reproduction gate ──────────────── */
%put =====================================================;
%put STEP 4a: Reproduction gate -- rerun the ORIGINAL candidate-vs-;
%put comparator definition (primary_group_psych, N=590,770) with the;
%put new age/sex/race sources, and confirm it still reproduces the;
%put locked, previously published PR 3.51 (95%% CI 3.44, 3.59). This;
%put gates the new age/sex/race sources themselves, independent of;
%put the PRIMARY_V2 phenotype logic built in STEP 4 above. If this;
%put does not reproduce, stop here -- do not interpret PRIMARY_V2.;
%put =====================================================;

data work._poisson_original_repro;
    set work._poisson_primary_v2;
    where primary_group_psych in ('CANDIDATE','COMPARATOR');
    orig_group_full = (primary_group_psych = 'CANDIDATE');
run;

%require_count(work._poisson_original_repro, %str(), 590770,
    Gold-standard reproduction population, original CANDIDATE plus COMPARATOR (N=590,770))

ods output GEEEmpPEst = work._repro_gee;
proc genmod data=work._poisson_original_repro descending;
    /* REVISION NOTE (v11): bene_id added to CLASS in all four GENMOD
       models. SAS's REPEATED statement documentation states variables
       used in the SUBJECT= effect must be listed in the CLASS
       statement. */
    class race_eth (ref='NH_White') sex_cat (ref='Female')
          orig_group_full (ref='0') bene_id / param=ref;
    model strong_inhib = orig_group_full age_years sex_cat race_eth
        / dist=poisson link=log;
    repeated subject=bene_id / type=ind;
    estimate 'PR original definition, full N=590,770 reproduction' orig_group_full 1 / exp;
    title "STEP 4a -- Reproduction gate, original definition, new age/sex/race sources";
run;
title;

proc sql noprint;
    select exp(Estimate), exp(LowerCL), exp(UpperCL)
        into :repro_pr trimmed, :repro_lcl trimmed, :repro_ucl trimmed
    from work._repro_gee
    where upcase(strip(Parm)) = 'ORIG_GROUP_FULL';
quit;

%put STEP 4a: reproduced PR = &repro_pr. (95%% CI &repro_lcl., &repro_ucl.);
%put STEP 4a: locked target  = PR 3.51 (95%% CI 3.44, 3.59);

%if &repro_pr. < 3.0 or &repro_pr. > 4.0 %then %do;
    %put ERROR: STEP 4a reproduction PR &repro_pr. is outside the [3.0, 4.0];
    %put ERROR: sanity band around the locked PR 3.51. The new age/sex/race;
    %put ERROR: sources materially changed the result, not merely refined;
    %put ERROR: it. Do NOT proceed to interpret PRIMARY_V2 (STEP 5 onward).;
    %put ERROR: Investigate the age/sex/race joins before going further.;
    %put ERROR: Aborting.;
    %abort cancel;
%end;
%else %if &repro_pr. < 3.44 or &repro_pr. > 3.59 %then %do;
    %put WARNING: STEP 4a reproduction PR &repro_pr. falls outside the locked;
    %put WARNING: 95%% CI (3.44, 3.59) but inside the [3.0, 4.0] sanity band.;
    %put WARNING: Some movement is expected, since the new age/sex/race;
    %put WARNING: sources are not identical to the original ones, but;
    %put WARNING: confirm the gap is attributable to that and not a join;
    %put WARNING: error before treating PRIMARY_V2 results as final.;
%end;
%else %do;
    %put OK: STEP 4a reproduction PR &repro_pr. falls inside the locked;
    %put OK: 95%% CI (3.44, 3.59). The new age/sex/race sources reproduce;
    %put OK: the previously published result. Safe to proceed and;
    %put OK: interpret PRIMARY_V2 below.;
%end;

%put STEP 4a complete.;


/* ── STEP 4b: Reclassification QC ──────────────────────────── */
%put =====================================================;
%put STEP 4b: Reclassification QC, how MOUD moves beneficiaries between groups;
%put =====================================================;

proc sql;
    create table work._reclass_qc as
    select
        case when primary_group_psych = 'CANDIDATE' then 1
             when primary_group_psych = 'COMPARATOR' then 0
             else . end                                   as orig_group,
        analysis_group_v2,
        moud_bup_flag,
        moud_ntx_flag,
        count(*) as n
    from work._poisson_primary_v2
    group by orig_group, analysis_group_v2, moud_bup_flag, moud_ntx_flag;
quit;

proc print data=work._reclass_qc;
run;
%put STEP 4b complete. orig_group=0 moving to analysis_group_v2=. means;
%put a comparator was reclassified to intermediate by MOUD;;
%put orig_group=. moving to analysis_group_v2=1 means a 1-psych-domain;
%put intermediate became a candidate via MOUD. Report both counts;
%put alongside the PR, not the PR alone.;


/* ── STEP 5: Modified Poisson, PRIMARY_V2 vs. restricted-sample original ── */
%put =====================================================;
%put STEP 5: Modified Poisson regression, PRIMARY_V2 candidate vs comparator;
%put =====================================================;

proc genmod data=work._poisson_primary_v2 descending;
    where analysis_group_v2 in (0,1);
    class race_eth (ref='NH_White') sex_cat (ref='Female')
          analysis_group_v2 (ref='0') bene_id / param=ref;
    model strong_inhib = analysis_group_v2 age_years sex_cat race_eth
        / dist=poisson link=log;
    repeated subject=bene_id / type=ind;
    estimate 'PR candidate_v2 vs comparator' analysis_group_v2 1 / exp;
run;

%put STEP 5 complete.;

/* STEP 5b: original psychiatric-only model restricted to the SAME
   Part D-observable sample, for an apples-to-apples comparison against
   the full-cohort PR 3.51. */
%put =====================================================;
%put STEP 5b: Original psych-only model, restricted to PTD-observable sample;
%put =====================================================;

data work._poisson_orig_restricted;
    set work._poisson_primary_v2;
    where ptd_observable_adequate = 1 and primary_group_psych ne 'INTERMEDIATE';
    orig_group = (primary_group_psych = 'CANDIDATE');
run;

proc genmod data=work._poisson_orig_restricted descending;
    class race_eth (ref='NH_White') sex_cat (ref='Female')
          orig_group (ref='0') bene_id / param=ref;
    model strong_inhib = orig_group age_years sex_cat race_eth
        / dist=poisson link=log;
    repeated subject=bene_id / type=ind;
    estimate 'PR original definition, PTD-observable subsample' orig_group 1 / exp;
run;

%put STEP 5b complete. Compare against the full-cohort PR 3.51 (95%% CI;
%put 3.44, 3.59) and the PRIMARY_V2 PR from STEP 5.;


/* ── STEP 6: Buprenorphine-only sensitivity (drops naltrexone) ──── */
%put =====================================================;
%put STEP 6: Buprenorphine-only MOUD sensitivity (bounds naltrexone's;
%put OUD-vs-AUD ambiguity);
%put =====================================================;

data work._poisson_bup_only;
    set work._poisson_primary_v2;
    if moud_partd_flag = . then n_qual_bup_only = .;
    else n_qual_bup_only = n_qual_psych + moud_bup_flag;

    if n_qual_bup_only = . then analysis_group_bup = .;
    else if n_qual_bup_only >= 2 then analysis_group_bup = 1;
    else if n_qual_bup_only = 0 then analysis_group_bup = 0;
    else analysis_group_bup = .;
run;

proc genmod data=work._poisson_bup_only descending;
    where analysis_group_bup in (0,1);
    class race_eth (ref='NH_White') sex_cat (ref='Female')
          analysis_group_bup (ref='0') bene_id / param=ref;
    model strong_inhib = analysis_group_bup age_years sex_cat race_eth
        / dist=poisson link=log;
    repeated subject=bene_id / type=ind;
    estimate 'PR buprenorphine-only MOUD vs comparator' analysis_group_bup 1 / exp;
run;

%put =====================================================;
%put STEP 6 complete. Compare against the buprenorphine+naltrexone;
%put PRIMARY_V2 PR from STEP 5. A large gap means naltrexone's OUD/AUD;
%put ambiguity is materially affecting the result.;
%put =====================================================;

%put =====================================================;
%put ALL STEPS COMPLETE. Do not report the STEP 5 PR alone. Report it;
%put alongside: STEP 0 PDE date-coverage and enrollment-structure;
%put checks, STEP 2 locked population/group/outcome QC gates, STEP 2b;
%put flag self-validation result, STEP 3 observable-depth distribution;
%put (pooled and by classification_start_year) and the right-edge;
%put PDE-coverage check,;
%put STEP 4 post-join population check, STEP 4a reproduction-gate result;
%put against the locked PR 3.51, STEP 4b reclassification counts, STEP 5b;
%put restricted-sample original PR, and STEP 6 buprenorphine-only PR.;
%put Bring all of this back before deciding;
%put whether this becomes a manuscript sensitivity analysis or a;
%put standalone letter to the editor.;
%put =====================================================;
