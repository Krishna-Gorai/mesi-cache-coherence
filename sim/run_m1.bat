@echo off
REM ---------------------------------------------------------------------------
REM Compile + elaborate + run the M1 two-core coherence test in Vivado xsim.
REM Run from the project root:  sim\run_m1.bat
REM (Requires the Vivado bin directory on PATH: xvlog / xelab / xsim.)
REM ---------------------------------------------------------------------------
setlocal
cd /d "%~dp0\.."

call xvlog -sv rtl\mesi_pkg.sv rtl\main_memory.sv rtl\l1_cache.sv ^
                rtl\snoop_bus.sv rtl\bus_monitor.sv rtl\coherent_system.sv ^
                tb\tb_coherent_system.sv || exit /b 1
call xelab -debug typical -timescale 1ns/1ps tb_coherent_system -s tb_m1 || exit /b 1
call xsim tb_m1 -R || exit /b 1

endlocal
