-module(example).
% Returns the greeting together with the answer.
-export([answer/0]).
answer() -> {ok, "hello Erlang", 42}.
