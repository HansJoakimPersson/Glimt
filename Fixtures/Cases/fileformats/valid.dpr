{ Pascal and Delphi share Object Pascal syntax. }
program CounterDemo;

type
  TCounter = record
    Value: Integer;
  end;

var
  Counter: TCounter;

begin
  Counter.Value := 42;
  WriteLn('The answer is ', Counter.Value);
end.
