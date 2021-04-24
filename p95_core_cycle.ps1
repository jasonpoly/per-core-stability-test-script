# Windows Powershell Script
# Will extract, configure, and run a Prime95 on asingle thread using
# $process.ProcessorAffinity to assign to each cpu core for the specified time

$p95path="p95v303b6.win64.zip"; # path to p95.zip you want to extract and use
$core_failure = @()

# Customize length of time to run
$core_loop_test=$true;    # Default=$true. Basic test to loop around all cores.  Set to $falue to disable. 
$loops=3;                 # Default=3.     Number of times to loop arount all cores.
$cycle_time=180;          # Default=180.   Time (seconds) to run on each core.
$cooldown=5;              # Default=5.     Time (seconds) to cool down between testing each core.

$core_jumping_test=$true;      # Default=$true. Test to move process from core to core.  Set to $falue to disable.
$core_jumping_loops=5;         # Default=5.     Number of loops to run.
$core_jumping_cycle_time=10;   # Default=10.    Approx time in s to run on each core.  

# Limit testing to a specific range of cores
$first_core=0;   # Default=0.  First core to test in each loop. Any cores lower than this will not be tested.
$last_core=31;   # Default=31. Last core to test in each loop. Any cores higher than this will not be tested.
                 # Will automatically get adjusted down to the actual number of detected cores.
                 # Cores 32 or higher will result in an Error: "Arithmetic operation resulted in an overflow."

