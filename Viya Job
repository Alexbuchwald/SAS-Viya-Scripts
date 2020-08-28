cas casauto sessopts=(caslib='CSML' TIMEOUT=600);
libname CSML cas; 

%global MATID;
%global PLANT;

proc sql noprint;
create table work.data as
select MAT_ID_8,DESCRIPTION_EN,VALUATION_PRICE from CSML.SDTB_DM_CSML_MATERIAL_MASTER 
where MAT_ID_8 IN ('&MATID') 
and plant in ('&PLANT')
;
quit;

ods _all_ close;

filename exp_file filesrvc parenturi="&SYS_JES_JOB_URI"
name="_webout.xlsx"
 contentdisp="attachment; filename=CSML_SMART_REPORT_EXPORT.xlsx";

proc export 
	data=work.data 
	dbms=xlsx 
	outfile=exp_file 
	label 
	replace;
run;
