param(
    [parameter(Mandatory=$false)]
    [String] $AzureRunAsConnection = "Use *AzureRunAsConnection* Asset",
    [parameter(Mandatory=$false)]
    [bool]$Simulate = $false
)

$VERSION = "0.0.1"

# Define function to check current time against specified range
function CheckScheduleEntry ([string]$TimeRange)
{    
    # Initialize variables
    $rangeStart, $rangeEnd, $parsedDay = $null
    $currentTime = (Get-Date).ToUniversalTime()
    $midnight = $currentTime.AddDays(1).Date            

    try
    {
        # Parse as range if contains '->'
        if($TimeRange -like "*->*")
        {
            $timeRangeComponents = $TimeRange -split "->" | foreach {$_.Trim()}
            if($timeRangeComponents.Count -eq 2)
            {
                $rangeStart = Get-Date $timeRangeComponents[0]
                $rangeEnd = Get-Date $timeRangeComponents[1]
    
                # Check for crossing midnight
                if($rangeStart -gt $rangeEnd)
                {
                    # If current time is between the start of range and midnight tonight, interpret start time as earlier today and end time as tomorrow
                    if($currentTime -ge $rangeStart -and $currentTime -lt $midnight)
                    {
                        $rangeEnd = $rangeEnd.AddDays(1)
                    }
                    # Otherwise interpret start time as yesterday and end time as today   
                    else
                    {
                        $rangeStart = $rangeStart.AddDays(-1)
                    }
                }
            }
            else
            {
                Write-Output "`tWARNING: Invalid time range format. Expects valid .Net DateTime-formatted start time and end time separated by '->'" 
            }
        }
        # Otherwise attempt to parse as a full day entry, e.g. 'Monday' or 'December 25' 
        else
        {
            # If specified as day of week, check if today
            if([System.DayOfWeek].GetEnumValues() -contains $TimeRange)
            {
                if($TimeRange -eq (Get-Date).DayOfWeek)
                {
                    $parsedDay = Get-Date "00:00"
                }
                else
                {
                    # Skip detected day of week that isn't today
                }
            }
            # Otherwise attempt to parse as a date, e.g. 'December 25'
            else
            {
                $parsedDay = Get-Date $TimeRange
            }
        
            if($parsedDay -ne $null)
            {
                $rangeStart = $parsedDay # Defaults to midnight
                $rangeEnd = $parsedDay.AddHours(23).AddMinutes(59).AddSeconds(59) # End of the same day
            }
        }
    }
    catch
    {
        # Record any errors and return false by default
        Write-Output "`tWARNING: Exception encountered while parsing time range. Details: $($_.Exception.Message). Check the syntax of entry, e.g. '<StartTime> -> <EndTime>', or days/dates like 'Sunday' and 'December 25'"   
        return $false
    }
    
    # Check if current time falls within range
    if($currentTime -ge $rangeStart -and $currentTime -le $rangeEnd)
    {
        return $true
    }
    else
    {
        return $false
    }
    
} # End function CheckScheduleEntry

# Function to handle instance scaling
function ScaleManagedInstance
{
    param(
        [string]$ManagedInstanceName,
        [string]$ResourceGroupName,
        [int]$NewCores,
        [int]$NewStorage,
        [bool]$Simulate
    )

    $currentInstanceState = Get-AzSqlInstance -Name $ManagedInstanceName -ResourceGroupName $ResourceGroupName
    $currentStorage = $currentInstanceState.StorageSizeInGB
    $currentVCores = $currentInstanceState.VCores
    
    if(($currentStorage -ne $NewStorage) -or ($currentVCores -ne $NewCores)) {
        Write-Output "Current storage or vCores don't match sheduled values."
        if($Simulate) {
            Write-Output "Simulating started for instance with name: [$($ManagedInstanceName)] scaling started. Vcores: [$($NewCores)]. Storage: [$($NewStorage)]."
        } else {
            Set-AzSqlInstance -Name $ManagedInstanceName -ResourceGroupName $ResourceGroupName -VCore $NewCores -StorageSizeInGB $NewStorage -Force
            Write-Output "Instance with name: [$($ManagedInstanceName)] scaling started. Vcores: [$($NewCores)]. Storage: [$($NewStorage)]."
        }
    } else {
        Write-Output "Current storage or vCores match sheduled values."
    }
}