# Additional settings
$stop_on_error=$false; # Default=$false.   $true will stop if an error is found, otherwise skip to the next core. 
$timestep=1;           # Min time to run.  Will check for errors every this many seconds.
$use_smt=$true;        # Default=$true.    $false will only enable one thread on each physical core even if SMT (Hyperthreading) is enabled on the system.
$fatal_error=$false;   # Default=$false.   Script sets this to true if there is an unrecoverable error. Any subsequent tests will then be skipped.

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
    Write-Log "Moving any previous results into ${test}.prev.results"
    if (Test-Path "$work_dir\${test}.core*failure.txt")
    {
        mkdir "$work_dir\${test}.prev.results" -ErrorAction SilentlyContinue
        mv -Force "$work_dir\${test}.core*_failure.txt" "$work_dir\${test}.prev.results"
    }
    if (Test-Path "$work_dir\p95\results.txt")
    {
        mv -Force "$work_dir\p95\results.txt" "$work_dir\p95\prev.results.txt"
    }
	Write-Log "*****************************************************"
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
    while (($runtime -lt $time_out) -and (Get-Process -Name $ProcessName -ErrorAction SilentlyContinue).Count -eq 0)
    {
        Start-Sleep -Milliseconds 100
        $runtime=(NEW-TIMESPAN –Start $starttime –End (GET-DATE)).TotalSeconds
    }
    if ($runtime -ge $time_out)
    {
        Write-Log "!!! ============================================= !!!"
        Write-Log "!!! ERROR: Timed out waiting for $ProcessName to start  !!!"
        Write-Log "!!! ============================================= !!!"
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


function p95-Error
{
    param (
        [Parameter()]$p95result,
        [Parameter(Mandatory=$true)]$process,
        [Parameter(Mandatory=$true)]$CPUCore,
        [Parameter(Mandatory=$true)]$Loop
    )
    if ($p95result)
    {
        Write-Log "!!! ============================================= !!!"
        Write-Log "!!! Test FAILED on core $CPUCore.                        !!!"
        Write-Log "!!! Check core${CPUCore}_loop${Loop}_failure.txt                 !!!"
        Write-Log "!!! ============================================= !!!"
        Write-Log "$p95result"
		$core_failure += "$CPUCore"
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
        Write-Log "!!! ============================================= !!!"
        Write-Log "!!! Prime95 process closed unexpectedly           !!!"
        Write-Log "!!! Test FAILED on core $CPUCore.                        !!!"
        Write-Log "!!! Check core${CPUCore}_loop${Loop}_failure.txt                 !!!"
        Write-Log "!!! ============================================= !!!"
        Write-Log "$p95result"
		$core_failure += "$CPUCore"
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
}


function Wait-prime95
{
    param (
        [Parameter(Mandatory=$true)]$CPUCore,
        [Parameter(Mandatory=$true)]$WaitTime,
        [Parameter(Mandatory=$true)]$Loop
    )
    # Wait for p95 to run for $cycle_time, as long as there is no error, and no failure in a previous loop
    $runtime=0
    $p95result=""
    $starttime=(GET-DATE)
    while (($runtime -lt $WaitTime) -and (-not($p95result)) -and ((Test-Path "$work_dir\core${CPUCore}_loop*_failure.txt") -eq $false) -and ($process.HasExited -eq $false))
    {
        Start-Sleep -Seconds $timestep
        $p95result=if (Test-Path "$work_dir\p95\results.txt") {Select-String "$work_dir\p95\results.txt" -Pattern ERROR}
        $runtime=(NEW-TIMESPAN –Start $starttime –End (GET-DATE)).TotalSeconds
    }
    if ($p95result)
    {
        p95-Error -p95result $p95result.Line -process $process -CPUCore $CPUCore -Loop $Loop
    }
    elseif ($process.HasExited -ne $false)
    {
        p95-Error -p95result $p95result.Line -process $process -CPUCore $CPUCore -Loop $Loop
    }
    else
    {
        Write-Log "Test passed on core $CPUCore."
    }
}


function Exit-Process
{
    param (
        [Parameter(Mandatory=$true)]$Process, 
        [Parameter(Mandatory=$true)]$ProcessName
    )

    if (($Process -ne 0) -and ($Process.HasExited -eq $false))
    {
        if ($Process.CloseMainWindow() -eq $fales)
        {
            $Process.Kill()
        }
        Write-Log "Waiting for $ProcessName to close."
        Wait-Process -Id $Process.Id -ErrorAction SilentlyContinue
        $Process.Close()
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
        Write-Log "Extracting Prime95 from $p95path"
        Expand-Archive -LiteralPath "$p95path" -DestinationPath p95 -ErrorAction SilentlyContinue
    }
    else
    {
        Write-Log "Using previously extracted Prime95 found in $work_dir\p95"
    }
}
else
{
    Write-Log "!!! ============================================= !!!"
    Write-Log "!!! $work_dir\$p95path not found"
    Write-Log "!!! Download Prime95 and copy it to into $work_dir"
    Write-Log "!!! ============================================= !!!"
    Wait-Event    
    exit
}

Write-Log "Configuring Prime95 for single core, non-AVX torture test"
cp "$work_dir\local.txt" "$work_dir\p95\"
cp "$work_dir\prime.txt" "$work_dir\p95\"

# Figure out how many cores we have an if SMT is enabled or disabled.
# We will then stress one core at a time, but use both threads on that core if SMT is enabled
$NumberOfLogicalProcessors=Get-WmiObject Win32_Processor | Measure -Property  NumberOfLogicalProcessors -Sum
$NumberOfCores=Get-WmiObject Win32_Processor | Measure -Property  NumberOfCores -Sum
if (($NumberOfCores.Sum * 2) -eq $NumberOfLogicalProcessors.Sum)
{
    Write-Log "Detected $($NumberOfCores.Sum) cores and $($NumberOfLogicalProcessors.Sum) threads. SMT is enabled."
    if ($use_smt -eq $true)
    {
        Write-Log "use_smt=$true. Using 2 threads per core."
    }
    else
    {
        Write-Log "use_smt=$false. Using 1 thread per core."
    }
    $smt_enabled=$true
}
elseif ($NumberOfCores.Sum -eq $NumberOfLogicalProcessors.Sum)
{
    Write-Log "Detected $($NumberOfCores.Sum) cores and $($NumberOfLogicalProcessors.Sum) threads. SMT is disabled."
    $smt_enabled=$false
}
else
{
    Write-Log "!!! ============================================= !!!"
    Write-Log "!!! ERROR detected $NumberOfCores cores and $NumberOfLogicalProcessors threads. !!!"
    Write-Log "!!! This script only supports 1 or 2 threads per core !!!"
    Write-Log "!!! ============================================= !!!"
    $fatal_error=$true
}

if ($last_core -ge $NumberOfCores.Sum)
{
    $last_core=$NumberOfCores.Sum-1
}

if ((Get-Process -Name prime95 -ErrorAction SilentlyContinue).Count -gt 0)
{
    Write-Log "!!! ============================================= !!!"
    Write-Log "!!! ERROR Prime95 is already running              !!!"
    Write-Log "!!! ============================================= !!!"
    $fatal_error=$true
}

if (($fatal_error -eq $false) -and ($core_loop_test -eq $true))
{
    $test="core_loop_test"
	Write-Log ""
	Write-Log ""
    Write-Log "Starting looping test on cores $first_core through $last_core."
    Clean-p95-Results ($test)
    Write-Log "Looping $loops times around all cores."
    $first_run=1
    for ($i=1; $i -le $loops; $i++)
    {
		Write-Log "*****************************************************"
        Write-Log "Starting loop $i out of $loops."
        for ($core=$first_core; $core -le $last_core; $core++)
        {
            # Skip testing if this core already failied in an earlier loop
            if (Test-Path "$work_dir\*.core${core}_loop*_failure.txt")
            {
                Write-Log "!!! ============================================= !!!"
                Write-Log "!!! Skipping core ${core} due to previous failure.      !!!"
                Write-Log "!!! ============================================= !!!"
            }
            else
            {
                $timer=0
                $p95result=""
                if ($first_run -eq 1) # Do not cool down before the first test
                {
                    $first_run=0
                }
                else
                {
                    Write-Log "Cooling down for $cooldown seconds."
                    Start-Sleep -Seconds $cooldown
                }
				Write-Log "*****************************************************"
                Write-Log "Starting $cycle_time second torture test on core $core."
                # Start stress test
                Start-Process -FilePath "$work_dir\p95\prime95.exe" -ArgumentList "-T" -WindowStyle Minimized
                $process=Set-Affinity -CPUCore $core -ProcessName "prime95"
                Wait-prime95 -CPUCore $core -WaitTime $cycle_time -Loop $i
                Exit-Process -Process $process -ProcessName "prime95"
            }
        }
    }
}

if (($fatal_error -eq $false) -and ($core_jumping_test -eq $true))
{
    $test="core_jumping_test"
    $loops=$core_jumping_loops
    $cycle_time=$core_jumping_cycle_time
    [int]$prev_core=-1
    [int]$core=-1
	Write-Log ""
	Write-Log ""
    Write-Log "Starting core jumping test on cores $first_core through $last_core."
    Clean-p95-Results ($test)
    for ($i=1; $i -le $loops; $i++)
    {
		Write-Log "*****************************************************"
        Write-Log "Starting loop $i out of $loops."
        for ($j=$first_core; $j -le $last_core; $j++)
        {
            # randomly pick a new core to start or move to
            while ($core -eq $prev_core) {$core=Get-Random -Minimum $first_core -Maximum $last_core}
            # skip testing if this core already failied in an earlier loop
            if (Test-Path "$work_dir\*.core${core}_loop*_failure.txt")
            {
                Write-Log "!!! ============================================= !!!"
                Write-Log "!!! Skipping core ${core} due to previous failure.      !!!"
                Write-Log "!!! ============================================= !!!"
            }
            else
            {
                $timer=0
                $p95result=""
                Write-Log "Starting $cycle_time second torture test on core $core"
                # Start or re-start stress test
                if ((Get-Process -Name prime95 -ErrorAction SilentlyContinue).Count -eq 0)
                {
                    Start-Process -FilePath "$work_dir\p95\prime95.exe" -ArgumentList "-T" -WindowStyle Minimized
                }
                $process=Set-Affinity -CPUCore $core -ProcessName "prime95"
                Start-Sleep -Milliseconds 100
                $p95result=if (Test-Path "$work_dir\p95\results.txt") {Select-String "$work_dir\p95\results.txt" -Pattern ERROR}
                if ($p95result)
                {
                    if ($prev_core -gt -1)
                    {
                        Write-Log "!!! ============================================= !!!"
                        Write-Log "!!! Warning! Test failed within 100 ms.           !!!"
						Write-Log "!!! Previous core $prev_core might not be stable          !!!"
                        Write-Log "!!! ============================================= !!!"
                    }
                    p95-Error -p95result $p95result.Line -process $process -CPUCore $core -Loop $i
                    Exit-Process -Process $process -ProcessName "prime95"
                }
                elseif ($process.HasExited -ne $false)
                {
                    if ($prev_core -gt -1)
                    {
                        Write-Log "!!! ============================================= !!!"
                        Write-Log "!!! Warning! Test failed within 100 ms.           !!!"
						Write-Log "!!! Previous core $prev_core might not be stable          !!!"
                        Write-Log "!!! ============================================= !!!"
                    }
                    p95-Error -p95result $p95result.Line -process $process -CPUCore $core -Loop $i
                }
                else
                {
                    Wait-prime95 -CPUCore $core -WaitTime $cycle_time -Loop $i
                }
            }
            $prev_core=$core
        }
    }
    Exit-Process -Process $process -ProcessName "prime95"
}

if ($fatal_error -eq $true)
{
    Write-Log ""
    Write-Log "Script encountered an error. Resolve and retry."
}
else
{
    Write-Log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    Write-Log "Testing complete."
	Write-Log "Cores $core_failure are NOT stable."
    Write-Log "Check log at $work_dir\cycle.log for any failures."
}

Wait-Event
