#!/bin/csh
set files = (*.log)
foreach f ($files)
    if (-z $f) then
        echo "empty: $f
end
