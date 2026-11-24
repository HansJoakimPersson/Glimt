model Tank "Enkel tank"
  parameter Real area = 1.0;
  Real level(start = 0.5);
  input Real inflow;
equation
  area * der(level) = inflow;
end Tank;
