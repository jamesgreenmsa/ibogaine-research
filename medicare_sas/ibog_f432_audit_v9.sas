
options nodate nonumber ls=180 ps=max;
%let run_date = %sysfunc(today(), yymmdd10.);
%put NOTE: ibog_f432_audit_v9 - run date: &run_date.;

%let run_claim_scan = N;

            
%let scan_start = 2016;
%let scan_end   = 2022;

%macro hard_abort(msg=);
   %put ERROR: HARD GATE FAILED - &msg.;
   %abort cancel;
%mend hard_abort;

%macro run_audit;

%if %upcase(&run_claim_scan.) ne Y %then %do;
   %put NOTE: run_claim_scan=N - claims scan skipped.;
   %put NOTE: Inspect 02_build_landmark_population.sas for PTSD definition first.;
   %put NOTE: If F431-only confirmed: add Methods note and stop.;
   %put NOTE: If F432 included: set run_claim_scan=Y, confirm scan_start/scan_end.;
   %return;
%end;

%put NOTE: run_claim_scan=Y - scanning years &scan_start.-&scan_end.;

libname coh   "/path/to/your/working/directory\Working\Cohorts";
libname ibog  "/path/to/your/working/directory\Ibogaine_Extraction\Output"
              access=readonly;
libname ip_yr "/path/to/your/working/directory\Output\Inpatient yearly"
              access=readonly;
libname op_yr "/path/to/your/working/directory\Output\Outpatient yearly"
              access=readonly;
libname ca_yr "/path/to/your/working/directory\Output\Carrier yearly"
              access=readonly;


%macro assert_var(ds=, var=);
   %local dsid vnum rc;
   %let dsid=%sysfunc(open(&ds.));
   %if &dsid.=0 %then %hard_abort(msg=Cannot open &ds.);
   %let vnum=%sysfunc(varnum(&dsid.,&var.));
   %if &vnum.=0 %then %hard_abort(msg=Variable &var. not found in &ds.);
   %else %put NOTE: PREFLIGHT PASS - &ds. has &var.;
   %let rc=%sysfunc(close(&dsid.));
%mend assert_var;

/* Assert fixed fields */
%assert_var(ds=ip_yr.ip_12018, var=bene_id);
%assert_var(ds=ip_yr.ip_12018, var=clm_from_dt);
%assert_var(ds=ip_yr.ip_12018, var=prncpal_dgns_cd);
%assert_var(ds=op_yr.op_12018, var=bene_id);
%assert_var(ds=op_yr.op_12018, var=clm_from_dt);
%assert_var(ds=op_yr.op_12018, var=prncpal_dgns_cd);
%assert_var(ds=ca_yr.ca_12018, var=bene_id);
%assert_var(ds=ca_yr.ca_12018, var=clm_from_dt);
%assert_var(ds=ca_yr.ca_12018, var=prncpal_dgns_cd);

/* Confirm at least one icd_dgns_cd variable exists in each source.
   Use PROC CONTENTS with output dataset to check via wildcard.         */
%macro assert_icd_exists(ds=);
   proc contents data=&ds.(obs=0) out=_chk_icd noprint; run;
   proc sql noprint;
      select count(*) into :n_icd trimmed
      from _chk_icd
      where upcase(name) like 'ICD_DGNS_CD%'
         or upcase(name) like 'ICDdgnscd%';
   quit;
   %if &n_icd.=0 %then
      %hard_abort(msg=No ICD_DGNS_CD variables found in &ds.);
   %else %put NOTE: PREFLIGHT PASS - &ds. has &n_icd. icd_dgns_cd variables;
%mend assert_icd_exists;

%assert_icd_exists(ds=ip_yr.ip_12018);
%assert_icd_exists(ds=op_yr.op_12018);
%assert_icd_exists(ds=ca_yr.ca_12018);

