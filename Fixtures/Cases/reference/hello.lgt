:- object(hello).

	:- public(greet/1).
	% Logtalk
	greet(Name) :-
		write('Hej '), write(Name), nl.

:- end_object.
