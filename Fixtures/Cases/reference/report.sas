/* SAS */
data work.formats;
  input name $ count;
  datalines;
glimt 3
;
run;
proc print data=work.formats; run;
