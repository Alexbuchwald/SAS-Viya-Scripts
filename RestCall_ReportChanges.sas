/* General settings */
options VALIDVARNAME = ANY VALIDMEMNAME = EXTEND; 
options nonotes;
cas casauto;
caslib _all_ assign;

/* Setting variables */
%global selected_year;
%global viyahost;
%global report_uri;	
%global viyatarget;
%global myfolder;
%let viyahost=ptcrhelsasviya.ptc.internal;
%let report_template=/reports/reports/09d34d67-6c89-4d6d-9a41-88a168fdaac9;
%let selected_year=2017;

/* Reload data source if not In-Memory */
%macro reload_tables(CAS_lib,CAS_table);
	%if  %sysfunc(exist(&CAS_lib..&CAS_table.)) %then %do;
	    %put Table &CAS_lib..&CAS_table. was already loaded;
	%end;
	%else %do;
	    proc casutil outcaslib="&CAS_lib" incaslib="&CAS_lib." ;
			load casdata="&CAS_table..sashdat" replace 
			casout="&CAS_table";           
	    quit;
	    %put Table &CAS_lib..&CAS_table reloaded;
	%end;
%mend reload_tables;

%reload_tables(SAMPLES,COSTCHANGE);
%reload_tables(SAMPLES,WARRANTY_CLAIMS_0117);

/* Change data */
data work.COSTCHANGE;
   set SAMPLES.COSTCHANGE;
run; 

data work.WARRANTY_CLAIMS_0117;
   set SAMPLES.WARRANTY_CLAIMS_0117(where=(SHIP_YEAR_CD="&selected_year."));
run; 

/* Promote tables */
proc casutil outcaslib="CASUSER" ;
	load data=work.COSTCHANGE promote ;
	load data=work.WARRANTY_CLAIMS_0117 promote ;
quit;

/*** REST Calls ***/
/* Getting personal folder URI */
filename respond temp;
filename resp_hdr temp;

proc http 
	method="GET" 
	oauth_bearer=sas_services 
	url="&viyahost/folders/folders/@myFolder" 
	ct="application/vnd.sas.collectionn"
	out=respond 
	headerout=resp_hdr
	headerout_overwrite; 
run; 

libname respond json;

data _NULL_; 
	set respond.links(where=(rel="self")); 
	call symputx('myfolder',uri); 
run; 
%put Myfolder URI for "&SYS_COMPUTE_SESSION_OWNER.": &myfolder.;


/* Copy Report and Change first data source */
filename respond temp;
filename resp_hdr temp;
%put Creation of new Report;

proc http
	method="POST" oauth_bearer=sas_services
	url="&viyahost/reportTransforms/dataMappedReports/?useSavedReport=true&saveResult=true"
	in=%unquote(%nrbquote('{
			  "inputReportUri": "&report_template.",
			  "wait": "1",
			  "dataSources": [
			    {
			      "namePattern": "serverLibraryTable",
			      "purpose": "original",
			      "server": "cas-shared-default",
			      "library": "SAMPLES",
			      "table": "WARRANTY_CLAIMS_0117"
			    },
			    {
			      "namePattern": "serverLibraryTable",
			      "purpose": "replacement",
			      "server": "cas-shared-default",
			      "library": "CASUSER(&SYS_COMPUTE_SESSION_OWNER.)",
			      "table": "WARRANTY_CLAIMS_0117",
			      "replacementLabel": "WARRANTY_CLAIMS_0117"
			    }
			  ],
			  "resultReportName": "Warrenty_Analysis_&selected_year.",
			  "resultParentFolderUri": "&myfolder."
			}
		'))
	out=respond
	headerout=resp_hdr
	headerout_overwrite;
    headers "Accept" = "application/vnd.sas.report.transform+json"
			"Content-Type" = "application/vnd.sas.report.transform+json" ;
run;

libname respond json;

/*Retrieve URI of new report*/
proc sql noprint;
	select "/reports/reports/"||resultReportName into :report_uri from respond.root;
quit;
%put Successful Restcall, New Report URI: &report_uri.;


/*Create Report Images*/
libname respond clear;
libname resp_hdr clear;

/*Create Report Images*/
%put Making POST call to retrieve report images;
proc http
	method="POST" oauth_bearer=sas_services
	url="&viyahost/reportImages/jobs"
	ct="application/vnd.sas.report.images.job.request+json"
	in=%unquote(%nrbquote('{
			  "reportUri": "&report_uri",
			  "version":1,
	  		  "layoutType":"entireSection",
			  "selectionType":"perSection",
			  "size":"1400x800",
			  "refresh":true
			 }
		'))
	out=respond
	headerout=resp_hdr
	headerout_overwrite;
run;

libname respond json; 
%put POST Call sent.;

/* Checking Rest Call Status */
%macro restcallstatus(running_job); 

	%let rest_call_status=running;
	%let timeout=0;

	%do %until ("&rest_call_status" ne "running" or &timeout=60); 

		%put POST Call still running since &timeout. seconds...;
		data _null_;
		   slept=sleep(1,1);
		run;

		filename restc_st temp; 
		filename res_hdr2 temp; 	
		
		proc http 
			method="GET" 
			oauth_bearer=sas_services 
			url="&viyahost/&running_job" 
			out=restc_st 
			headerout=res_hdr2 
			headerout_overwrite; 
		run; 
	
		libname restc_st json; 

		proc sql noprint;
			select state into :rest_call_status from restc_st.root;
		quit;

		filename restc_st clear; 
		libname restc_st clear; 
		%let timeout=%sysevalf(&timeout.+1);
		
	%end; 

%mend restcallstatus; 

/* RESTCall ID: */
proc sql noprint noprint;
	select "reportImages/jobs/"||id into :job_id from RESPOND.ROOT;
quit;
%put RESTCall ID: &job_id;

%restcallstatus(&job_id); 


/*Receive Report Images Feedback from POST CALL*/
data _NULL_; 
	set respond.links(where=(type="application/vnd.sas.report.images.job" and method="GET")); 
	call symputx('job_id',uri); 
run; 

libname respond clear;
proc http 
	method="GET" oauth_bearer=sas_services 
	url="&viyahost/&job_id." 
	out=respond
	headerout=resp_hdr 
	headerout_overwrite; 
run; 

libname respond json;

proc sql noprint;
	select count(*) into :numTabs from respond.IMAGES_LINKS where type="image/svg+xml";
	select uri into :uri1 - from respond.IMAGES_LINKS where type="image/svg+xml";
quit;

%put First image: &viyahost.&uri1.;

/*Iterate through all report tabs and save all*/
%macro download_images();
	%do i=1 %to &numTabs;

		filename exp_img "%sysfunc(getoption(work))/Image_&i..svg";
	
		proc http 
			method="GET" 
			oauth_bearer=sas_services 
			url="&viyahost&&uri&i." 
			ct="image/svg+xml"
			out=exp_img;
		run; 

	%end;
%mend;
%download_images;


/* Delete new data */
proc casutil outcaslib="CASUSER" ;
	droptable casdata="COSTCHANGE";
	run;
	droptable casdata="WARRANTY_CLAIMS_0117";
	run;
quit;

/* Delete temporary report */
proc http
	method="DELETE" oauth_bearer=sas_services
	url="&report_uri."
	out=respond	
	headerout=resp_hdr
	headerout_overwrite;
	headers "Accept" = "*/*";
run;

cas casauto terminate;
