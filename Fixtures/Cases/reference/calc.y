%{
#include <stdio.h>
%}
%token NUMBER
%%
expr: expr '+' term { $$ = $1 + $3; }
    | term
    ;
term: NUMBER ;
%%
