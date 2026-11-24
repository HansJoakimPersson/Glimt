module example.com/observatory

go 1.24.0

toolchain go1.24.2

require (
    example.com/astronomy v1.8.3
    golang.org/x/text v0.27.0 // indirect
)

exclude example.com/old/meteor v0.4.1
replace example.com/local/orbit => ../orbit
retract [v1.2.0, v1.2.3]
