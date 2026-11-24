%{ /* å %% %} */ %}
%code
{
  const char *section = "%% }";
}
%token WORD
%printer { $$ } <*>
%%
start: 'x' { { $1; @$; } /* } %% */ } | 'y';
%%
/* Epilogue is intentionally plain. */
int generated_parser_is_not_compiled;
