@echo off
pushd %~dp0
powershell -executionPolicy remoteSigned -command .\build.ps1 %*
popd
exit /b %ERRORLEVEL%