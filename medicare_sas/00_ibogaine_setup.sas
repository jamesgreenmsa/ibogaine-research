/******************************************************************************
PROGRAM  : 00_ibogaine_setup.sas
VERSION  : fp_v006 (round 3 fixes: item 1 macro utility ordering + label=
           keyword syntax, item 2 run-ID collision resolved by letting the
           calling driver set run_id/test_mode BEFORE this file is included)
******************************************************************************/

/* ===========================================================================
   SHARED UTILITY MACROS -- defined FIRST, before anything that calls them
   (item 1 fix: check_name_length below calls %ibog_stop and must come after).
   All use %local for temporary variables to prevent leakage.
   =========================================================================== */

%macro ibog_stop(msg);
   %put ERROR: ==============================================;
   %put ERROR: IBOGAINE PIPELINE STOPPED: &msg.;
   %put ERROR: ==============================================;
   %abort cancel;
%mend;

%macro require_dataset(ds, context=);
   %if not %sysfunc(exist(&ds.)) %then
      %ibog_stop(Required dataset &ds. does not exist. Context: &context.);
   %else %put NOTE: OK -- &ds. exists.;
%mend;

/* Item 2 fix: SAS can hit an error in a procedure, set a nonzero
   condition code, and keep executing. Without this check, a manifest
   could say AUDIT_DONE/BRANCH_OK/COMPLETED purely because execution
   reached the final line, even if something upstream actually failed.
   Call this immediately before every success-status update. */
%macro assert_clean_run(stage=);
   %if %sysevalf(&syscc. > 4) %then %do;
      proc sql;
         update res.ibog_run_manifest&version_tag.
         set run_status = "FAILED";
      quit;
      %ibog_stop(SAS condition code &syscc. indicates an error before completion of &stage. - run_status set to FAILED.);
   %end;
   %else %put NOTE: SYSCC check passed (&syscc.) before marking &stage. complete.;
%mend;

%macro assert_unique(ds, keyvar=bene_id);
   %local _rows _distinct;
   proc sql noprint;
      select count(*), count(distinct &keyvar.)
      into :_rows trimmed, :_distinct trimmed
      from &ds.;
   quit;
   %if &_rows. ne &_distinct. %then
      %ibog_stop(&ds. is NOT unique by &keyvar. - &_rows. rows and &_distinct. distinct.);
   %else %put NOTE: UNIQUE -- &ds. unique by &keyvar. (&_rows. rows).;
%mend;

%macro log_counts(ds, label=);
   %local _rows _distinct;
   proc sql noprint;
      select count(*), count(distinct bene_id)
      into :_rows trimmed, :_distinct trimmed
      from &ds.;
   quit;
   %put NOTE: COUNTS | &label. | rows=&_rows. | benes=&_distinct.;
%mend;

%macro require_vars(ds, vars);
   %local _missing _vlist _i _v _dsid _found;
   %let _missing = ;
   %let _vlist   = &vars.;
   %let _dsid    = %sysfunc(open(&ds.));
   %if &_dsid. = 0 %then
      %ibog_stop(Cannot open &ds. to check variables.);
   %let _i = 1;
   %let _v = %scan(&_vlist., &_i., %str( ));
   %do %while (&_v. ne );
      %let _found = %sysfunc(varnum(&_dsid., &_v.));
      %if &_found. = 0 %then %let _missing = &_missing. &_v.;
      %let _i = %eval(&_i. + 1);
      %let _v = %scan(&_vlist., &_i., %str( ));
   %end;
   %let _dsid = %sysfunc(close(&_dsid.));
   %if %length(%trim(&_missing.)) > 0 %then
      %ibog_stop(&ds. is missing required variables:&_missing.);
   %else %put NOTE: VARS OK -- &ds. has all required variables.;
%mend;

