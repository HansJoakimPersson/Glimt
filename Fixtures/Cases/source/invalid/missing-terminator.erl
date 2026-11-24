-module(totals).
-export([sum/1]).

sum([]) -> 0;
sum([H | T]) -> H + sum(T)

sum_twice(L) -> 2 * sum(L).
