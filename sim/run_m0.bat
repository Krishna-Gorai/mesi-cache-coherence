@echo off
REM ---------------------------------------------------------------------------
REM Compile + elaborate + run the M0 L1-cache sanity test in Vivado xsim.
REM Run from the project root:  sim\run_m0.bat
REM (Requires the Vivado bin directory on PATH: xvlog / xelab / xsim.)
REM ---------------------------------------------------------------------------
setlocal
cd /d "%~dp0\.."

call xvlog -sv rtl\mesi_pkg.sv rtl\main_memory.sv rtl\l1_cache.sv tb\tb_l1_cache.sv || exit /b 1
call xelab -debug typical -timescale 1ns/1ps tb_l1_cache -s tb_sim || exit /b 1
call xsim tb_sim -R || exit /b 1

endlocal