# Main runbook content
try
{
    $currentTime = (Get-Date).ToUniversalTime()
    Write-Output "Runbook started. Version: $VERSION"
    if($Simulate)
    {
        Write-Output "*** Running in SIMULATE mode. Scaling of the instance will not be performed. ***"
    }
    else
    {
        Write-Output "*** Running in LIVE mode. Instance scaling will be performed. NOTE: Changing instance storage and vCores results with changes in price ***"
    }
    Write-Output "Current UTC/GMT time [$($currentTime.ToString("dddd, yyyy MMM dd HH:mm:ss"))] will be checked against schedules"
    

    # Retrieve connection from variable asset if not specified
    if($AzureRunAsConnection -eq "Use *AzureRunAsConnection* asset")
    {
        # By default, look for "AzureRunAsConnection" asset
        $connection = Get-AutomationConnection -Name AzureRunAsConnection
        if($connection -eq $null)
        {
            throw "No AzureRunAsConnection service principal is defined."
        }
    }
    else
    {
        # A different connection was specified, attempt to load it
        $connection = Get-AutomationConnection -Name $AzureRunAsConnection
        if($connection -eq $null)
        {
            throw "Failed to get connection with name [$AzureRunAsConnection]"
        }
    }

    Write-Output "Attempting to authenticate wuth subscription ID: [$($connection.SubscriptionID)]"

    # Ensures you do not inherit an AzContext in your runbook
    Disable-AzContextAutosave –Scope Process
    while(!($connectionResult) -and ($logonAttempt -le 5))
    {
        $LogonAttempt++
        # Logging in to Azure...
        $connectionResult = Connect-AzAccount `
                                -ServicePrincipal `
                                -Tenant $connection.TenantID `
                                -ApplicationId $connection.ApplicationID `
                                -CertificateThumbprint $connection.CertificateThumbprint

        Start-Sleep -Seconds 30
    }

    $AzureContext = Set-AzContext -SubscriptionId $connection.SubscriptionID
    
    Write-Output "Current context: [$($AzureContext.Name)]"

    $resourceGroups = Get-AzResourceGroup -AzContext $AzureContext
    Write-Output "Total resource groups found: [$($resourceGroups.length)]"

    # Get resource groups that are tagged for automatic shutdown of resources
    $taggedResourceGroups = Get-AzResourceGroup -AzContext $AzureContext -Tag @{ AutoScalingSchedule = $null }
    Write-Output "Found [$($taggedResourceGroups.length)] schedule-tagged resource groups in subscription"    

    if($taggedResourceGroups.length -gt 0) {
        $schedule = $null

        foreach($rg in $taggedResourceGroups) {
            $rgName = $rg.ResourceGroupName
            $schedule = $rg.Tags.AutoScalingSchedule
            Write-Output "[$($rgName)]: Found parent resource group schedule tag with value: $schedule"

            $upperCores = $rg.Tags.AutoScalingUpperCores
            Write-Output "Upper cores: [$($upperCores)]"
            $lowerCores = $rg.Tags.AutoScalingLowerCores
            Write-Output "Lower cores: [$($lowerCores)]"

            $upperStorage = $rg.Tags.AutoScalingUpperStorage
            Write-Output "Upper storage: [$($upperStorage)]"
            $lowerStorage = $rg.Tags.AutoScalingLowerStorage
            Write-Output "Lower storage: [$($lowerStorage)]"

            $managedInstances = Get-AzSqlInstance -ResourceGroupName $rgName
            Write-Output "Managed instances found: [$($managedInstances.length)]"

            foreach($mi in $managedInstances) {
                if( $mi.DnsZone -ne $null ) {
                    Write-Output "Working with managed instance: [$($mi.ManagedInstanceName)] -> from resource group [$($rgName)]"
                     
                     # Check for direct tag or group-inherited tag
                    if($mi.Tags) {
                        if($mi.Tags.ContainsKey("AutoScalingSchedule")) {
                            $schedule = $mi.Tags.AutoScalingSchedule
                            Write-Output "[$($mi.ManagedInstanceName)]: Found direct scaling schedule tag with value: $schedule"
                        }
                        if($mi.Tags.ContainsKey("AutoScalingUpperCores")) {
                            $upperCores = $mi.Tags.AutoScalingUpperCores
                            Write-Output "[$($mi.ManagedInstanceName)]: Found direct upper cores tag with value: $upperCores"
                        }
                        if($mi.Tags.ContainsKey("AutoScalingLowerCores")) {
                            $lowerCores = $mi.Tags.AutoScalingLowerCores
                            Write-Output "[$($mi.ManagedInstanceName)]: Found direct lower cores tag with value: $lowerCores"
                        }
                        if($mi.Tags.ContainsKey("AutoScalingUpperStorage")) {
                            $upperStorage = $mi.Tags.AutoScalingUpperStorage
                            Write-Output "[$($mi.ManagedInstanceName)]: Found direct upper storage tag with value: $upperStorage"
                        }
                        if($mi.Tags.ContainsKey("AutoScalingLowerStorage")) {
                            $lowerStorage = $mi.Tags.AutoScalingLowerStorage
                            Write-Output "[$($mi.ManagedInstanceName)]: Found direct lower storage tag with value: $lowerStorage"
                        }
                    }

                    # Parse the ranges in the Tag value. Expects a string of comma-separated time ranges, or a single time range
                    $timeRangeList = @($schedule -split "," | foreach {$_.Trim()})

                    # Check each range against the current time to see if any schedule is matched
                    $scheduleMatched = $false
                    $matchedSchedule = $null
                    foreach($entry in $timeRangeList)
                    {
                        if((CheckScheduleEntry -TimeRange $entry) -eq $true)
                        {
                            $scheduleMatched = $true
                            $matchedSchedule = $entry
                            break
                        }
                    }

                    # Enforce desired state for group resources based on result. 
                    if($scheduleMatched)
                    {
                        # Schedule is matched. Scale down managed instance. 
                        Write-Output "[$($mi.ManagedInstanceName)]: Current time [$currentTime] falls within the scheduled scale down range [$matchedSchedule]"
                        ScaleManagedInstance -ManagedInstanceName $mi.ManagedInstanceName -ResourceGroupName $rgName -NewCores $lowerCores -NewStorage $lowerStorage -Simulate $Simulate
                    }
                    else
                    {
                        # Schedule not matched. Scale up managed instance.
                        Write-Output "[$($mi.ManagedInstanceName)]: Current time falls within scheduled scale up range."
                        ScaleManagedInstance -ManagedInstanceName $mi.ManagedInstanceName -ResourceGroupName $rgName -NewCores $upperCores -NewStorage $upperStorage -Simulate $Simulate
                    } 
                }
            }
        }
    }
}
catch
{
    $errorMessage = $_.Exception.Message
    throw "Unexpected exception: $errorMessage"
}
finally
{
    Write-Output "Runbook finished (Duration: $(("{0:hh\:mm\:ss}" -f ((Get-Date).ToUniversalTime() - $currentTime))))"
}
