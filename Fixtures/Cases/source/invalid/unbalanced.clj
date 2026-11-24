(ns glimt.totals)

(defn total [items]
  (reduce + (map :price items))

(println (total [{:price 2} {:price 3}]))
