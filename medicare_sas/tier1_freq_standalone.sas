/* ============================================================
   tier1_freq_standalone.sas
   Purpose: Confirm Tier 1 strong-inhibitor candidate count
            (resolves 18.3% vs 16.3% discrepancy)
   Run as a NEW blank program tab in SAS EG.
   No dependency on work._ibog_demog or any prior data step.
   ============================================================ */

/* Option A - preferred: query permanent table directly.
   Produces the same cross-tab that _ibog_demog would give.    */

libname coh "/path/to/your/working/directory\Working\Cohorts"; run;

proc freq data=coh.ibog_fp_analysis_fp_full_v001;
  tables primary_group_psych * active_allstrong_primary
    / nocum nopercent norow nocol;
  where primary_comparison_flag = 1;
  title 'Tier 1 strong inhibitor by candidate/comparator - full binary cohort (coh.ibog_fp_analysis_fp_full_v001)';
run;


/* ============================================================
   Option B - only if coh.ibog_fp_analysis_fp_full_v001 is not
   accessible but work._ibog_demog already exists in WORK from
   a prior run this session.
   ============================================================ */

/*
proc freq data=work._ibog_demog;
  tables primary_group_psych * active_allstrong_primary
    / nocum nopercent norow nocol;
  where primary_comparison_flag = 1;
  title 'Tier 1 strong inhibitor by candidate/comparator - work._ibog_demog';
run;
*/


/* ============================================================
   What to look for in the output:

   primary_group_psych = CANDIDATE, primary_comparison_flag = 1
   active_allstrong_primary = 1  ->  should match 56,212
   total CANDIDATE row           ->  should match 307,336

   If those numbers confirm, 56,212 / 307,336 = 18.3% is verified
   and matches the manuscript. If the CANDIDATE total is smaller,
   the 18.3% likely came from a different filter or run version.
   ============================================================ */


proc means data=work._ibog_demog_analytic n missing;
var active_allstrong_primary ;
where primary_comparison_flag = 1;
run;