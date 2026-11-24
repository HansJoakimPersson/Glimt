function result = analysis(values)
% Analyze a numeric vector and return its sample statistics.
arguments
    values (1,:) double
end
result.mean = mean(values);
result.samples = numel(values);
end