/* Output-name length check -- now safe to define since %ibog_stop exists */
%macro check_name_length(nm, label=);
   %local memonly;
   %let memonly = %scan(&nm., 2, .);
   %if %length(&memonly.) > 32 %then
      %ibog_stop(Output name &label. resolves to &memonly. - %length(&memonly.) characters with maximum 32);
%mend;


%global run_id version_tag test_mode test_sample_n;

%macro run_00_setup;

   %if %length(%superq(run_id)) = 0 %then %do;
      %let run_id = fpd_v001;
      %put NOTE: run_id not set by driver -- defaulting to &run_id..;
   %end;
   %let version_tag = _&run_id.;

   %if %length(%superq(test_mode)) = 0 %then %do;
      %let test_mode = Y;
      %put NOTE: test_mode not set by driver -- defaulting to Y.;
   %end;

   %if %length(%superq(test_sample_n)) = 0 %then %let test_sample_n = 500;

   /* dlcreatedir BEFORE libname statements (item 9, two rounds ago) */
   options dlcreatedir;

   /* ===========================================================================
      LIBRARIES
      =========================================================================== */
   /* -------------------------------------------------------------------------
   Set proj_root to the root of your local working directory before running.
   Example (Windows): %let proj_root = C:\Projects\Ibogaine;
   Example (Unix/Mac): %let proj_root = /data/projects/ibogaine;
   The pipeline expects subdirectories: Output, Working, Ibogaine_Extraction
   ------------------------------------------------------------------------- */
%let proj_root = /path/to/your/working/directory;
   %let outp      = &proj_root.\Output;
   %let ibog_root = &proj_root.\Ibogaine_Extraction;
   %let workp     = &proj_root.\Working;

   libname out  "&outp.\temp_output_green"                  access=readonly;
   libname enr  "&ibog_root.\Output\Enrollment";
   libname ibog "&ibog_root.\Output"         access=readonly;
   libname coh  "&workp.\Cohorts";
   libname res  "&workp.\Ibogaine_FirstPass";

   %put NOTE: ====================================================;
   %put NOTE: Ibogaine first-pass -- run &run_id. test_mode=&test_mode.;
   %put NOTE: ====================================================;

   /* ===========================================================================
      SCIENTIFIC PARAMETERS
      =========================================================================== */
   %global classification_days index_offset;
   %let classification_days = 365;
   %let index_offset        = 365;

   %global enr_first_year enr_last_year;
   %let enr_first_year = 2016;
   %let enr_last_year  = 2022;

   %global entlmt_ab_codes hmo_ffs_codes partd_none_vals;
   %let entlmt_ab_codes = ('3','C');
   %let hmo_ffs_codes   = ('0','4');
   %let partd_none_vals = ('','0000N','N0000');

   %global cand_min_qualifiers comp_max_qualifiers;
   %let cand_min_qualifiers = 2;
   %let comp_max_qualifiers = 0;

   %global cyp2d6_strong_tiers recent_fill_days max_days_supply;
   %let cyp2d6_strong_tiers = ('STRONG');
   %let recent_fill_days    = 90;
   %let max_days_supply     = 100;

   %global pd_generic_name_var;
   %let pd_generic_name_var = FDB_GNN60;

   %global target_drug_1 target_drug_2 target_drug_3 target_drug_list;
   %let target_drug_1 = BUPROPION;
   %let target_drug_2 = PAROXETINE;
   %let target_drug_3 = FLUOXETINE;
   %let target_drug_list = &target_drug_1./&target_drug_2./&target_drug_3.;

   /* ITEM 9 FIX (this round): program_version is now a variable, not a
      hardcoded string repeated in the manifest -- bumped to fp_v006 to
      reflect that this package has undergone multiple substantive
      revisions since fp_v001 was first assigned. A run_id distinguishes
      individual executions but NOT code versions; two different code
      packages could otherwise both claim program_version=fp_v001. */
   %global program_version;
   %let program_version = fp_v006;

   /* Output names -- all <= 32 characters */
   %global t_base t_exposure t_analysis t_attrition t_audit t_issues
           t_qual_combos t_days_audit t_table1 t_gradient t_sensitivity t_summary
           t_concord t_drugspec t_qualpres;
   %let t_base        = coh.ibog_fp_base&version_tag.;
   %let t_exposure    = coh.ibog_fp_exposure&version_tag.;
   %let t_analysis    = coh.ibog_fp_analysis&version_tag.;
   %let t_attrition   = res.ibog_fp_attrition&version_tag.;
   %let t_audit       = res.ibog_stg_inv&version_tag.;
   %let t_issues      = res.ibog_fp_stg_issues&version_tag.;
   %let t_qual_combos = res.ibog_qual_combo&version_tag.;
   %let t_days_audit  = res.ibog_days_audit&version_tag.;
   %let t_table1      = res.ibog_fp_table1&version_tag.;
   %let t_gradient    = res.ibog_exp_gradient&version_tag.;
   %let t_sensitivity = res.ibog_fp_sensitivity&version_tag.;
   %let t_summary     = res.ibog_fp_summary&version_tag.;
   %let t_concord     = res.ibog_concord&version_tag.;
   %let t_drugspec    = res.ibog_drugspec&version_tag.;
   %let t_qualpres    = res.ibog_qualpres&version_tag.;

   %check_name_length(&t_base.,        label=t_base)
   %check_name_length(&t_exposure.,    label=t_exposure)
   %check_name_length(&t_analysis.,    label=t_analysis)
   %check_name_length(&t_attrition.,   label=t_attrition)
   %check_name_length(&t_audit.,       label=t_audit)
   %check_name_length(&t_issues.,      label=t_issues)
   %check_name_length(&t_qual_combos., label=t_qual_combos)
   %check_name_length(&t_days_audit.,  label=t_days_audit)
   %check_name_length(&t_table1.,      label=t_table1)
   %check_name_length(&t_gradient.,    label=t_gradient)
   %check_name_length(&t_sensitivity., label=t_sensitivity)
   %check_name_length(&t_summary.,     label=t_summary)
   %check_name_length(&t_concord.,     label=t_concord)
   %check_name_length(&t_drugspec.,    label=t_drugspec)
   %check_name_length(&t_qualpres.,    label=t_qualpres)

   %put NOTE: 00_ibogaine_setup.sas (phase 1: libraries/parameters) complete.;
   %put NOTE: run_id=&run_id. test_mode=&test_mode. program_version=&program_version.;
   %put NOTE: Call %%initialize_ibog_run AFTER prerequisite/approval gates pass.;

