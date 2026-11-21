

%put NOTE: 01_validate_lydia_staging.sas starting...;
%require_dataset(res.ibog_run_manifest&version_tag., context=01_validate needs 00_setup first);

%macro run_01_validate;

%require_dataset(ibog.eligible_scp_ibogaine_bene_flags, context=base eligibility file);
%require_dataset(ibog._ibogaine_dx_flags,               context=diagnosis flags);
%require_dataset(ibog._ibogaine_pd_flags,               context=Part D pharmacy flags);


%local cardiac_available;
%let cardiac_available = %sysfunc(exist(ibog._cardiac_outcome_flags));
%if &cardiac_available. %then %do;
   %put NOTE: _cardiac_outcome_flags found -- auditing (optional for this package).;
   %require_vars(ibog._cardiac_outcome_flags,
      bene_id clm_from_dt out_qt_prolongation out_torsades out_vt out_vf
      out_cardiac_arrest out_afib out_bradycardia out_heart_failure
      out_cardiomyopathy out_conduction out_cardioversion);
%end;
%else %put NOTE: _cardiac_outcome_flags not found -- OK, not required for this;
%put NOTE: package. It will be required when 05_cardiac_secondary.sas is written.;

%require_vars(ibog.eligible_scp_ibogaine_bene_flags,
   bene_id flag_oud_dx flag_moud_fill first_oud_dx_dt first_moud_fill_dt
   flag_ptsd flag_depression flag_anxiety flag_tbi first_qualifier_dt);
%require_vars(ibog._ibogaine_dx_flags,
   bene_id clm_from_dt flag_ptsd flag_depression flag_anxiety flag_tbi flag_oud_dx);
%require_vars(ibog._ibogaine_pd_flags,
   bene_id srvc_dt cyp2d6_tier days_suply_num flag_moud);

/* ITEM 8: Hard-stop if the confirmed generic-name variable is absent */
%require_vars(ibog._ibogaine_pd_flags, &pd_generic_name_var.);


%macro check_enrollment_years;
   %local yr m enr_vars;
   %let enr_vars = bene_id bene_enrollmt_ref_yr bene_death_dt valid_death_dt_sw;
   %do m = 1 %to 12;
      %let enr_vars = &enr_vars.
         mdcr_entlmt_buyin_ind_%sysfunc(putn(&m.,z2.))
         hmo_ind_%sysfunc(putn(&m.,z2.))
         ptd_cntrct_id_%sysfunc(putn(&m.,z2.));
   %end;
   %do yr = &enr_first_year. %to &enr_last_year.;
      %require_dataset(enr.master_1&yr., context=enrollment year &yr.);
      %require_vars(enr.master_1&yr., &enr_vars.);
   %end;
%mend;
%check_enrollment_years;
%put NOTE: All enrollment years &enr_first_year.-&enr_last_year. confirmed present;
%put NOTE: with all 12 monthly entitlement/HMO/Part-D-contract variables.;

/* ===========================================================================
   SECTION 2: Row counts and key structure
   =========================================================================== */
%local n_base n_dx n_pd n_card n_base_benes n_dx_benes n_pd_benes n_card_benes;

proc sql noprint;
   select count(*), count(distinct bene_id)
   into :n_base trimmed, :n_base_benes trimmed
   from ibog.eligible_scp_ibogaine_bene_flags;
quit;
%put NOTE: eligible_scp_ibogaine_bene_flags: &n_base. rows, &n_base_benes. distinct benes;
%if &n_base. ne &n_base_benes. %then
   %ibog_stop(eligible_scp_ibogaine_bene_flags is NOT unique by bene_id - &n_base. rows and &n_base_benes. distinct);

proc sql noprint;
   select count(*), count(distinct bene_id) into :n_dx trimmed, :n_dx_benes trimmed
   from ibog._ibogaine_dx_flags;
quit;
%put NOTE: _ibogaine_dx_flags: &n_dx. rows, &n_dx_benes. distinct benes (multiple rows per bene expected);

proc sql noprint;
   select count(*), count(distinct bene_id) into :n_pd trimmed, :n_pd_benes trimmed
   from ibog._ibogaine_pd_flags;
quit;
%put NOTE: _ibogaine_pd_flags: &n_pd. rows, &n_pd_benes. distinct benes;

%if &cardiac_available. %then %do;
   proc sql noprint;
      select count(*), count(distinct bene_id) into :n_card trimmed, :n_card_benes trimmed
      from ibog._cardiac_outcome_flags;
   quit;
   %put NOTE: _cardiac_outcome_flags: &n_card. rows, &n_card_benes. distinct benes;
%end;
%else %do;
   %let n_card = 0;
   %let n_card_benes = 0;
%end;

/* ===========================================================================
   SECTION 3: Flag frequencies and date ranges
   =========================================================================== */
