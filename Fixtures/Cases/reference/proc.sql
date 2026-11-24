-- PL/SQL
CREATE OR REPLACE PROCEDURE greet(p_name IN VARCHAR2) IS
  v_count PLS_INTEGER := 3;
BEGIN
  FOR i IN 1 .. v_count LOOP
    DBMS_OUTPUT.PUT_LINE('Hej ' || p_name);
  END LOOP;
END greet;
/
