<#
.SYNOPSIS
    Automate the WVD starting and stop of the WVD session hosts based 
    on the amount of users sessions

.DESCRIPTION
    This powershell script does the following:
        Automatically start and stop session hosts in the WVD environment based on the number of users logged in
        Determines the number of servers that are required to be running to meet the specifications outlined
            (number is divided by the definition of maximum session set as defined in the depth-first load balancing settings for the pool) 
        Session hosts are scaled up or down based on that metric
    
.REQUIREMENTS    
        An Azure Automation Account
        RunAsAccount for the Automation Account
        A runbook with an enabled webhook
        The corresponding secret url for the webhook
        An Azure Logic App configured to manipulate the runbook via the webhook
        WVD Host Pool must be configured for Depth First load balancing
        The RunAsAccount for the Automation Account must be in a "RDS Contributor" role for the WVD Tenant
        Azure Automation Account runbook needs the following added PowerShell modules:
            Az.account, Az.compute, and Microsoft.RDInfra.RDPowershell

.LOGIC_APP_EXAMPLE
    {
        "definition": { 
            "$schema": "https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#",
            "actions": {
                "HTTP_Webhook": {
                    "inputs": {
                        "subscribe": {
                            "body": {
                                "ConnectionAssetName": "<RunAsConnectionName>",
                                "RDBrokerURL": "https://rdbroker.wvd.microsoft.com",
                                "aadTenantId": "<AADTenant>",
                                "azureSubId": "<AzureSubscriptionId>",
                                "callbackUrl": "@{listCallbackUrl()}",
                                "endPeakTime": "18:00:00",
                                "hostpoolname": "<WVDHostPoolName>",
                                "peakServerStartThreshold": "2",
                                "peakday": [
                                    "Monday",
                                    "Tuesday",
                                    "Wednesday",
                                    "Thursday",
                                    "Friday"
                                ],
                                "serverStartThreshold": "1",
                                "sessionHostRg": "<WVDHostPoolResourceGroup>",
                                "startPeakTime": "06:00:00",
                                "tenantName": "<WVDTenantName>",
                                "usePeak": "yes",
                                "utcoffset": "-7"
                            },
                            "method": "POST",
                            "uri": "<RunbookWebhookUrl>"
                        },
                        "unsubscribe": {}
                    },
                    "runAfter": {},
                    "type": "HttpWebhook"
                }
            },
            "contentVersion": "1.0.0.0",
            "outputs": {},
            "parameters": {},
            "triggers": {
                "Recurrence": {
                    "recurrence": {
                        "frequency": "Minute",
                        "interval": 5
                    },
                    "type": "Recurrence"
                }
            }
        },
        "parameters": {}
    }

.NOTES 
    Author:       Donald Harris
    Version:      1.0.0     Initial Build Kandice Hendricks see here for her information https://github.com/KandiceLynne/AzureRunbooks
                  1.0.1     Implemented logic app manipulating a runbook webhook to feed the variables in this script
                  1.0.2     Fixed typos, fixed up time, and other random bug fixes
                  2.0.0     Removed all hard coded references, they all now use the data from the webhook