proc freq data=ibog.eligible_scp_ibogaine_bene_flags;
   tables flag_oud_dx flag_moud_fill flag_ptsd flag_depression
          flag_anxiety flag_tbi / missing;
   title "01_validate: Base file flag frequencies";
run;

proc means data=ibog.eligible_scp_ibogaine_bene_flags n nmiss min max;
   var first_oud_dx_dt first_moud_fill_dt first_qualifier_dt;
   format first_oud_dx_dt first_moud_fill_dt first_qualifier_dt date9.;
   title "01_validate: Date ranges in base file";
run;

proc means data=ibog._ibogaine_dx_flags n nmiss min max;
   var clm_from_dt;
   format clm_from_dt date9.;
   title "01_validate: Diagnosis date range";
run;

/* ===========================================================================
   SECTION 3b (item 8 fix): 
   =========================================================================== */
%local n_orig n_oud_flag_no_date n_oud_date_no_flag
       n_moud_flag_no_date n_moud_date_no_flag n_both_anchors_missing
       n_valid_anchor;

proc sql noprint;
   select count(*) into :n_orig trimmed from ibog.eligible_scp_ibogaine_bene_flags;

   select count(*) into :n_oud_flag_no_date trimmed
   from ibog.eligible_scp_ibogaine_bene_flags
   where flag_oud_dx = 1 and missing(first_oud_dx_dt);

   select count(*) into :n_oud_date_no_flag trimmed
   from ibog.eligible_scp_ibogaine_bene_flags
   where not missing(first_oud_dx_dt) and flag_oud_dx = 0;

   select count(*) into :n_moud_flag_no_date trimmed
   from ibog.eligible_scp_ibogaine_bene_flags
   where flag_moud_fill = 1 and missing(first_moud_fill_dt);

   select count(*) into :n_moud_date_no_flag trimmed
   from ibog.eligible_scp_ibogaine_bene_flags
   where not missing(first_moud_fill_dt) and flag_moud_fill = 0;

   select count(*) into :n_both_anchors_missing trimmed
   from ibog.eligible_scp_ibogaine_bene_flags
   where missing(first_oud_dx_dt) and missing(first_moud_fill_dt);

   select count(*) into :n_valid_anchor trimmed
   from ibog.eligible_scp_ibogaine_bene_flags
   where not missing(first_oud_dx_dt) or not missing(first_moud_fill_dt);
quit;

%put NOTE: ================================================;
%put NOTE: FLAG/DATE CONSISTENCY CHECK (item 8):;
%put NOTE:   Original staged beneficiary rows: &n_orig.;
%put NOTE:   Rows with a valid observed anchor (OUD dx or MOUD fill date): &n_valid_anchor.;
%put NOTE:   Rows excluded for missing BOTH anchor dates: &n_both_anchors_missing.;
%put NOTE:   flag_oud_dx=1 but first_oud_dx_dt missing: &n_oud_flag_no_date.;
%put NOTE:   first_oud_dx_dt present but flag_oud_dx=0: &n_oud_date_no_flag.;
%put NOTE:   flag_moud_fill=1 but first_moud_fill_dt missing: &n_moud_flag_no_date.;
%put NOTE:   first_moud_fill_dt present but flag_moud_fill=0: &n_moud_date_no_flag.;
%put NOTE: ================================================;
%if &n_oud_flag_no_date. > 0 or &n_oud_date_no_flag. > 0
    or &n_moud_flag_no_date. > 0 or &n_moud_date_no_flag. > 0 %then %do;
   %put WARNING: Flag/date inconsistencies found above -- discuss with Lydia;
   %put WARNING: before trusting anchor dates. Not a hard stop for the;
   %put WARNING: audit, but should be resolved before the full run.;
%end;
%else %put NOTE: No flag/date inconsistencies found -- flags and dates agree.;

/* ===========================================================================
   SECTION 4: KEY AUDIT -- scope of _ibogaine_pd_flags
   cyp2d6_tier values, days_suply_num distribution, drug names
   =========================================================================== */
proc freq data=ibog._ibogaine_pd_flags;
   tables cyp2d6_tier / missing;
   title "01_validate AUDIT: cyp2d6_tier values (confirm STRONG/MODERATE coding)";
run;

proc freq data=ibog._ibogaine_pd_flags;
   tables flag_moud / missing;
   title "01_validate AUDIT: flag_moud frequency";
run;

proc means data=ibog._ibogaine_pd_flags n nmiss min p1 p5 p25 p50 p75 p95 p99 max;
   var days_suply_num;
   title "01_validate AUDIT: days_suply_num distribution (ALL pharmacy records)";
run;

