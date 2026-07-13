@echo off
REM ---------------------------------------------------------------------------
REM Compile + run both M2 tests in Vivado xsim:
REM   tb_coherent_system : stable-transition regression (from M1)
REM   tb_race            : concurrent-request race resolution
REM Run from the project root:  sim\run_m2.bat
REM ---------------------------------------------------------------------------
setlocal
cd /d "%~dp0\.."

call xvlog -sv rtl\mesi_pkg.sv rtl\main_memory.sv rtl\l1_cache.sv ^
                rtl\snoop_bus.sv rtl\bus_monitor.sv rtl\coherent_system.sv ^
                tb\tb_coherent_system.sv tb\tb_race.sv || exit /b 1

echo ===== regression: tb_coherent_system =====
call xelab -debug typical -timescale 1ns/1ps tb_coherent_system -s tb_reg || exit /b 1
call xsim tb_reg -R || exit /b 1

echo ===== races: tb_race =====
call xelab -debug typical -timescale 1ns/1ps tb_race -s tb_race || exit /b 1
call xsim tb_race -R || exit /b 1

endlocal
