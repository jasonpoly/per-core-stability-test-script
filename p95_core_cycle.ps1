# Windows Powershell Script
# Will extract, configure, and run a Prime95 on asingle thread using
# $process.ProcessorAffinity to assign to each cpu core for the specified time

$p95path="p95v303b6.win64.zip"; # path to p95.zip you want to extract and use
$env:core_failure=@()
$filedatetime=Get-Date -format FileDateTime
$log_file="cycle_$filedatetime.log"

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
	mkdir "$work_dir\logs" -ErrorAction SilentlyContinue
	mkdir "$work_dir\core_failures" -ErrorAction SilentlyContinue
}
else
{
    $work_dir="."
	mkdir "$work_dir\logs" -ErrorAction SilentlyContinue
	mkdir "$work_dir\core_failures" -ErrorAction SilentlyContinue
}


###################################################################
# Functions
###################################################################
function Write-Log-and-timestamp ($msg)
{
    Write-Output $msg | timestamp
    $msg | timestamp >> "$work_dir\logs\$log_file"
}

# LEGACY: No longer needed due to new file naming and handling
function OldRunScrubber ($test)
{
    if (Test-Path "$work_dir\${test}.core*failure*.log")
    {
		Write-Log-and-timestamp "Found previous results. Moving into into .\core_failures"
		Get-ChildItem -Path ".\*.log" | Move-Item -Destination "$work_dir\core_failures\"
    }
    if (Test-Path "$work_dir\p95\results.txt") # Is this necessary?
    {
        Move-Item -Force "$work_dir\p95\results.txt" "$work_dir\p95\prev.results.txt"
    }
	Write-Log-and-timestamp "Finished moving previous results."
}


function SetAffinity
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
        $runtime=(NEW-TIMESPAN -Start $starttime -End (GET-DATE)).TotalSeconds
    }
    if ($runtime -ge $time_out)
    {
        Write-Log-and-timestamp "!!! ============================================= !!!"
        Write-Log-and-timestamp "!!! ERROR: Timed out waiting for $ProcessName to start  !!!"
        Write-Log-and-timestamp "!!! ============================================= !!!"
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
        $process=Get-Process Prime95
        $process.ProcessorAffinity=[System.IntPtr]$affinity
        Write-Output $process
    }
}


function p95Error
{
    param (
        [Parameter()]$p95result,
        [Parameter(Mandatory=$true)]$process,
        [Parameter(Mandatory=$true)]$CPUCore,
        [Parameter(Mandatory=$true)]$Loop
    )
    if ($p95result)
    {
        Write-Log-and-timestamp "!!! ============================================= !!!"
        Write-Log-and-timestamp "!!! Test FAILED on core $CPUCore.                        !!!"
        Write-Log-and-timestamp "!!! Check .\core_failures                         !!!"
        Write-Log-and-timestamp "!!! ============================================= !!!"
        Write-Log-and-timestamp "$p95result"
		$env:core_failure += ("$CPUCore")
        Move-Item "$work_dir\p95\results.txt" "$work_dir\core_failures\${test}.core${CPUCore}_loop${Loop}_failure_$filedatetime.log"
        if ($stop_on_error)
        {
            $process.CloseMainWindow()
            $process.Close()
            Wait-Event
        }
    }
    elseif ($process.HasExited -ne $false)
    {
        Write-Log-and-timestamp "!!! ============================================= !!!"
        Write-Log-and-timestamp "!!! Prime95 process closed unexpectedly           !!!"
        Write-Log-and-timestamp "!!! Test FAILED on core $CPUCore.                        !!!"
        Write-Log-and-timestamp "!!! Check .\core_failures                         !!!"
        Write-Log-and-timestamp "!!! ============================================= !!!"
        Write-Log-and-timestamp "$p95result"
		$env:core_failure += ("$CPUCore")
        if (Test-Path "$work_dir\p95\results.txt")
        {
            Move-Item "$work_dir\p95\results.txt" "$work_dir\core_failures\${test}.core${CPUCore}_loop${Loop}_failure_$filedatetime.txt"
        }
        else
        {
            "Prime95 process closed unexpectedly" >> "$work_dir\core_failures\${test}.core${CPUCore}_loop${Loop}_failure_$filedatetime.log"
        }
        if ($stop_on_error)
        {
            $process.CloseMainWindow()
            $process.Close()
            Wait-Event
        }
    }
}


