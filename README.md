# Per Core Stability Test Script
Test script developed for easier testing of Zen 3 curve offsets.  

**WARNING: Do not use if you have never run Prime95.**  
**WARNING: This script is provided as a convenience. Use at your own risk.**  
**WARNING: Use a tool such as [HWiNFO64](https://www.hwinfo.com/download) to check for safe temperatures and voltages during testing.**  
**WARNING: After completing your testing, check that Prime95 is not still running in the background.**  
**WARNING: On Ryzen CPUs, a single thread can boost to high voltages. This can potentially degrade the CPU over time.**  


## Step 1.
Download [this repository](https://github.com/jasonpoly/per-core-stability-test-script/archive/refs/heads/main.zip).

## Step 2.
Download [Prime95](http://www.mersenne.org/ftp_root/gimps/p95v303b6.win64.zip). Place the Prime95 zip file into the folder `per-core-stability-test-script`.  

## Step 3.
Go to the directory where you downloaded the repository. Right click on `p95_core_cycle.ps1` and select "Run with PowerShell."  

## All done!
That's it! The script will walk you through the rest. Further reading below.  

## Powershell Script
This script will extract, configure, and run a Prime95 on single thread using `$process.ProcessorAffinity` to assign to each cpu core for the specified time. This script assumes SMT (multithreading) is enabled. This means one core has two threads, so the process is assigned to two threads at a time.  


## Adjust the following to customize length of time to run
```
$loops      # Default = 3.   Number of times to loop arount all cores.  
$cycle_time # Default = 180. Time (seconds) to run on each core.  
$cooldown   # Default = 15.  Time (seconds) to cool down between testing each core.  
```

## Adjust next two values to limit testing to a specific range of cores
```
$first_core # Default = 0.  First core to test in each loop. Any cores lower than this number will not be tested.  
$last_core  # Default = 31. Last core to test in each loop. Any cores higher than this number will not be tested.  
```
