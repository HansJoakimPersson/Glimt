-- Active users with a score of at least 42.
SELECT id, display_name
FROM users
WHERE active = TRUE AND score >= 42
ORDER BY display_name;
