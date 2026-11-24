CREATE FUNCTION py_max (a integer, b integer) RETURNS integer AS $$
    return max(a, b)
$$ LANGUAGE plpython3u;
