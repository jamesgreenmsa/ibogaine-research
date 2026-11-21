libname outp "/path/to/your/working/directory\Ibogaine_Extraction\Output";

proc contents data=outp._ibogaine_pd_flags varnum; run;


proc freq data=outp._ibogaine_pd_flags ;
tables cyp2d6_tier / missing;
run;


libname res "/path/to/your/working/directory\Working\Ibogaine_FirstPass";

proc print data=res.ibog_fp_sensitivity_fp_full_v001 noobs; run;

proc print data=res.ibog_fp_summary_fp_full_v001 noobs; run;

libname en "/path/to/your/working/directory\Ibogaine_Extraction\Output\Enrollment"; run;

proc contents data=en.master_12016 varnum; run;