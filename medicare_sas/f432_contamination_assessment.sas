/******************************************************************************
PROGRAM  : f432_contamination_assessment.sas
PURPOSE  : Assess whether F432x (Adjustment Disorder) claims are driving
           flag_ptsd=1 in Lydia's staging file for benes who have no F431x
           (PTSD proper) claims anywhere in their record.

           The key output number is n_marginal_candidates: benes whose
           flag_ptsd=1 is F432-only AND who have exactly one other psych
           qualifier (depression or anxiety). These are the only benes
           whose Candidate status could change under an F431-only definition.

INPUTS   : ibog.eligible_scp_ibogaine_bene_flags  (Lydia's staging file)
           ip_yr.ip_12016 - ip_yr.ip_12022        (inpatient claims)
           op_yr.op_12016 - op_yr.op_12022        (outpatient claims)

OUTPUT   : work.f432_assessment  (printed to log)

NOTES    : PREFLIGHT runs first and confirms all three libraries resolve
           correctly before any claim scanning begins. If any library
           fails, the program stops and reports which path needs fixing.
           Run STEP 0 next to confirm ICD diagnosis variable name.
******************************************************************************/


/* ===========================================================================
   LIBRARIES
   =========================================================================== */
libname ip_yr "/path/to/your/working/directory\Output\Inpatient yearly";
libname op_yr "/path/to/your/working/directory\Output\Outpatient yearly";
libname ibog  "/path/to/your/working/directory\Ibogaine_Extraction\Output"
              access=readonly;


/* ===========================================================================
   PREFLIGHT: Confirm all three libraries resolve and contain expected files.
   Review the three contents listings before proceeding.
   If any proc contents errors, fix that library path before running further.
   =========================================================================== */
%put NOTE: ================================================;
%put NOTE: PREFLIGHT -- confirming library paths;
%put NOTE: ================================================;

proc contents data=ip_yr._all_ nods;
   title "PREFLIGHT: ip_yr library contents -- expect ip_12016 through ip_12022";
run;

proc contents data=op_yr._all_ nods;
   title "PREFLIGHT: op_yr library contents -- expect op_12016 through op_12022";
run;

proc contents data=ibog._all_ nods;
   title "PREFLIGHT: ibog library contents -- expect eligible_scp_ibogaine_bene_flags";
run;

%put NOTE: ================================================;
%put NOTE: PREFLIGHT complete. Review listings above.;
%put NOTE: If all three libraries show expected files, proceed.;
%put NOTE: If any library errored, fix the path and rerun.;
%put NOTE: ================================================;


/* ===========================================================================
   STEP 0: Confirm diagnosis variable name before running claim scans.
   Look for variables named ICD_DGNS_CD_1 through ICD_DGNS_CD_25 or similar.
   If your files use a different prefix, update the array statement in
   the %scan_claims macro below before running STEP 1 onward.
   =========================================================================== */
proc contents data=ip_yr.ip_12016 varnum;
   title "STEP 0: Variable names in ip_12016 -- confirm ICD diagnosis field name";
run;


/* ===========================================================================
   STEP 1: Scan inpatient and outpatient claims 2016-2022 for any F431x
   or F432x code in any diagnosis position. Uses a hash lookup to restrict
   processing to benes already in Lydia's staging file, which keeps this
   from scanning the full Medicare population unnecessarily.
   =========================================================================== */
