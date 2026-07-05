UsesCleaner
===========

A command line tool that detects and removes unused Delphi units
from uses clauses. It works by temporarily removing one unit
reference at a time, rebuilding the project with MSBuild, and
keeping only the removals that do not introduce any build error
or any new warning compared to the original (baseline) build.

When a unit of the interface uses clause cannot be removed, the
tool also tries to move it to the implementation uses clause
(recreating its surrounding conditional compilation directives
when required) and keeps the move only if the project still
compiles for all selected configurations/platforms without any
new warning.

How it works
------------

1. The tool asks for (or reads from the command line):
   * The path to a Delphi .dproj project file.
   * One or more directories containing the .pas files to process
     (a list of *.pas files can be given instead of directories).
   * The build configuration(s) to use (Debug;Release by default).
   * The target platform(s) to compile for
     (Win32;Win64;Android64;iOSDevice64;OSXARM64 by default).

2. Before modifying any file, the original project is compiled once
   for every selected configuration/platform pair. If one of those
   builds fails or emits warnings, the tool stops and reports that
   the baseline build is invalid. The spurious warning
   "failed to read line prolog at offset ..." is always ignored.

3. Both the `interface` and the `implementation` uses clauses of
   every .pas file are then normalized to the following format
   (conditional compilation directives and comments are preserved):

   ```
   uses
     System.Math,
     System.DateUtils,
     {$IF defined(ANDROID)}
     Androidapi.JNI.Net,
     Androidapi.Helpers,
     {$ENDIF}
     FMX.Forms,
     RQApp.ApiClient;
   ```

4. Every unit reference is then processed one at a time:
   * The unit reference is first removed and the project is rebuilt
     for every selected configuration/platform pair. If all the
     builds succeed without any new warning, the unit reference is
     considered unused and stays removed.
   * Otherwise, if the unit belongs to the interface uses clause,
     the tool tries to move it to the implementation uses clause
     (creating one right after the "implementation" keyword when
     the file has none) and rebuilds everything again. The move is
     kept only if all the builds succeed without any new warning.
   * Otherwise the file is restored exactly to its previous
     accepted state and the tool continues with the next unit
     reference.

5. At the end, a final full rebuild of every configuration/platform
   pair is executed to guarantee that the project still compiles
   with no new warnings.

Keeping a unit
--------------

A unit reference followed by the comment `// UsesCleaner:keep` is
never removed nor moved:

```
uses
  System.Classes, // UsesCleaner:keep
  FMX.Types, // UsesCleaner:keep
  Alcinoe.JSONDoc,
  MFApp.Page.Base;
```

Use it for units that are required at runtime but that the compiler
cannot see as used (e.g. units registering classes or components in
their initialization section).

Safety
------

* A .bak copy of every modified file can be created with
  -CreateBackup=true (disabled by default).
* Before processing a file, the tool injects a temporary syntax
  error in it and verifies that at least one build fails. This
  guarantees that the file really belongs to the project (if it
  did not, every removal would wrongly succeed).
* Compiler directives ({$IF ...}, {$IFDEF ...}, {$IFNDEF ...},
  {$ELSE}, {$ELSEIF ...}, {$ENDIF}, ...) are never removed nor
  corrupted. When a unit nested inside conditional compilation
  directives is moved to the implementation uses clause, its
  surrounding directives are recreated around it. The last unit
  of a clause that still contains directives or comments is never
  removed.

Usage
-----

```
  UsesCleaner.exe
    -Project=The path to the .dproj project file.
    -Sources=The directories and/or *.pas files to process. Separate items with ";".
    -Configs=The build configuration(s) to use. Default: Debug;Release
    -Platforms=The target platform(s) to compile for. Default: Win32;Win64;Android64;iOSDevice64;OSXARM64
    -RsVars=The path to rsvars.bat. Default: auto-detected from the registry.
    -CreateBackup=true or false. Create a .bak file before modifying a file. Default: false
```

When a parameter is missing, the tool asks for it interactively.

Example
-------

```
  UsesCleaner.exe^
    -Project="c:\MyProject\MyProject.dproj"^
    -Sources="c:\MyProject\Source"^
    -Configs="Debug;Release"^
    -Platforms="Win32;Win64"
```

Note: the tool can be slow on big projects since every candidate
removal or move triggers one incremental MSBuild compilation per
selected configuration/platform pair. Remember that a unit can be
used on one platform only, so the final cleaning should always be
done with every configuration/platform the project supports.