function Wait-Prime95
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
    while (($runtime -lt $WaitTime) -and (-not($p95result)) -and ((Test-Path "$work_dir\core_failures\core${CPUCore}_loop*_failure_$filedatetime.log") -eq $false) -and ($process.HasExited -eq $false))
    {
        Start-Sleep -Seconds $timestep
        $p95result=if (Test-Path "$work_dir\p95\results.txt") {Select-String "$work_dir\p95\results.txt" -Pattern ERROR}
        $runtime=(NEW-TIMESPAN -Start $starttime -End (GET-DATE)).TotalSeconds
    }
    if ($p95result)
    {
        p95Error -p95result $p95result.Line -process $process -CPUCore $CPUCore -Loop $Loop
    }
    elseif ($process.HasExited -ne $false)
    {
        p95Error -p95result $p95result.Line -process $process -CPUCore $CPUCore -Loop $Loop
    }
    else
    {
        Write-Log-and-timestamp "Test passed on core $CPUCore."
		Write-Log-and-timestamp "-----------------------------------------------------"
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
        Write-Log-and-timestamp "Waiting for $ProcessName to close."
        Wait-Process -Id $Process.Id -ErrorAction SilentlyContinue
        $Process.Close()
    }
}

###################################################################
# Main Script
###################################################################
Write-Log-and-timestamp "Writing log to $work_dir\$log_file"
if (Test-Path "$work_dir\$p95path")
{
    if (!(Test-Path "$work_dir\p95"))
    {
        Write-Log-and-timestamp "Extracting Prime95 from $p95path"
        Expand-Archive -LiteralPath "$p95path" -DestinationPath p95 -ErrorAction SilentlyContinue
    }
    else
    {
        Write-Log-and-timestamp "Using previously extracted Prime95 found in $work_dir\p95"
    }
}
else
{
    Write-Log-and-timestamp "!!! ============================================= !!!"
    Write-Log-and-timestamp "!!! $work_dir\$p95path not found"
    Write-Log-and-timestamp "!!! Download Prime95 and copy it to into $work_dir"
    Write-Log-and-timestamp "!!! ============================================= !!!"
    Wait-Event
    exit
}

Write-Log-and-timestamp "Configuring Prime95 for single core, non-AVX torture test"
Copy-Item "$work_dir\local.txt" "$work_dir\p95\"
Copy-Item "$work_dir\prime.txt" "$work_dir\p95\"

# Figure out how many cores we have and if SMT is enabled or disabled.
# We will then stress one core at a time, but use both threads on that core if SMT is enabled
$NumberOfLogicalProcessors=Get-CimInstance Win32_Processor | Measure-Object -Property  NumberOfLogicalProcessors -Sum
$NumberOfCores=Get-CimInstance Win32_Processor | Measure-Object -Property  NumberOfCores -Sum
if (($NumberOfCores.Sum * 2) -eq $NumberOfLogicalProcessors.Sum)
{
    Write-Log-and-timestamp "Detected $($NumberOfCores.Sum) cores and $($NumberOfLogicalProcessors.Sum) threads. SMT is enabled."
    if ($use_smt -eq $true)
    {
        Write-Log-and-timestamp "use_smt=$true. Using 2 threads per core."
    }
    else
    {
        Write-Log-and-timestamp "use_smt=$false. Using 1 thread per core."
    }
    $smt_enabled=$true
}
elseif ($NumberOfCores.Sum -eq $NumberOfLogicalProcessors.Sum)
{
    Write-Log-and-timestamp "Detected $($NumberOfCores.Sum) cores and $($NumberOfLogicalProcessors.Sum) threads. SMT is disabled."
    $smt_enabled=$false
}
else
{
    Write-Log-and-timestamp "!!! ============================================= !!!"
    Write-Log-and-timestamp "!!! ERROR detected $NumberOfCores cores and $NumberOfLogicalProcessors threads. !!!"
    Write-Log-and-timestamp "!!! This script only supports 1 or 2 threads per core !!!"
    Write-Log-and-timestamp "!!! ============================================= !!!"
    $fatal_error=$true
}

if ($last_core -ge $NumberOfCores.Sum)
{
    $last_core=$NumberOfCores.Sum-1
}

if ((Get-Process -Name Prime95 -ErrorAction SilentlyContinue).Count -gt 0)
{
    Write-Log-and-timestamp "!!! ============================================= !!!"
    Write-Log-and-timestamp "!!! ERROR Prime95 is already running              !!!"
    Write-Log-and-timestamp "!!! ============================================= !!!"
    $fatal_error=$true
}

