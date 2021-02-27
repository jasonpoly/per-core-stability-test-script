# Windows Powershell Script
# Will extract, configure and run a single thread on prime 95,
# using $process.ProcessorAffinity to assign to each cpu core for the specified time
# Assumes SMT is enabled, so one core means two threads and the process is assigned to two threads at a time
# Provided as-is and for use at your own risk.

Requires Windows10 Powershell.

WARNING: This script is provided as a convenience and use is entirely at your own risk
WARNING: On Ryzen CPUs a single thread can boost to high voltages, potentially degrading a CPU over time
WARNING: Do not use if you have never run Prime95
WARNING: Check for safe temperature and voltage on each core
WARNING: After completing your testing, check that prime95 is not still running in the background

Download p95v303b6.win64.zip from https://www.mersenne.org/download/ and place into this folder

[Optional] Open p95_core_cycle.ps1 in a text editor and edit the top few lines in case you want to change anything from the defaults:

# adjust the following to customize length of time to run
$loops=3;               # Default=3. Number of times to loop arount all cores.
$cycle_time=180;        # Default=180.  Approx time in s to run on each core.  
$cooldown=15;           # Default=15.  Time in s to cool down between testing each core.  

# adjust next two values to limit testing to a specific range of cores
$first_core=0;   # First core to test in each loop.  Default=0.  Any cores lower than this number will not be tested.
$last_core=31;   # Last core to test in each loop.  Any cores (that exist) higher than this number will not be tested.

[Optional] Edit the contents of prime.txt and local.txt to change those values

Right click on p95_core_cycle.ps1 and select "Run with PowerShell"