/* Target-drug-specific days-supply distribution  */
data _target_drug_check;
   set ibog._ibogaine_pd_flags;
   length name_norm $100 target_drug $12;
   name_norm = upcase(strip(&pd_generic_name_var.));
   is_bupropion  = (index(name_norm, "&target_drug_1.") > 0);
   is_paroxetine = (index(name_norm, "&target_drug_2.") > 0);
   is_fluoxetine = (index(name_norm, "&target_drug_3.") > 0);
   is_target = (is_bupropion or is_paroxetine or is_fluoxetine);
   if is_bupropion then target_drug = "Bupropion";
   else if is_paroxetine then target_drug = "Paroxetine";
   else if is_fluoxetine then target_drug = "Fluoxetine";
run;

proc means data=_target_drug_check n nmiss min p1 p5 p25 p50 p75 p95 p99 max;
   where is_target = 1;
   var days_suply_num;
   title "01_validate AUDIT: days_suply_num distribution -- TARGET DRUGS ONLY";
   title2 "(bupropion/paroxetine/fluoxetine) -- use THIS to set max_days_supply, not the all-drug distribution above";
run;

/* ITEM 7 FIX:  */
proc sql;
   create table &t_concord. as
   select target_drug, cyp2d6_tier, count(*) as n_fills
   from _target_drug_check
   where is_target = 1
   group by target_drug, cyp2d6_tier;
quit;
proc print data=&t_concord. noobs;
   title "01_validate AUDIT: Target drug vs. cyp2d6_tier concordance";
   title2 "Shows whether Lydias tier field agrees with the name-based target-drug definition";
run;

/* Days-supply validity summary -- compact, not a full data copy (item 18 fix) */
proc sql;
   create table &t_days_audit. as
   select "missing"       as category length=20, count(*) as n
      from ibog._ibogaine_pd_flags where missing(days_suply_num)
   UNION ALL
   select "zero_or_neg"   as category, count(*) as n
      from ibog._ibogaine_pd_flags where not missing(days_suply_num) and days_suply_num <= 0
   UNION ALL
   select "1_to_30"       as category, count(*) as n
      from ibog._ibogaine_pd_flags where days_suply_num between 1 and 30
   UNION ALL
   select "31_to_90"      as category, count(*) as n
      from ibog._ibogaine_pd_flags where days_suply_num between 31 and 90
   UNION ALL
   select "91_to_100"     as category, count(*) as n
      from ibog._ibogaine_pd_flags where days_suply_num between 91 and 100
   UNION ALL
   select "101_to_180"    as category, count(*) as n
      from ibog._ibogaine_pd_flags where days_suply_num between 101 and 180
   UNION ALL
   select "181_to_365"    as category, count(*) as n
      from ibog._ibogaine_pd_flags where days_suply_num between 181 and 365
   UNION ALL
   select "over_365"      as category, count(*) as n
      from ibog._ibogaine_pd_flags where days_suply_num > 365;
quit;

proc print data=&t_days_audit. noobs;
   title "01_validate: Days-supply distribution summary";
run;

/* ITEM 4 FIX: drug names via sorted frequency output, not MAXLEVELS= */
proc freq data=ibog._ibogaine_pd_flags noprint;
   tables &pd_generic_name_var. / missing out=_drug_freq;
run;
proc sort data=_drug_freq; by descending count; run;
proc print data=_drug_freq (obs=50) noobs;
   title "01_validate AUDIT: Top 50 drug names in _ibogaine_pd_flags (&pd_generic_name_var.)";
   title2 "Determines whether file is CYP2D6-only or broader Part D extract";
run;

/* ===========================================================================
   SECTION 5: Enrollment sentinel values -- inspect actual data
   =========================================================================== */
%local yr; %let yr = &enr_last_year.;
proc freq data=enr.master_1&yr.;
   tables MDCR_ENTLMT_BUYIN_IND_01 HMO_IND_01 PTD_CNTRCT_ID_01 / missing;
   title "01_validate AUDIT: Enrollment sentinel values from master_1&yr., month 01";
   title2 "Confirm assumed codes: entlmt_ab=&entlmt_ab_codes., hmo_ffs=&hmo_ffs_codes., partd_none=&partd_none_vals.";
run;

/* ===========================================================================
   SECTION 6: Cross-file linkage -- pharmacy dx benes in base file
   =========================================================================== */
%local n_pd_orphan n_dx_orphan n_cardiac_no_flag;

proc sql noprint;
   select count(distinct p.bene_id) into :n_pd_orphan trimmed
   from ibog._ibogaine_pd_flags p
   left join ibog.eligible_scp_ibogaine_bene_flags b on p.bene_id = b.bene_id
   where b.bene_id is missing;
quit;
%put NOTE: Pharmacy benes NOT in base file: &n_pd_orphan. (should be 0);

