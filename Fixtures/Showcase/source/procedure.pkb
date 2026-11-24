CREATE OR REPLACE PACKAGE BODY greeting AS
  PROCEDURE say_hello(p_name IN VARCHAR2) IS
    v_message VARCHAR2(100);
  BEGIN
    v_message := 'Hello, ' || p_name;
    DBMS_OUTPUT.PUT_LINE(v_message);
  END say_hello;
END greeting;
/
