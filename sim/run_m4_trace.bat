@echo off
REM ---------------------------------------------------------------------------
REM Compile + run the M4 annotated protocol trace in Vivado xsim. Prints a
REM Markdown table walking a line through the full MESI lifecycle and writes
REM trace.vcd. Run from the project root:  sim\run_m4_trace.bat
REM ---------------------------------------------------------------------------
setlocal
cd /d "%~dp0\.."

call xvlog -sv rtl\mesi_pkg.sv rtl\main_memory.sv rtl\l1_cache.sv ^
                rtl\snoop_bus.sv rtl\coherent_system.sv ^
                tb\tb_trace.sv || exit /b 1
call xelab -debug typical -timescale 1ns/1ps tb_trace -s tb_trace || exit /b 1
call xsim tb_trace -R || exit /b 1

endlocal
