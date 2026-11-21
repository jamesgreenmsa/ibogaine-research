/******************************************************************************
PROGRAM  : 99b_run_branch_test.sas
******************************************************************************/


%let ibog_code_root = /path/to/your/working/directory\Ibogaine_Extraction\j_code;

%global run_id test_mode test_sample_n;
%let run_id = fp_test_v001;
%let test_mode = Y;
%let test_sample_n = 500;


%let audit_approved = Y;

%macro run_99b;

   %put NOTE: ================================================;
   %put NOTE: DRIVER 2/3: Branch-coverage test (not a completeness guarantee).;
   %put NOTE: run_id=&run_id.;
   %put NOTE: ================================================;

   /* Phase 1 only */
   %include "&ibog_code_root.\00_ibogaine_setup.sas";

   %if %upcase(&audit_approved.) ne Y %then %do;
      %ibog_stop(Set audit_approved=Y at the top of this driver only after manually reviewing the 99a audit log - AUDIT_DONE alone does not confirm human review of sentinel values - pharmacy scope - or supply-day rules.);
   %end;

   /* ITEM 3 FIX */
   %local _audit_status _audit_version _audit_class_days _audit_index_offset
          _audit_max_supply _audit_drugs _audit_first_yr _audit_last_yr;

   %if not %sysfunc(exist(res.ibog_run_manifest_audit_v001)) %then %do;
      %ibog_stop(Prerequisite audit manifest res.ibog_run_manifest_audit_v001 not found - run 99a_run_staging_audit.sas first.);
   %end;
   proc sql noprint;
      select run_status, program_version, classification_days, index_offset,
             max_days_supply, target_drug_list, enr_first_year, enr_last_year
      into :_audit_status trimmed, :_audit_version trimmed,
           :_audit_class_days trimmed, :_audit_index_offset trimmed,
           :_audit_max_supply trimmed, :_audit_drugs trimmed,
           :_audit_first_yr trimmed, :_audit_last_yr trimmed
      from res.ibog_run_manifest_audit_v001;
   quit;

   %if %upcase(&_audit_status.) ne AUDIT_DONE %then %do;
      %ibog_stop(Prerequisite audit run_status is &_audit_status. - expected AUDIT_DONE - review and rerun 99a before continuing.);
   %end;
   %if %upcase(&_audit_version.) ne %upcase(&program_version.) %then %do;
      %ibog_stop(Prerequisite audit used program_version=&_audit_version. but current code is &program_version. - rerun 99a with the current code package before continuing.);
   %end;
   %if &_audit_class_days. ne &classification_days. or &_audit_index_offset. ne &index_offset.
       or &_audit_max_supply. ne &max_days_supply. or %superq(_audit_drugs) ne %superq(target_drug_list)
       or &_audit_first_yr. ne &enr_first_year. or &_audit_last_yr. ne &enr_last_year. %then %do;
      %ibog_stop(Prerequisite audit was run with different scientific parameters than the current code - rerun 99a before continuing.);
   %end;
   %put NOTE: Prerequisite audit confirmed AUDIT_DONE, matching program_version, and matching parameters.;

   /* Only NOW, after all gates pass, initialize this runs manifest */
   %initialize_ibog_run;

   %include "&ibog_code_root.\01_validate_lydia_staging.sas";
   %include "&ibog_code_root.\02_build_landmark_population.sas";
   %include "&ibog_code_root.\03_define_cyp2d6_exposure.sas";
   %include "&ibog_code_root.\04_first_pass_results.sas";

   /* ------------------------------------------------------------------
      BRANCH COVERAGE ASSERTIONS.
      ------------------------------------------------------------------ */
   %local n_eligible_check n_active_classifiable;

   %global branch_coverage_failed;
   %let branch_coverage_failed = 0;

   %put NOTE: ================================================;
   %put NOTE: Checking minimal sanity conditions (true hard stops)...;
   %put NOTE: ================================================;

   /* Hard stop 1: at least one eligible beneficiary */
   proc sql noprint;
      select count(*) into :n_eligible_check trimmed from &t_base.;
   quit;
   %if &n_eligible_check. = 0 %then %do;
      %put ERROR: ZERO eligible beneficiaries in &t_base. - test sample produced nothing to analyze.;
      %let branch_coverage_failed = 1;
   %end;
   %else %put NOTE: OK -- &n_eligible_check. eligible beneficiaries.;

   /* Hard stop 2: 1:1 output integrity re-check */
   %assert_unique(&t_base.)
   %assert_unique(&t_exposure.)

   /* ITEM 4 FIX: check active_primary (missing for unclassifiable
      beneficiaries) */
   proc sql noprint;
      select count(active_primary) into :n_active_classifiable trimmed
      from &t_exposure.;
   quit;
   %if &n_active_classifiable. = 0 %then %do;
      %put ERROR: NO beneficiary has classifiable active-at-index exposure;
      %put ERROR: (active_primary is missing for everyone) - exposure;
      %put ERROR: classification produced nothing usable.;
      %let branch_coverage_failed = 1;
   %end;
   %else %put NOTE: OK -- &n_active_classifiable. beneficiaries have classifiable active-at-index exposure.;

   /* Informational: warn (dont fail) if all classifiable results are identical */
   proc sql noprint;
      select count(distinct active_primary) into :_n_distinct_active trimmed
      from &t_exposure. where not missing(active_primary);
   quit;
   %if &n_active_classifiable. > 0 and &_n_distinct_active. < 2 %then %do;
      %put WARNING: All classifiable beneficiaries have the SAME active_primary;
      %put WARNING: value (everyone exposed, or everyone unexposed) -- not a;
      %put WARNING: hard failure, but worth reviewing before trusting the gradient.;
   %end;

   %put NOTE: ================================================;
   %put NOTE: Checking informational branch frequencies (warnings only)...;
   %put NOTE: ================================================;

   %macro warn_if_absent(ds, var, value, label);
      %local _n;
      proc sql noprint;
         select count(*) into :_n trimmed from &ds. where &var. = "&value.";
      quit;
      %if &_n. = 0 %then %do;
         %put WARNING: &label. (&var.=&value.) not exercised by this sample.;
         %put WARNING: May reflect sampling, not broken logic -- informational only.;
      %end;
      %else %put NOTE: &label. (&var.=&value.): &_n. rows.;
   %mend;

   %warn_if_absent(&t_base., primary_group_psych, CANDIDATE, Candidate group)
   %warn_if_absent(&t_base., primary_group_psych, COMPARATOR, Comparator group)
   %warn_if_absent(&t_base., primary_group_psych, INTERMEDIATE, Intermediate group)
   %warn_if_absent(&t_base., moud_status, MOUD_PRESENT, MOUD present)
   %warn_if_absent(&t_base., moud_status, MOUD_ABSENT_OBSERVABLE, MOUD observably absent)
   %warn_if_absent(&t_base., moud_status, MOUD_UNKNOWN, MOUD unknown)
   %warn_if_absent(&t_exposure., active_status, ACTIVE, Active exposure)
   %warn_if_absent(&t_exposure., active_status, NOT_ACTIVE_OBSERVABLE, Confirmed not active)
   %warn_if_absent(&t_exposure., active_status, UNKNOWN_NO_PARTD, Unknown - no Part D)
   %warn_if_absent(&t_exposure., active_status, UNKNOWN_DAYS_SUPPLY, Unknown - invalid supply)
   %warn_if_absent(&t_exposure., active_status_allstrong, UNKNOWN_DRUG_CLASS, Unknown - drug class allstrong only)

   %put NOTE: ================================================;
   %if &branch_coverage_failed. = 1 %then %do;
      proc sql;
         update res.ibog_run_manifest&version_tag.
         set run_status = "BRANCH_FAIL";
      quit;
      %put ERROR: ONE OR MORE MINIMAL SANITY CHECKS FAILED -- see ERROR lines above.;
      %put ERROR: run_status set to BRANCH_FAIL in the manifest.;
      %ibog_stop(Branch-coverage test failed a minimal sanity check - review the 99b log before running 99c.);
   %end;
   %else %do;
      %assert_clean_run(stage=branch-coverage test)
      proc sql;
         update res.ibog_run_manifest&version_tag.
         set run_status = "BRANCH_OK";
      quit;
      %put NOTE: ALL MINIMAL SANITY CHECKS PASSED. run_status=BRANCH_OK.;
      %put NOTE: Review the informational WARNING lines above before assuming;
      %put NOTE: every logic branch was actually exercised -- they werent;
      %put NOTE: guaranteed by this samples stratification design.;
      %put NOTE: Safe to proceed to 99c after also confirming no other;
      %put NOTE: errors/warnings elsewhere in the log.;
   %end;
   %put NOTE: ================================================;

%mend run_99b;
%run_99b;

/* end 99b_run_branch_test.sas */
