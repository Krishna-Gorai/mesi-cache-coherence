@echo off
REM ---------------------------------------------------------------------------
REM Compile + run the M3 randomized 4-core coherence stress test in Vivado xsim.
REM The bus_monitor (invariant + golden data-value checker) runs inside the DUT.
REM Run from the project root:  sim\run_m3.bat
REM ---------------------------------------------------------------------------
setlocal
cd /d "%~dp0\.."

call xvlog -sv rtl\mesi_pkg.sv rtl\main_memory.sv rtl\l1_cache.sv ^
                rtl\snoop_bus.sv rtl\bus_monitor.sv rtl\coherent_system.sv ^
                tb\tb_stress.sv || exit /b 1
call xelab -debug typical -timescale 1ns/1ps tb_stress -s tb_stress || exit /b 1
call xsim tb_stress -R || exit /b 1

endlocal
