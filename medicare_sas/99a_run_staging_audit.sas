/******************************************************************************
PROGRAM  : 99a_run_staging_audit.sas
PURPOSE  : Driver 1 of 3 -- staging audit only (programs 00 + 01).
           run_id/test_mode are set HERE, before 00_setup.sas is included,
           so each driver gets its own run ID and the collision guard in
           00_setup does not block the intended audit-then-run sequence.
******************************************************************************/

%let ibog_code_root = /path/to/your/working/directory\Ibogaine_Extraction\j_code;

%global run_id test_mode test_sample_n;
%let run_id = audit_v001;
%let test_mode = Y;
%let test_sample_n = 500;

%put NOTE: ================================================;
%put NOTE: DRIVER 1/3: Staging audit only. run_id=&run_id.;
%put NOTE: Review log fully before running 99b (branch-complete test).;
%put NOTE: ================================================;

%include "&ibog_code_root.\00_ibogaine_setup.sas";
%initialize_ibog_run;
%include "&ibog_code_root.\01_validate_lydia_staging.sas";

%put NOTE: ================================================;
%put NOTE: STAGING AUDIT COMPLETE. Confirm before proceeding:;
%put NOTE:   1. Enrollment sentinel values correct?;
%put NOTE:   2. Drug-name scope of _ibogaine_pd_flags confirmed?;
%put NOTE:   3. pd_generic_name_var = FDB_GNN60 confirmed?;
%put NOTE:   4. max_days_supply parameter appropriate?;
%put NOTE:   5. Any duplicate/conflicting enrollment records to resolve?;
%put NOTE: Update 00_ibogaine_setup.sas if any of the above need changes.;
%put NOTE: ================================================;

/* Mark the manifest so a successful audit is distinguishable from one
   that crashed partway through. 04_first_pass_results.sas (which
   normally sets COMPLETED) never runs in this driver -- without this,
   the manifest would stay labeled STARTED forever even after a clean
   audit. AUDIT_DONE (not COMPLETED) makes clear this is only the audit
   stage, not the full pipeline. */
%assert_clean_run(stage=staging audit)
proc sql;
   update res.ibog_run_manifest&version_tag.
   set run_status = "AUDIT_DONE";
quit;
%put NOTE: run_status set to AUDIT_DONE in res.ibog_run_manifest&version_tag..;

/* end 99a_run_staging_audit.sas */
