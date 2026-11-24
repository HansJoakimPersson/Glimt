/^ERROR/ { errors++ }
/^WARN { warnings++
END { print errors, warnings }