/* Confirm schema stable across all scan years using representative checks */
%macro assert_years_exist(lib=, prefix=);
   %local yr;
   %do yr=&scan_start. %to &scan_end.;
      %local dsid rc;
      %let dsid=%sysfunc(open(&lib..&prefix.&yr.));
      %if &dsid.=0 %then
         %hard_abort(msg=Cannot open &lib..&prefix.&yr. - confirm scan_start/scan_end);
      %else %put NOTE: PREFLIGHT PASS - &lib..&prefix.&yr. accessible;
      %let rc=%sysfunc(close(&dsid.));
   %end;
%mend assert_years_exist;

%assert_years_exist(lib=ip_yr, prefix=ip_1);
%assert_years_exist(lib=op_yr, prefix=op_1);
%assert_years_exist(lib=ca_yr, prefix=ca_1);

/* ── Prevalence gate ─────────────────────────────────────────────────── */
proc sql noprint;
   select mean(active_allstrong_primary)*100,
          mean(active_primary)*100
   into :pct_s trimmed, :pct_c trimmed
   from coh.ibog_fp_analysis_fp_full_v001
   where primary_group_psych='CANDIDATE';
quit;
%put NOTE: Strong inhibitor among candidates = &pct_s.% (expect ~15.8%);
%put NOTE: Composite among candidates        = &pct_c.%  (expect ~29.5%);
%if %sysevalf(%sysfunc(abs(&pct_s.-15.8)) > 1.0) %then
   %hard_abort(msg=Strong inhibitor &pct_s.% deviates >1pp from 15.8%);
%if %sysevalf(%sysfunc(abs(&pct_c.-29.5)) > 1.0) %then
   %hard_abort(msg=Composite &pct_c.% deviates >1pp from 29.5%);
%put NOTE: PREVALENCE GATE PASSED;

/* ── Step 1: Pull frozen window and flags ────────────────────────────── */
proc sql;
   create table work._anchor as
   select bene_id,
          anchor_dt                      as index_dt,
          anchor_dt - 730                as window_start format=date9.,
          primary_group_psych,
          primary_comparison_flag,
          coalesce(flag_ptsd_w,       0) as flag_ptsd_w,
          coalesce(flag_depression_w,  0) as flag_depression_w,
          coalesce(flag_anxiety_w,     0) as flag_anxiety_w,
          active_allstrong_primary       as strong_inhib,
          active_primary                 as composite
   from coh.ibog_fp_analysis_fp_full_v001;
quit;



/* ── Step 1b: Original unadjusted PR as benchmark ────────────────────── */
proc genmod data=work._anchor
   (where=(primary_group_psych in ('CANDIDATE','COMPARATOR')
           and not missing(strong_inhib))) descending;
   class primary_group_psych (ref='COMPARATOR') / param=ref;
   model strong_inhib = primary_group_psych / dist=poisson link=log;
   repeated subject=bene_id / type=ind;
   estimate "Original unadjusted PR" primary_group_psych 1 / exp;
   title "Original Unadjusted PR - Benchmark for Step 7";
run;
title;

/* ── Step 2: Scan claims within frozen window ────────────────────────── */
/* Uses icd_dgns_cd: wildcard and array dx{*} to avoid naming assumption  */
%macro scan_ptsd_window(lib=, prefix=);
   %local yr;
   %do yr=&scan_start. %to &scan_end.;
      data _ptsd_&lib._&yr.;
         set &lib..&prefix.&yr.
            (keep=bene_id clm_from_dt prncpal_dgns_cd icd_dgns_cd:);

         if _n_=1 then do;
            declare hash h_win(dataset:"work._anchor");
            h_win.definekey("bene_id");
            h_win.definedata("index_dt","window_start");
            h_win.definedone();
         end;
         length index_dt window_start 8;
         format index_dt window_start date9.;
         if h_win.find() ne 0 then delete;

         if clm_from_dt < window_start or clm_from_dt > index_dt
            then delete;

         has_f431=0; has_f432=0;

         if not missing(prncpal_dgns_cd) then do;
            if substr(upcase(strip(prncpal_dgns_cd)),1,4)='F431' then has_f431=1;
            if substr(upcase(strip(prncpal_dgns_cd)),1,4)='F432' then has_f432=1;
         end;

         /* Dynamic array handles any number of icd_dgns_cd variables */
         array dx{*} $ icd_dgns_cd:;
         do i=1 to dim(dx);
            if substr(upcase(strip(dx{i})),1,4)='F431' then has_f431=1;
            if substr(upcase(strip(dx{i})),1,4)='F432' then has_f432=1;
         end;

         if has_f431=1 or has_f432=1;
         keep bene_id has_f431 has_f432;
      run;
      %put NOTE: &lib. year &yr. complete;
   %end;
