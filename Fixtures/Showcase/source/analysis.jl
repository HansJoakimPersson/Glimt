# Summarize a vector of values.
function summarize(values)
    message = "Glimt"
    return (mean = sum(values) / length(values), label = message, answer = 42)
end

println(summarize([1, 2, 3]))
