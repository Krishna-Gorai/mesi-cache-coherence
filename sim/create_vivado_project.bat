@echo off
REM ---------------------------------------------------------------------------
REM Build the Vivado project for GUI design exploration + waveform simulation.
REM Run from the project root:  sim\create_vivado_project.bat
REM Then open  vivado_prj\mesi_coherence.xpr  in Vivado.
REM ---------------------------------------------------------------------------
setlocal
cd /d "%~dp0\.."
call vivado -mode batch -source sim\create_vivado_project.tcl -nojournal -nolog || exit /b 1
endlocal
