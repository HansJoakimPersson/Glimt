# Summarize a numeric vector.
values <- c(3, 1, 4, 1, 5)
summary_stats <- function(x) {
  list(mean = mean(x), count = length(x))
}
print(summary_stats(values))