%macro scan_claims(lib=, prefix=, start=2016, end=2022);
   %local yr;
   %do yr = &start. %to &end.;

      data _dx_&lib._&yr.;
         set &lib..&prefix.&yr.
            (keep=bene_id prncpal_dgns_cd icd_dgns_cd:);

         /* Hash lookup: skip benes not in the staging file */
         if _n_ = 1 then do;
            declare hash h(dataset:"ibog.eligible_scp_ibogaine_bene_flags");
            h.definekey("bene_id");
            h.definedone();
         end;
         if h.find() ne 0 then delete;

         array dx{*} $ prncpal_dgns_cd icd_dgns_cd:;
		 has_f431 = 0;
		 has_f432 = 0;
		 do i = 1 to dim(dx);
		 	if not missing(dx{i}) then do ;
				if substr(upcase(strip(dx{i})),1,4) = 'F431' then has_F431 = 1;
				if substr(upcase(strip(dx{i})),1,4) = 'F432' then has_F432 = 1;
			end;
		 end;

         if has_f431 = 1 or has_f432 = 1;
         keep bene_id has_f431 has_f432;
      run;

      %put NOTE: Completed &lib. year &yr.;

   %end;
%mend scan_claims;

%scan_claims(lib=ip_yr, prefix=ip_1, start=2016, end=2022);
%scan_claims(lib=op_yr, prefix=op_1, start=2016, end=2022);


/* ===========================================================================
   STEP 2: Stack all years and files, then collapse to one row per bene.
   =========================================================================== */
data _all_dx_hits;
   set _dx_ip_yr_2016-_dx_ip_yr_2022
       _dx_op_yr_2016-_dx_op_yr_2022;
run;

proc sql;
   create table _bene_dx_summary as
   select bene_id,
          max(has_f431) as ever_f431,
          max(has_f432) as ever_f432
   from _all_dx_hits
   group by bene_id;
quit;

%put NOTE: STEP 2 complete. Bene-level dx summary built.;


/* ===========================================================================
   STEP 3: Join to Lydia's staging file and count contamination.

   Output fields:
     n_total_benes         -- all benes in the staging file
     n_flag_ptsd_1         -- benes with flag_ptsd=1 in staging
     n_ptsd_has_f431       -- of those, how many have a real F431x claim
     n_ptsd_f432_only      -- of those, how many have F432x but NO F431x
     n_marginal_candidates -- THE KEY NUMBER: F432-only PTSD benes who
                              have exactly 1 other qualifier (depression
                              or anxiety). These are the only benes who
                              would lose Candidate status under a strict
                              F431-only definition.
   =========================================================================== */
proc sql;
   create table work.f432_assessment as
   select

      count(*)
         as n_total_benes
         label="Total benes in staging file",

      sum(b.flag_ptsd)
         as n_flag_ptsd_1
         label="flag_ptsd=1 in staging file",

      sum(case when b.flag_ptsd = 1
                and coalesce(d.ever_f431, 0) = 1
               then 1 else 0 end)
         as n_ptsd_has_f431
         label="flag_ptsd=1 with at least one F431x claim (true PTSD)",

      sum(case when b.flag_ptsd = 1
                and coalesce(d.ever_f431, 0) = 0
                and coalesce(d.ever_f432, 0) = 1
               then 1 else 0 end)
         as n_ptsd_f432_only
         label="flag_ptsd=1 driven by F432x only, no F431x found",

      sum(case when b.flag_ptsd = 1
                and coalesce(d.ever_f431, 0) = 0
                and coalesce(d.ever_f432, 0) = 1
                and (b.flag_depression + b.flag_anxiety) = 1
               then 1 else 0 end)
         as n_marginal_candidates
         label="KEY: F432-only PTSD with exactly 1 other qualifier -- would lose Candidate status under F431-only definition"

   from ibog.eligible_scp_ibogaine_bene_flags b
   left join _bene_dx_summary d on b.bene_id = d.bene_id;
quit;

proc print data=work.f432_assessment noobs label;
   title "F432 Contamination Assessment -- Ibogaine Cohort";
   title2 "Key number: n_marginal_candidates";
run;

%put NOTE: ================================================;
%put NOTE: f432_contamination_assessment.sas complete.;
%put NOTE: Send n_marginal_candidates back to James Green.;
%put NOTE: ================================================;

/* end f432_contamination_assessment.sas */

proc contents data=ip_yr.ip_12016 varnum; run;