if (($fatal_error -eq $false) -and ($core_loop_test -eq $true))
{
    $test="core_loop_test"
	Write-Log-and-timestamp "#####################################################"
    Write-Log-and-timestamp "Starting looping test on cores $first_core through $last_core."
    OldRunScrubber ($test)
    Write-Log-and-timestamp "Looping $loops times around all cores."
    $first_run=1
    for ($i=1; $i -le $loops; $i++)
    {
		Write-Log-and-timestamp "*****************************************************"
        Write-Log-and-timestamp "Starting pass $i out of $loops."
		Write-Log-and-timestamp "*****************************************************"
        for ($core=$first_core; $core -le $last_core; $core++)
        {
            # Skip testing if this core already failied in an earlier loop
            if (Test-Path "$work_dir\core_failures\*.core${core}_loop*_failure_$filedatetime.log")
            {
                Write-Log-and-timestamp "!!! ============================================= !!!"
                Write-Log-and-timestamp "!!! Skipping core ${core} due to previous failure.      !!!"
                Write-Log-and-timestamp "!!! ============================================= !!!"
            }
            else
            {
                $p95result=""
                if ($first_run -eq 1) # Do not cool down before the first test
                {
                    $first_run=0
                }
                elseif($cooldown -gt 0)
                {
                    Write-Log-and-timestamp "Cooling down for $cooldown seconds."
                    Start-Sleep -Seconds $cooldown
                }
                Write-Log-and-timestamp "Starting $cycle_time second torture test on core $core."
                # Start stress test
                Start-Process -FilePath "$work_dir\p95\Prime95.exe" -ArgumentList "-T" -WindowStyle Minimized
                $process=SetAffinity -CPUCore $core -ProcessName "Prime95"
                Wait-Prime95 -CPUCore $core -WaitTime $cycle_time -Loop $i
                Exit-Process -Process $process -ProcessName "Prime95"
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
	Write-Log-and-timestamp "#####################################################"
    Write-Log-and-timestamp "Starting core jumping test on cores $first_core through $last_core."
	Write-Log-and-timestamp "#####################################################"
    OldRunScrubber ($test)
    for ($i=1; $i -le $loops; $i++)
    {
		Write-Log-and-timestamp "*****************************************************"
        Write-Log-and-timestamp "Starting pass $i out of $loops."
		Write-Log-and-timestamp "*****************************************************"
        for ($j=$first_core; $j -le $last_core; $j++)
        {
            # randomly pick a new core to start or move to
            while ($core -eq $prev_core) {$core=Get-Random -Minimum $first_core -Maximum $last_core}
            # skip testing if this core already failied in an earlier loop
            if (Test-Path "$work_dir\core_failures\*.core${core}_loop*_failure_$filedatetime.log")
            {
                Write-Log-and-timestamp "!!! ============================================= !!!"
                Write-Log-and-timestamp "!!! Skipping core ${core} due to previous failure.      !!!"
                Write-Log-and-timestamp "!!! ============================================= !!!"
            }
            else
            {
                $p95result=""
                Write-Log-and-timestamp "Starting $cycle_time second torture test on core $core"
                # Start or re-start stress test
                if ((Get-Process -Name Prime95 -ErrorAction SilentlyContinue).Count -eq 0)
                {
                    Start-Process -FilePath "$work_dir\p95\Prime95.exe" -ArgumentList "-T" -WindowStyle Minimized
                }
                $process=SetAffinity -CPUCore $core -ProcessName "Prime95"
                Start-Sleep -Milliseconds 100
                $p95result=if (Test-Path "$work_dir\p95\results.txt") {Select-String "$work_dir\p95\results.txt" -Pattern ERROR}
                if ($p95result)
                {
                    if ($prev_core -gt -1)
                    {
                        Write-Log-and-timestamp "!!! ============================================= !!!"
                        Write-Log-and-timestamp "!!! Warning! Test failed within 100 ms.           !!!"
						Write-Log-and-timestamp "!!! Previous core $prev_core might not be stable          !!!"
                        Write-Log-and-timestamp "!!! ============================================= !!!"
                    }
                    p95Error -p95result $p95result.Line -process $process -CPUCore $core -Loop $i
                    Exit-Process -Process $process -ProcessName "Prime95"
                }
                elseif ($process.HasExited -ne $false)
                {
                    if ($prev_core -gt -1)
                    {
                        Write-Log-and-timestamp "!!! ============================================= !!!"
                        Write-Log-and-timestamp "!!! Warning! Test failed within 100 ms.           !!!"
						Write-Log-and-timestamp "!!! Previous core $prev_core might not be stable          !!!"
                        Write-Log-and-timestamp "!!! ============================================= !!!"
                    }
                    p95Error -p95result $p95result.Line -process $process -CPUCore $core -Loop $i
                }
                else
                {
                    Wait-Prime95 -CPUCore $core -WaitTime $cycle_time -Loop $i
                }
            }
            $prev_core=$core
        }
    }
}

if ($fatal_error -eq $true)
{
    Write-Log-and-timestamp "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    Write-Log-and-timestamp "Script encountered an error. Resolve and retry."
}
else
{
	$env:core_failures = $env:core_failure | Sort-Object
    Write-Log-and-timestamp "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    Write-Log-and-timestamp "Testing complete."
	if($env:core_failures.Count -gt 0)
	{
		Write-Log-and-timestamp "The following cores are NOT stable."
		Write-Log-and-timestamp $env:core_failures
	}
    Write-Log-and-timestamp "Console output is stored at $work_dir\logs\$log_file."
}
Wait-Event