%mend scan_ptsd_window;

%scan_ptsd_window(lib=ip_yr, prefix=ip_1);
%scan_ptsd_window(lib=op_yr, prefix=op_1);
%scan_ptsd_window(lib=ca_yr, prefix=ca_1);

/* ── Step 3: Collapse - uses scan_start/scan_end parameters ─────────── */
/* Build year-list dynamically so all scanned years are included         */
%macro stack_years;
   %local yr first_ds;
   %let first_ds=1;
   data _all_ptsd;
      %do yr=&scan_start. %to &scan_end.;
         set _ptsd_ip_yr_&yr.
             _ptsd_op_yr_&yr.
             _ptsd_ca_yr_&yr.;
      %end;
   run;
%mend stack_years;
%stack_years;

proc sql;
   create table work._bene_ptsd as
   select bene_id,
          max(has_f431) as flag_f431_window,
          max(has_f432) as flag_f432_window
   from _all_ptsd
   group by bene_id;
quit;

/* ── Step 4: Two-way reproduction QC - hard gate ────────────────────── */
proc sql noprint;
   select
      sum(a.flag_ptsd_w),
      sum(case
            when a.flag_ptsd_w=1
             and coalesce(b.flag_f431_window,0)=0
             and coalesce(b.flag_f432_window,0)=0
            then 1 else 0
          end),
      sum(case
            when a.flag_ptsd_w=0
             and (coalesce(b.flag_f431_window,0)=1
               or coalesce(b.flag_f432_window,0)=1)
            then 1 else 0
          end),
      sum(1-a.flag_ptsd_w)
   into :n_frozen_ptsd    trimmed,
        :n_false_neg      trimmed,
        :n_false_pos      trimmed,
        :n_frozen_no_ptsd trimmed
   from work._anchor a
   left join work._bene_ptsd b
      on a.bene_id=b.bene_id;
quit;

%let pct_fn=%sysevalf(&n_false_neg./&n_frozen_ptsd.*100);
%let pct_fp=%sysevalf(&n_false_pos./&n_frozen_no_ptsd.*100);

%put NOTE: Reproduction QC (two-way):;
%put NOTE:   Frozen PTSD=1: &n_frozen_ptsd.;
%put NOTE:   FALSE NEG (ptsd=1 no F431/F432): &n_false_neg. (&pct_fn.%);
%put NOTE:   Frozen PTSD=0: &n_frozen_no_ptsd.;
%put NOTE:   FALSE POS (ptsd=0 F431/F432 found): &n_false_pos. (&pct_fp.%);
%put NOTE:   Threshold: 0.5% each direction.;
%put NOTE:   If threshold exceeded: investigate source/window/schema before proceeding.;
%put NOTE:   DOCUMENT any deliberate change to this threshold with justification.;

%if %sysevalf(&pct_fn. > 0.5) %then
   %hard_abort(msg=False-neg rate &pct_fn.% exceeds 0.5%. Mismatch - investigate.);
%if %sysevalf(&pct_fp. > 0.5) %then
   %hard_abort(msg=False-pos rate &pct_fp.% exceeds 0.5%. Mismatch - investigate.);
%put NOTE: REPRODUCTION QC GATE PASSED - proceeding to reclassification;

