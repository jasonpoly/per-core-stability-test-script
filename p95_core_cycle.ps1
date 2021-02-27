# MIT License
# 
# Copyright (c) 2021 jasonpoly
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.


# Windows Powershell Script
# Will extract, configure and run a single thread on prime 95,
# using $process.ProcessorAffinity to assign to each cpu core for the specified time

$p95path="p95v303b6.win64.zip"; # path to p95 .zip you want to extract and use

# adjust the following to customize length of time to run
$core_loop_test=$true;    # Default=$true.  Basic test to loop around all cores.  Set to $falue to disable. 
$loops=3;                 # Default=3. Number of times to loop around all cores.
$cycle_time=180;          # Default=180.  Approx time in s to run on each core.  
$cooldown=15;             # Default=15.  Time in s to cool down between testing each core.  

# adjust next two values to limit testing to a specific range of cores
$first_core=0;   # First core to test in each loop.  Default=0.  Any cores lower than this number will not be tested.
$last_core=31;   # Last core to test in each loop.  Any cores (that exist) higher than this number will not be tested.
                 # Will automaticlly get adjusted down to the actual number of detected cores.
                 # Default and MAX value=31.  Cores 32 or higher will result in an Error: "Arithmetic operation resulted in an overflow."

# additional settings
$stop_on_error=$false; # Default=$false.  $true will stop if an error is found, otherwise skip to the next core. 
$timestep=10;          # Minimum time to run stress test.  Will check for errors every this many seconds.
$use_smt=$true;        # Default=$true.  $false will only enable one thread on each physical core even if SMT (Hyperthreading) is enabled on the system.

# After extracting, we will add the following lines to local.txt for single thread, non-AVX test
#     NumCPUs=1
#     CpuNumHyperthreads=1
#     CpuSupportsAVX=0
#     CpuSupportsAVX2=0
#     CpuSupportsAVX512F=0
# Add the following lines to prime.txt for stress test with FFT size of 84
#     StressTester=1
#     UsePrimenet=0
#     MinTortureFFT=84
#     MaxTortureFFT=84
#     TortureMem=8
#     TortureTime=3

filter timestamp {"$(Get-Date -Format G): $_"}

if ($PSScriptRoot)
{
    $work_dir="$PSScriptRoot"
}
else
{
    $work_dir="."
}


###################################################################
# Functions
###################################################################

function Write-Log ($msg)
{
    Write-Output $msg | timestamp
    $msg | timestamp >> "$work_dir\cycle.log"
}

function Clean-p95-Results ($test)
{
    Write-Log "Moving any previous results into ${test}.prev.results\"
    if (Test-Path "$work_dir\${test}.core*failure.txt")
    {
        rmdir "$work_dir\${test}.prev.results" -Recurse -Force -ErrorAction SilentlyContinue        
        mkdir "$work_dir\${test}.prev.results" -ErrorAction SilentlyContinue
        mv "$work_dir\${test}.core*_failure.txt" "$work_dir\${test}.prev.results"
    }
    if (Test-Path "$work_dir\p95\results.txt")
    {
        mv "$work_dir\p95\results.txt" "$work_dir\p95\prev.results.txt"
    }
}

function Set-Affinity 
{
    param (
        [Parameter(Mandatory=$true)]$CPUCore, 
        [Parameter(Mandatory=$true)]$ProcessName
    )

    $time_out=10

    $starttime=(GET-DATE)
    $runtime=0

    while ( ($runtime -lt $time_out) -and (Get-Process -Name $ProcessName -ErrorAction SilentlyContinue).Count -eq 0 )
    {        
        Start-Sleep -Milliseconds 100
        $runtime = (NEW-TIMESPAN –Start $starttime –End (GET-DATE)).TotalSeconds
    }

    if ($runtime -ge $time_out)
    {
        Write-Log "!!!! =================================================== !!!!"
        Write-Log "!!!! ERROR Timed out waiting for $ProcessName to start  !!!!"
        Write-Log "!!!! =================================================== !!!!"
        Write-Output 0
    }
    else
    {
        if ($smt_enabled)
        {
            if ($use_smt) 
            { 
                [Int64]$affinity=[Math]::Pow(2, $CPUCore*2) + [Math]::Pow(2, $CPUCore*2+1) 
            }
            else 
            {
                [Int64]$affinity=[Math]::Pow(2, $CPUCore*2)
            }
        }
        else
        {
            [Int64]$affinity=[Math]::Pow(2, $CPUCore)
        }

        $process=Get-Process prime95
        $process.ProcessorAffinity=[System.IntPtr]$affinity
        Write-Output $process
    }
}

