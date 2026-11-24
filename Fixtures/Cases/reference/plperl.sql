CREATE FUNCTION perl_max (integer, integer) RETURNS integer AS $$
    my ($x, $y) = @_;
    return $x > $y ? $x : $y;
$$ LANGUAGE plperl;
