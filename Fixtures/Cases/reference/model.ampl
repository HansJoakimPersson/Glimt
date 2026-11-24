set PRODUCTS;
param price {PRODUCTS} > 0;
var Make {p in PRODUCTS} >= 0;
# objective
maximize Profit: sum {p in PRODUCTS} price[p] * Make[p];
subject to Capacity: sum {p in PRODUCTS} Make[p] <= 40;