function Wait-prime95
{
    param (
        [Parameter(Mandatory=$true)]$CPUCore, 
        [Parameter(Mandatory=$true)]$WaitTime,
        [Parameter(Mandatory=$true)]$Loop
    )

    # wait for p95 to run for $cycle_time, as long as there is no error, and no failure in a previous loop
    $runtime=0
    $p95result=""
    $starttime=(GET-DATE)
    while ( ($runtime -lt $WaitTime) -and (-not($p95result)) -and ((Test-Path "$work_dir\core${CPUCore}_loop*_failure.txt") -eq $false) -and ($process.HasExited -eq $false) )
    {
        Start-Sleep -Seconds $timestep
        $p95result = if (Test-Path "$work_dir\p95\results.txt") {Select-String "$work_dir\p95\results.txt" -Pattern ERROR}
        $runtime = (NEW-TIMESPAN –Start $starttime –End (GET-DATE)).TotalSeconds
    }

    if ($p95result)
    {
        Write-Log "!!!! ============================================= !!!!"
        Write-Log "!!!! Test FAILED on core $CPUCore.                    !!!!"
        Write-Log "!!!! Check core${CPUCore}_loop${Loop}_failure.txt        !!!!"
        Write-Log "!!!! ============================================= !!!!"
        Write-Log "$p95result"
        mv "$work_dir\p95\results.txt" "$work_dir\${test}.core${CPUCore}_loop${Loop}_failure.txt"
        if ($stop_on_error) 
        { 
            $process.CloseMainWindow()
            $process.Close()
            Wait-Event 
        }
    } 
    elseif ($process.HasExited -ne $false)
    {
        Write-Log "!!!! ============================================= !!!!"
        Write-Log "!!!! Prime95 process closed unexpectedly           !!!!"
        Write-Log "!!!! Test FAILED on core $CPUCore.                    !!!!"
        Write-Log "!!!! Check core${CPUCore}_loop${Loop}_failure.txt        !!!!"
        Write-Log "!!!! ============================================= !!!!"
        Write-Log "$p95result"
        if (Test-Path "$work_dir\p95\results.txt") 
        {
            mv "$work_dir\p95\results.txt" "$work_dir\${test}.core${CPUCore}_loop${Loop}_failure.txt"
        }
        else
        {
            "Prime95 process closed unexpectedly" >> "$work_dir\${test}.core${CPUCore}_loop${Loop}_failure.txt"
        }
        if ($stop_on_error) 
        { 
            $process.CloseMainWindow()
            $process.Close()
            Wait-Event 
        }
    }
    else
    {
        Write-Log "Test passed on core $CPUCore."            
    }
}

###################################################################
# Main Script
###################################################################

Write-Log "Writing log to $work_dir\cycle.log"

if (Test-Path "$work_dir\$p95path")
{
    if (!(Test-Path "$work_dir\p95"))
    {
        Write-Log "Extracting prime95 from $p95path"
        Expand-Archive -LiteralPath "$p95path" -DestinationPath p95 -ErrorAction SilentlyContinue
    }
    else
    {
        Write-Log "Using previously extracted p95 found in $work_dir\p95"
    }
}
else
{
    Write-Log "!!!! ============================================= !!!!"
    Write-Log "!!!! $work_dir\$p95path not found    "
    Write-Log "!!!! Download and copy this into $work_dir"
    Write-Log "!!!! ============================================= !!!!"    
    Wait-Event    
    exit
}

Write-Log "Configuring prime95 for single core, non-AVX torture test"
cp "$work_dir\local.txt" "$work_dir\p95\"
cp "$work_dir\prime.txt" "$work_dir\p95\"

