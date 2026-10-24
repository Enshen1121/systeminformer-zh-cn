@echo off
setlocal
set "SI_ARCH=%~1"
if "%SI_ARCH%"=="" set "SI_ARCH=x64"
if "%SI_ARCH%"=="x64" (set "SI_VCARCH=amd64") else if "%SI_ARCH%"=="x86" (set "SI_VCARCH=x86") else (echo Supported: x64 or x86&exit /b 1)
set "SI_VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
set "PATH=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer;%PATH%"
if not exist "%SI_VSWHERE%" (echo Visual Studio Build Tools not found&exit /b 1)
for /f "usebackq tokens=*" %%i in (`"%SI_VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "SI_VS=%%i"
if not defined SI_VS (echo C++ build tools not found&exit /b 1)
call "%SI_VS%\VC\Auxiliary\Build\vcvarsall.bat" %SI_VCARCH% >nul
if errorlevel 1 exit /b %errorlevel%
set "SI_ROOT=%~dp0.."
if not exist "%SI_ROOT%\build\%SI_ARCH%" mkdir "%SI_ROOT%\build\%SI_ARCH%"
set "TEMP=%SI_ROOT%\build\%SI_ARCH%"
set "TMP=%TEMP%"
pushd "%TEMP%"
cl /nologo /std:c17 /utf-8 /W4 /WX /MT /O2 /GS /guard:cf /LD "%SI_ROOT%\src\localization-plugin\plugin.c" "%SI_ROOT%\src\localization-plugin\zh_ui.c" /Fe:"%SI_ROOT%\payload\%SI_ARCH%\ZhLocalization.dll" /link /IMPLIB:ZhLocalization.lib user32.lib comctl32.lib version.lib /DYNAMICBASE /NXCOMPAT /guard:cf
if errorlevel 1 (popd&exit /b 1)
cl /nologo /std:c17 /utf-8 /W4 /WX /MT /O2 /GS /guard:cf /D_WIN32_WINNT=0x0A00 /LD "%SI_ROOT%\src\third-party\third_party.c" /Fe:"%SI_ROOT%\payload\%SI_ARCH%\ThirdPartyManager.dll" /link /IMPLIB:ThirdPartyManager.lib user32.lib comctl32.lib version.lib shell32.lib gdi32.lib /DYNAMICBASE /NXCOMPAT /guard:cf
if errorlevel 1 (popd&exit /b 1)
popd
exit /b 0
