; CLIPS
(deftemplate person (slot name))
(defrule greet
   (person (name ?n))
   =>
   (printout t "Hej " ?n crlf))