# Figure out how many cores we have an if SMT (Hyperthreading) is enabled or disabled
# We will then stress one core at a time, but use both threads on that core if SMT is enabled
$NumberOfLogicalProcessors = Get-WmiObject Win32_Processor | Measure -Property  NumberOfLogicalProcessors -Sum
$NumberOfCores = Get-WmiObject Win32_Processor | Measure -Property  NumberOfCores -Sum
if ( ($NumberOfCores.Sum * 2) -eq $NumberOfLogicalProcessors.Sum )
{
    Write-Log "Detected $($NumberOfCores.Sum) cores and $($NumberOfLogicalProcessors.Sum) threads.  SMT is enabled"
    if ($use_smt -eq $true)
    {
        Write-Log "    use_smt=$true Using 2 threads per core"
    }
    else
    {
        Write-Log "    use_smt=$fales Using 1 thread per core"
    }

    $smt_enabled=$true
}
elseif ( $NumberOfCores.Sum -eq $NumberOfLogicalProcessors.Sum )
{
    Write-Log "Detected $($NumberOfCores.Sum) cores and $($NumberOfLogicalProcessors.Sum) threads.  SMT is disabled"
    $smt_enabled=$false
}
else
{
    Write-Log "!!!! =========================================================================== !!!!"
    Write-Log "!!!! ERROR detected $NumberOfCores cores and $NumberOfLogicalProcessors threads. !!!!"
    Write-Log "!!!! This script only supports 1 or 2 threads per core                           !!!!"
    Write-Log "!!!! =========================================================================== !!!!"    
    $fatal_error=$true
}

if ($last_core -ge $NumberOfCores.Sum)
{
    $last_core = $NumberOfCores.Sum-1
}

if ((Get-Process -Name prime95 -ErrorAction SilentlyContinue).Count -gt 0)
{
    Write-Log "!!!! ============================================= !!!!"
    Write-Log "!!!! ERROR Prime95 is already running              !!!!"
    Write-Log "!!!! ============================================= !!!!"
    $fatal_error=$true
}

if ( ($fatal_error -eq $false) -and ($core_loop_test -eq $true) )
{
    $test="core_loop_test"
    Write-Log "Starting loop test on cores $first_core through $last_core"

    Clean-p95-Results ($test)

    Write-Log "Looping $loops times around all cores"

    $first_run=1

    for ($i=1; $i -le $loops; $i++)
    {
        Write-Log "Loop $i out of $loops"
        for ($core=$first_core; $core -le $last_core; $core++)
        {
            # skip testing if this core already failied in an earlier loop
            if (Test-Path "$work_dir\${test}.core${core}_loop*_failure.txt")
            {
                Write-Log "!!!! ============================================= !!!!"
                Write-Log "!!!! Skipping core ${core} due to previous failure !!!!"
                Write-Log "!!!! ============================================= !!!!"
            }
            else
            {
                $timer=0
                $p95result=""
                
                # Don't cool down before the first test
                if ($first_run -eq 1)
                {
                    $first_run= 0
                }
                else
                {
                    Write-Log "Cooling down for $cooldown seconds"
                    Start-Sleep -Seconds $cooldown
                }

                Write-Log "Starting $cycle_time second torture test on core $core"
                
                # Start stress test
                Start-Process -FilePath "$work_dir\p95\prime95.exe" -ArgumentList "-T" -WindowStyle Minimized

                $process=Set-Affinity -CPUCore $core -ProcessName "prime95"

                Wait-prime95 -CPUCore $core -WaitTime $cycle_time -Loop $i

                if ( ($process -ne 0) -and ($process.HasExited -eq $false) )
                {
                    if ($process.CloseMainWindow() -eq $fales)
                    {
                        $process.Kill()
                    }
                    Write-Log "Waiting for prime95 to close"
                    Wait-Process -Id $process.Id -ErrorAction SilentlyContinue
                    $process.Close()
                }
            }
        }
    }
}

if ( $fatal_error -eq $true)
{
    Write-Log ""    
    Write-Log "Script encountered an error.  Resolve and retry"
}
else
{
    Write-Log ""
    Write-Log "Testing complete."
    Write-Log "Check log at $work_dir\cycle.log for any failures"
}
Wait-Event

