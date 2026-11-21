/******************************************************************************
PROGRAM  : 99c_run_full_firstpass.sas
PURPOSE  : Driver 3 of 3 -- FULL first-pass pipeline, test_mode=N.
           This is the run whose results actually answer the original
           question. Run ONLY after 99a and 99b have both been reviewed
           and confirmed clean.

VERSION  : (this round) Manifest initialization moved to AFTER the
           prerequisite-manifest gate (item 2 fix). Prerequisite check
           now validates program_version and key scientific parameters,
           not just run_status (item 3 fix).
******************************************************************************/

%let ibog_code_root = /path/to/your/working/directory\Ibogaine_Extraction\j_code;

%global run_id test_mode test_sample_n;
%let run_id = fp_full_v001;
%let test_mode = N;
%let test_sample_n = 0; /* unused when test_mode=N */

%macro run_99c;

   %put NOTE: ================================================;
   %put NOTE: DRIVER 3/3: FULL FIRST-PASS PIPELINE. run_id=&run_id.;
   %put NOTE: test_mode=N -- this processes the FULL staged population.;
   %put NOTE: ================================================;

   /* Phase 1 only -- does NOT create the current run's manifest */
   %include "&ibog_code_root.\00_ibogaine_setup.sas";

   /* ITEM 3 FIX: validate status AND program_version AND key scientific
      parameters on the prerequisite branch-test manifest -- a stale
      BRANCH_OK from an older code package should not silently authorize
      a full run under different code. */
   %local _branch_status _branch_version _branch_class_days _branch_index_offset
          _branch_max_supply _branch_drugs _branch_first_yr _branch_last_yr;

   %if not %sysfunc(exist(res.ibog_run_manifest_fp_test_v001)) %then %do;
      %ibog_stop(Prerequisite branch-test manifest res.ibog_run_manifest_fp_test_v001 not found - run 99b_run_branch_test.sas first.);
   %end;
   proc sql noprint;
      select run_status, program_version, classification_days, index_offset,
             max_days_supply, target_drug_list, enr_first_year, enr_last_year
      into :_branch_status trimmed, :_branch_version trimmed,
           :_branch_class_days trimmed, :_branch_index_offset trimmed,
           :_branch_max_supply trimmed, :_branch_drugs trimmed,
           :_branch_first_yr trimmed, :_branch_last_yr trimmed
      from res.ibog_run_manifest_fp_test_v001;
   quit;

   %if %upcase(&_branch_status.) ne BRANCH_OK %then %do;
      %ibog_stop(Prerequisite branch-test run_status is &_branch_status. - expected BRANCH_OK - review and rerun 99b before continuing.);
   %end;
   %if %upcase(&_branch_version.) ne %upcase(&program_version.) %then %do;
      %ibog_stop(Prerequisite branch test used program_version=&_branch_version. but current code is &program_version. - rerun 99b with the current code package before continuing.);
   %end;
   %if &_branch_class_days. ne &classification_days. or &_branch_index_offset. ne &index_offset.
       or &_branch_max_supply. ne &max_days_supply. or %superq(_branch_drugs) ne %superq(target_drug_list)
       or &_branch_first_yr. ne &enr_first_year. or &_branch_last_yr. ne &enr_last_year. %then %do;
      %ibog_stop(Prerequisite branch test was run with different scientific parameters than the current code - rerun 99b before continuing.);
   %end;
   %put NOTE: Prerequisite branch test confirmed BRANCH_OK, matching program_version, and matching parameters.;

   /* Only NOW, after all gates pass, initialize this run's manifest */
   %initialize_ibog_run;

   %include "&ibog_code_root.\01_validate_lydia_staging.sas";
   %include "&ibog_code_root.\02_build_landmark_population.sas";
   %include "&ibog_code_root.\03_define_cyp2d6_exposure.sas";
   %include "&ibog_code_root.\04_first_pass_results.sas";

   %assert_clean_run(stage=full first-pass run)
   proc sql;
      update res.ibog_run_manifest&version_tag.
      set run_status = "COMPLETED";
   quit;
   %put NOTE: run_status set to COMPLETED in res.ibog_run_manifest&version_tag..;

   /* 05_cardiac_secondary.sas deliberately omitted --
      run only after reviewing these first-pass results */

   %put NOTE: ================================================;
   %put NOTE: FULL FIRST-PASS PIPELINE COMPLETE. run_id=&run_id.;
   %put NOTE: Results are in the res. library.;
   %put NOTE: Key output: &t_gradient.;
   %put NOTE: ================================================;

%mend run_99c;
%run_99c;

/* end 99c_run_full_firstpass.sas */