#>

    #######       Get data from webhook body    #############
        param(
	        [Parameter(mandatory = $false)]
	        [object]$WebHookData
        )
        # If runbook was called from Webhook, WebhookData will not be null.
        if ($WebHookData) {

	        # Collect properties of WebhookData
	        $WebhookName = $WebHookData.WebhookName
	        $WebhookHeaders = $WebHookData.RequestHeader
	        $WebhookBody = $WebHookData.RequestBody

	        # Collect individual headers. Input converted from JSON.
	        $From = $WebhookHeaders.From
	        $Input = (ConvertFrom-Json -InputObject $WebhookBody)
        }
        else
        {
	        Write-Error -Message 'Runbook was not started from Webhook' -ErrorAction stop
        }

    #######       Translate Webhook Data into Variables       #######
        $serverStartThreshold = $Input.serverStartThreshold
        $usePeak = $Input.usePeak
        $peakServerStartThreshold = $Input.peakServerStartThreshold
        $startPeakTime = $Input.startPeakTime
        $endPeakTime = $Input.endPeakTime
        $utcoffset = $Input.utcoffset
        $peakDay = $Input.peakDay 
        $aadTenantId = $Input.aadTenantId
        $azureSubId = $Input.azureSubId
        $sessionHostRg = $Input.sessionHostRg 
        $tenantName = $Input.tenantName
        $hostPoolName = $Input.hostpoolname
        $ConnectionAssetName = $Input.ConnectionAssetName
        $rdbroker = $Input.RDBrokerURL
        $callbackurl = $Input.callbackUrl

   #######       Section for Functions       ####### 

    #Convert UTC to Local Time

      function Convert-UTCtoLocalTime
    {
	    param(
		    $TimeDifferenceInHours
	)

	    $UniversalTime = (Get-Date).ToUniversalTime()
	    $TimeDifferenceMinutes = 0
	    if ($TimeDifferenceInHours -match ":") {
		    $TimeDifferenceHours = $TimeDifferenceInHours.Split(":")[0]
		    $TimeDifferenceMinutes = $TimeDifferenceInHours.Split(":")[1]
	    }
	    else {
		    $TimeDifferenceHours = $TimeDifferenceInHours
	    }
	    #Azure is using UTC time, justify it to the local time
	    $ConvertedTime = $UniversalTime.AddHours($TimeDifferenceHours).AddMinutes($TimeDifferenceMinutes)
	    return $ConvertedTime
    }

    #Start Session Host

      function Start-SessionHost 
    {
        param   
        (
           $SessionHosts,
           $sessionsToStart
       )
        
       # Number of off hosts accepting connections
        $offSessionHosts = $sessionHosts | Where-Object { $_.status -eq "NoHeartbeat" }
        $offSessionHostsCount = $offSessionHosts.count
        Write-Output "Off Session Hosts $offSessionHostsCount"
        Write-Output ($offSessionHost | Out-String)
       
        if ($offSessionHostsCount -eq 0 ) 
        {   
            Write-Error $ErrorMessage "Start threshold met, but the status variable is still not finding an available host to start"
        }
        else 
        {
            if  ($sessionsToStart -gt $offSessionHostsCount)
                {$sessionsToStart = $offSessionHostsCount}
            $counter = 0
                Write-Output "Conditions met to start a host"
            while ($counter -lt $sessionsToStart)
            {
                $startServerName = ($offSessionHosts | Select-Object -Index $counter).SessionHostName
                Write-Output "Server that will be started $startServerName"
                try
                {  
                    # Start the VM
                    $Connection = Get-AutomationConnection -Name $ConnectionAssetName
                    Connect-AzAccount -ErrorAction Stop -ServicePrincipal -SubscriptionId $azureSubId -TenantId $aadTenantId  -ApplicationId $Connection.ApplicationId -CertificateThumbprint $Connection.CertificateThumbprint
                    $vmName = $startServerName.Split('.')[0]
                    Start-AzVM -ErrorAction Stop -ResourceGroupName $sessionHostRg -Name $vmName
                }
                catch 
                {
                    $ErrorMessage = $_.Exception.message
                    Write-Error ("Error starting the session host: " + $ErrorMessage)
                    Break
                }
            $counter++
            }
        }
    }


#Stop Session Host
function Stop-SessionHost 
{
   param 
   (
       $SessionHosts,
       $sessionsToStop
   )
        ##  Get computers running with no users
        $emptyHosts = $sessionHosts | Where-Object { $_.Sessions -eq 0 -and $_.Status -eq 'Available' }
        $emptyHostsCount = $emptyHosts.count 
        ##  Count hosts without users and shut down all unused hosts until desire threshold is met
        Write-Output "Evaluating servers to shut down"
   if ($emptyHostsCount -eq 0) 
        {Write-Error "Error: No hosts available to shut down"}
   else
   {
        if ($sessionsToStop -gt $emptyHostsCount)
        {$sessionsToStop = $emptyHostsCount}
        $counter = 0
        Write-Output "Conditions met to stop a host"
        while ($counter -lt $sessionsToStop) 
            {
            $shutServerName = ($emptyHosts | Select-Object -Index $counter).SessionHostName
            Write-Output "Shutting down server $shutServerName"
            try 
                {
                # Stop the VM
                $Connection = Get-AutomationConnection -Name $ConnectionAssetName
                Connect-AzAccount -ErrorAction Stop -ServicePrincipal -SubscriptionId $azureSubId -TenantId $aadTenantId  -ApplicationId $Connection.ApplicationId -CertificateThumbprint $Connection.CertificateThumbprint
                $vmName = $shutServerName.Split('.')[0]
                Stop-AzVM -ErrorAction Stop -ResourceGroupName $sessionHostRg -Name $vmName -Force
                }
            catch 
                {
                $ErrorMessage = $_.Exception.Message
                Write-Error ("Error stopping the VM: " + $ErrorMessage)
                Break  
                }
        $counter++
            }   
    }
}

#######       Script Execution       #######

