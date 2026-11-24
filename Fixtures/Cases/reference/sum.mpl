# Maple
f := proc(n::posint)
    local i;
    add(i^2, i = 1 .. n);
end proc;
f(3);