/* ── Step 5: Reclassification ─────────────────────────────────────────── */
proc sql;
   create table work._reclassified as
   select a.bene_id,
          a.primary_group_psych,
          a.primary_comparison_flag,
          a.strong_inhib,
          a.composite,
          a.flag_ptsd_w,
          a.flag_depression_w,
          a.flag_anxiety_w,
          coalesce(b.flag_f431_window,0) as flag_f431_window,
          coalesce(b.flag_f432_window,0) as flag_f432_window,
          case when a.flag_ptsd_w=1
                and coalesce(b.flag_f431_window,0)=0
                and coalesce(b.flag_f432_window,0)=1
               then 1 else 0 end as ptsd_f432_only,
          /* TYPE A: candidate -> intermediate; frozen PTSD=1 required */
          case when a.primary_group_psych='CANDIDATE'
                and a.flag_ptsd_w=1
                and coalesce(b.flag_f431_window,0)=0
                and coalesce(b.flag_f432_window,0)=1
                and (a.flag_depression_w+a.flag_anxiety_w)=1
               then 1 else 0 end as reclassify_A,
          /* TYPE B: intermediate -> comparator; frozen PTSD=1 required */
          case when a.primary_group_psych='INTERMEDIATE'
                and a.flag_ptsd_w=1
                and coalesce(b.flag_f431_window,0)=0
                and coalesce(b.flag_f432_window,0)=1
                and (a.flag_depression_w+a.flag_anxiety_w)=0
               then 1 else 0 end as reclassify_B
   from work._anchor a
   left join work._bene_ptsd b on a.bene_id=b.bene_id;
quit;

/* ── Step 6: Counts ──────────────────────────────────────────────────── */
proc sql;
   title "F432 Contamination Audit - Reclassification Counts";
   select
      count(*) as n_total,
      sum(case when primary_group_psych='CANDIDATE'    then 1 else 0 end) as n_candidates,
      sum(case when primary_group_psych='COMPARATOR'   then 1 else 0 end) as n_comparators,
      sum(case when primary_group_psych='INTERMEDIATE' then 1 else 0 end) as n_intermediates,
      sum(reclassify_A) as n_type_A
         label="TYPE A: Candidates->Intermediates",
      sum(reclassify_B) as n_type_B
         label="TYPE B: Intermediates->new Comparators",
      sum(reclassify_A)/
         sum(case when primary_group_psych='CANDIDATE' then 1 else 0 end)*100
         as pct_A label="% candidates affected"
   from work._reclassified;
quit;
title;

/* ── Step 7: Corrected cohort and unadjusted PR ─────────────────────── */
proc sql;
   create table work._corrected_cohort as
   select bene_id, strong_inhib, composite,
          case when primary_group_psych='CANDIDATE' and reclassify_A=0 then 1
               when primary_group_psych='COMPARATOR'                    then 0
               when primary_group_psych='INTERMEDIATE'
                    and reclassify_B=1                                  then 0
               else . end as candidate_corrected
   from work._reclassified
   where calculated candidate_corrected is not missing;
quit;

proc sql;
   title "Corrected cohort: prevalence check";
   select candidate_corrected,
          count(*) as n,
          mean(strong_inhib)*100 as pct_strong,
          mean(composite)*100    as pct_composite
   from work._corrected_cohort
   group by candidate_corrected;
quit;
title;

proc genmod data=work._corrected_cohort
   (where=(not missing(candidate_corrected) and not missing(strong_inhib)))
   descending;
   class candidate_corrected (ref='0') / param=ref;
   model strong_inhib=candidate_corrected / dist=poisson link=log;
   repeated subject=bene_id / type=ind;
   estimate "Corrected unadjusted PR" candidate_corrected 1 / exp;
   title "F432-Corrected Unadjusted PR";
   title2 "Compare to original unadjusted PR from Step 1b";
run;
title;

%put NOTE: COMPLETE.;
%put NOTE: Report reclassification N (Type A and B), prevalence change,;
%put NOTE: and corrected vs original unadjusted PR.;
%put NOTE: If PR shifts materially by effect magnitude: rerun fully adjusted;
%put NOTE: model using ibogaine_demographic_analysis_v6 structure with;
%put NOTE: candidate_corrected substituted for the original candidate variable.;

%mend run_audit;
%run_audit;