## Log into Azure WVD
try 
{
    $Connection = Get-AutomationConnection -Name $ConnectionAssetName
    Add-RdsAccount -ErrorAction Stop -DeploymentUrl $rdbroker -ApplicationId $Connection.ApplicationId -CertificateThumbprint $Connection.CertificateThumbprint -AadTenantId $aadTenantId
}
catch 
{
    $ErrorMessage = $_.Exception.message
    Write-Error ("Error logging into WVD: " + $ErrorMessage)
    Break
}

## Get Host Pool 
try 
{
    $hostPool = Get-RdsHostPool -ErrorVariable Stop $tenantName $hostPoolName 
    Write-Output "HostPool:"
    Write-Output $hostPool.HostPoolName
}
catch 
{
    $ErrorMessage = $_.Exception.message
    Write-Error ("Error getting host pool details: " + $ErrorMessage)
    Break
}

## Verify load balancing is set to Depth-first
if ($hostPool.LoadBalancerType -ne "DepthFirst") 
{
    Write-Error "Error: Host pool not set to Depth-First load balancing. This script requires Depth-First load balancing to execute"
    exit
}

## Check if peak time and adjust threshold
    # Converting date time from UTC to Local
	$dateTime = Convert-UTCtoLocalTime -TimeDifferenceInHours $utcoffset
    	$BeginPeakDateTime = [datetime]::Parse($dateTime.ToShortDateString() + ' ' + $startPeakTime)
	$EndPeakDateTime = [datetime]::Parse($dateTime.ToShortDateString() + ' ' + $EndPeakTime)
    Write-Output "Current Day, Date, and Time:"
    Write-Output $dateTime
    $dateDay = (((get-date).ToUniversalTime()).AddHours($utcOffset)).dayofweek
    #Write-Output $dateDay
if ($dateTime -gt $BeginPeakDateTime -and $dateTime -lt $EndPeakDateTime -and $dateDay -in $peakDay -and $usePeak -eq "yes") 
    { Write-Output "Threshold set for peak hours" 
    $serverStartThreshold = $peakServerStartThreshold }
else 
    { Write-Output "Thershold set for outside of peak hours" }


## Get the Max Session Limit on the host pool
## This is the total number of sessions per session host
    $maxSession = $hostPool.MaxSessionLimit
    Write-Output "MaxSession: $maxSession"

# Find the total number of session hosts
# Exclude servers that do not allow new connections
try 
{
   $sessionHosts = Get-RdsSessionHost -ErrorAction Stop -tenant $tenantName -HostPool $hostPoolName | Where-Object { $_.AllowNewSession -eq $true }
}
catch 
{
   $ErrorMessage = $_.Exception.message
   Write-Error ("Error getting session hosts details: " + $ErrorMessage)
   Break
}

## Get current active user sessions
    $currentSessions = 0
foreach ($sessionHost in $sessionHosts) 
{
   $count = $sessionHost.sessions
   $currentSessions += $count
}
    Write-Output "CurrentSessions: $currentSessions"

## Number of running and available session hosts
## Host that are shut down are excluded
    $runningSessionHosts = $sessionHosts | Where-Object { $_.Status -eq "Available" }
    $runningSessionHostsCount = $runningSessionHosts.count
    Write-Output "Running Session Host: $runningSessionHostsCount"
    Write-Output ($runningSessionHosts | Out-string)

# Target number of servers required running based on active sessions, Threshold and maximum sessions per host
    $sessionHostTarget = [math]::Ceiling((($currentSessions + $serverStartThreshold) / $maxSession))

if ($runningSessionHostsCount -lt $sessionHostTarget) 
{
   Write-Output "Running session host count $runningSessionHostsCount is less than session host target count $sessionHostTarget, starting sessions"
   $sessionsToStart = ($sessionHostTarget - $runningSessionHostsCount)
   Start-SessionHost -Sessionhosts $sessionHosts -sessionsToStart $sessionsToStart
   Invoke-RestMethod -Method Post -Uri $callbackurl
}
elseif ($runningSessionHostsCount -gt $sessionHostTarget) 
{
   Write-Output "Running session hosts count $runningSessionHostsCount is greater than session host target count $sessionHostTarget, stopping sessions"
   $sessionsToStop = ($runningSessionHostsCount - $sessionHostTarget)
   Stop-SessionHost -SessionHosts $sessionHosts -sessionsToStop $sessionsToStop
   Invoke-RestMethod -Method Post -Uri $callbackurl
}
else 
{
 Write-Output "Running session host count $runningSessionHostsCount matches session host target count $sessionHostTarget, doing nothing" 
 Invoke-RestMethod -Method Post -Uri $callbackurl  
}