proc sql noprint;
   select count(distinct d.bene_id) into :n_dx_orphan trimmed
   from ibog._ibogaine_dx_flags d
   left join ibog.eligible_scp_ibogaine_bene_flags b on d.bene_id = b.bene_id
   where b.bene_id is missing;
quit;
%put NOTE: Dx-flag benes NOT in base file: &n_dx_orphan. (should be 0);

%if &cardiac_available. %then %do;
   proc sql noprint;
      select count(*) into :n_cardiac_no_flag trimmed
      from ibog._cardiac_outcome_flags
      where sum(out_qt_prolongation, out_torsades, out_vt, out_vf, out_cardiac_arrest,
                out_afib, out_bradycardia, out_heart_failure, out_cardiomyopathy,
                out_conduction, out_cardioversion) = 0;
   quit;
   %put NOTE: Cardiac rows with NO positive flag: &n_cardiac_no_flag. (should be 0 if pre-filtered);
%end;
%else %do;
   %let n_cardiac_no_flag = 0;
   %put NOTE: Cardiac file not available -- skipping positive-flag check.;
%end;

/* ===========================================================================
   SECTION 7: Write proper inventory -- one row per source file (item 7 fix)
   =========================================================================== */
data &t_audit.;
	length source_file $40 notes $80;
	n_rows = &n_base.; n_distinct_benes = &n_base_benes.;
	is_bene_unique = (input("&n_base.", 8.) = input("&n_base_benes.", 8.));
	source_file = "eligible_scp_ibogaine_bene_flags";
	notes= "Bene-level - Expected unique by bene id"; output;

	n_rows = &n_dx.; n_distinct_benes = &n_dx_benes.;
	is_bene_unique = 0;
	source_file = "_ibogaine_dx_flags";
	notes="Claim-level dx flags" ; output;

	n_rows = &n_pd.; n_distinct_benes = &n_pd_benes.;
	is_bene_unique = 0;
	source_file = "_ibogaine_pd_flags";
	notes="Claim-level pharmacy flags" ; output;

	n_rows = &n_card.; n_distinct_benes = &n_card_benes.;
	is_bene_unique = 0;
	source_file = "_cardiac_outcome_flags";
	notes="Claim-level cardiac flags" ; output;
run;

data &t_issues.;
   length check $60 result $80 action_needed $200;
   check = "Pharmacy orphan benes";
   result = "&n_pd_orphan. benes in pharmacy but not base file";
   if input("&n_pd_orphan.", 8.) > 0 then
      action_needed = "Investigate with Lydia -- likely extraction scope difference";
   else action_needed = "None";
   output;
   check = "Dx-flag orphan benes";
   result = "&n_dx_orphan. benes in dx-flags but not base file";
   if input("&n_dx_orphan.", 8.) > 0 then
      action_needed = "Investigate with Lydia";
   else action_needed = "None";
   output;
   check = "Cardiac rows without positive flag";
   result = "&n_cardiac_no_flag. rows";
   if input("&n_cardiac_no_flag.", 8.) > 0 then
      action_needed = "Build script may not be pre-filtering -- review";
   else action_needed = "None";
   output;
   check = "Enrollment sentinel values";
   result = "See AUDIT output in log";
   action_needed = "Confirm codes match ResDAC before running 02_build";
   output;
   check = "Drug-name scope";
   result = "See top-50 drug names in log";
   action_needed = "Confirm file is CYP2D6-relevant only, or note broader scope";
   output;
run;

%put NOTE: 01_validate complete.;
%put NOTE: ================================================;
%put NOTE: REQUIRED BEFORE RUNNING 02_build:;
%put NOTE:   1. Confirm enrollment sentinel values are correct;
%put NOTE:   2. Confirm drug-name scope of _ibogaine_pd_flags;
%put NOTE:   3. Confirm pd_generic_name_var = &pd_generic_name_var.;
%put NOTE:   4. Confirm days_suply_num handling (max_days_supply = &max_days_supply.);
%put NOTE:   5. Review &t_concord. -- does Lydias tier field agree with the;
%put NOTE:      name-based target-drug definition?;
%put NOTE:   6. Confirm whether _ibogaine_pd_flags captures ALL MOUD sources;
%put NOTE:      (Part D only, or also OTP/methadone billed elsewhere) -- this;
%put NOTE:      affects whether MOUD_ABSENT_OBSERVABLE means what it sounds;
%put NOTE:      like it means.;
%put NOTE:   7. Review the flag/date consistency check above -- any WARNING;
%put NOTE:      lines there should be discussed with Lydia first.;
%put NOTE: Then run 99b_run_branch_test.sas (not this audit-only driver).;
%put NOTE: ================================================;

%mend run_01_validate;
%run_01_validate;

/* end 01_validate_lydia_staging.sas */
