      * Print the working-storage count.
       IDENTIFICATION DIVISION.
       PROGRAM-ID. HELLO.
       DATA DIVISION.
       WORKING-STORAGE SECTION.
       01 WS-COUNT PIC 9 VALUE 42.
       PROCEDURE DIVISION.
           DISPLAY "HELLO " WS-COUNT.
           STOP RUN.
*> End of program.
