@rem = '--*-Perl-*--
@echo off
if "%OS%" == "Windows_NT" goto WinNT
perl -x -S "%0" %1 %2 %3 %4 %5 %6 %7 %8 %9
goto endofperl
:WinNT
perl -x -S %0 %*
if NOT "%COMSPEC%" == "%SystemRoot%\system32\cmd.exe" goto endofperl
if %errorlevel% == 9009 echo You do not have Perl in your PATH.
if errorlevel 1 goto script_failed_so_exit_with_non_zero_val 2>nul
goto endofperl
@rem ';
#!perl
#line 15
The bdf2gdfont.pl script will convert an X11 BDF font into a bitmapped
font that can be loaded into GD using the GD::Font->load() method.
Some restrictions apply. Run "perldoc bdf2gdfont.pl" for details.

Other scripts in this directory were designed for older versions of
libgd in which the fonts are compiled in.  Please use with care.

Lincoln Stein
Fall 2004

__END__
:endofperl
