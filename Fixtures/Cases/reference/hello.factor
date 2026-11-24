USING: io kernel math sequences ;
IN: hello

! Factor
: greet ( n -- ) [ "Hej" print ] times ;
3 greet