%mend run_00_setup;
%run_00_setup;


%macro initialize_ibog_run;

   %if %sysfunc(exist(res.ibog_run_manifest&version_tag.)) %then %do;
      %ibog_stop(Run ID &run_id. already exists in the res. library - choose a new run ID in the driver.);
   %end;

   data res.ibog_run_manifest&version_tag.;
      length run_status $14 target_drug_list $60 program_version $10;
      run_id              = "&run_id.";
      program_version     = "&program_version.";
      run_status          = "STARTED";
      test_mode           = "&test_mode.";
      test_sample_n       = "&test_sample_n.";
      classification_days = "&classification_days.";
      index_offset        = "&index_offset.";
      enr_first_year      = "&enr_first_year.";
      enr_last_year       = "&enr_last_year.";
      cand_min_qualifiers = "&cand_min_qualifiers.";
      comp_max_qualifiers = "&comp_max_qualifiers.";
      cyp2d6_strong_tiers = "&cyp2d6_strong_tiers.";
      target_drug_list    = "&target_drug_list.";
      recent_fill_days    = "&recent_fill_days.";
      max_days_supply     = "&max_days_supply.";
      pd_generic_name_var = "&pd_generic_name_var.";
      created_dt          = put(today(), date9.);
   run;

   %put NOTE: Run manifest initialized for run_id=&run_id. (run_status=STARTED).;

%mend initialize_ibog_run;

/* end 00_ibogaine_setup.sas */
