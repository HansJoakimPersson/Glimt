@echo off
if exist build (
    echo Cleaning build
    rmdir /s /q build
set TARGET="release
