@echo off
setlocal
where cl >nul 2>nul
if errorlevel 1 (
  echo Run this from a Visual Studio Developer Command Prompt for VS 2022.
  exit /b 1
)
if not exist openvr\headers\openvr_driver.h (
  echo Missing openvr headers. Clone ValveSoftware/openvr into .\openvr first.
  exit /b 1
)
if not exist bin\win64 mkdir bin\win64
cl /nologo /std:c++17 /EHsc /LD /I openvr\headers driver.cpp /link /OUT:bin\win64\driver_iPhoneVR.dll Ws2_32.lib
if errorlevel 1 exit /b 1
echo Built bin\win64\driver_iPhoneVR.dll
