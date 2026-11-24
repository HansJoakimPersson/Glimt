REPORT z_hello.
DATA lv_count TYPE i VALUE 3.
* Kommentar
DO lv_count TIMES.
  WRITE: / 'Hej', sy-index.
ENDDO.
