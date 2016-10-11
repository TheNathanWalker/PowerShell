<#
NetApp SolidFire LUN Clone Refresh Script
Author: Nathan Walker, nathan.walker@netapp.com

Requires an input JSON file of the following format:
{
	"params": {
		"mvip": "10.5.5.100",
		"sfusername": "admin",
		"sfpassword": "solidfire",
		"destinationESX": "10.6.6.13",
		"ESXadmin": "root",
		"ESXpassword": "solidfire",
		"destVM": "Windows2012_VM1",
		"destVAG": "VAG-dest",
		"clonePrefix": "oraClone",
		"logfolder": "c:\\OracleCloneLogs"
	},
	"volumes": [{
		"name": “SourceVol1",
		"min": "100",
		"max": "200",
		"burst": "300",
		"account": "1"
	}, {
		"name": “SourceVol2",
		"min": "200",
		"max": "300",
		"burst": "400",
		"account": "1"
	}, {
		"name": “SourceVol3",
		"min": "300",
		"max": "400",
		"burst": "500",
		"account": "1"
	}]
}
Recommend using http://jsonlint.com/ to validate JSON file

Command line example: ./SF-LunCloneRefresh.ps1 ./jsonInput.txt 

-Script will initiate connections to ESXi or vCenter and SolidFire cluster to create a group snapshot the volumes listed in the volumes array. 

-Logs are created in the logfolder directory. 

-Old clones will be deleted. 

-New clones will be named by concatenating the clonePrefix and the source volume name, e.g. OraCloneSourceVol1. 

-New clones have QoS and account set according to the volumes array

#>

# Grab command line parameters that are not static across iterations
[CmdletBinding(SupportsShouldProcess=$True)]
param (
[Parameter(Mandatory=$true)]
[string] $jsonInput = $null
)

# Load necessary modules
#Download latest from https://www.vmware.com/support/developer/PowerCLI
Get-Module -ListAvailable VM* | Import-Module

#Download from https://github.com/solidfire
Import-Module Solidfire

# Set variables
$j = ConvertFrom-JSON -InputObject (GC $jsonInput -Raw)
if($j -eq $null) {
        Write-Host “There was a problem parsing the JSON input file." -ForegroundColor Yellow
        Break
}

#Create log file
If (!(Test-Path -Path $j.params.logfolder)) { New-Item -ItemType Directory -Path $j.params.logfolder }
$logfile = $j.params.logfolder + "\" + (Get-Date -Format o |ForEach-Object {$_ -Replace ":", "."}) + ".clone.log"
add-content $logfile "Start script"
$now = Get-Date -Format o |ForEach-Object {$_ -Replace ":", "."}; add-content $logfile $now
 
function ToLog ( [string] $outtext1, [string] $outtext2, [string] $outtext3, [string] $outtext4 )
{
	$out = (Get-Date).ToString() + " " + $outtext1 + " " + $outtext2 + " " + $outtext3 + " " + $outtext4
	add-content $logfile $out
}

#############
#Initiate Sessions
#############
$sfclusterConnection = Connect-SFCluster -Target $j.params.mvip -Username $j.params.sfusername -Password $j.params.sfpassword
ToLog $sfclusterConnection
if($sfclusterConnection -eq $null) {
        Write-Host "You do not have an active SolidFire Cluster connection." -ForegroundColor Yellow
        Break
}

set-powercliconfiguration -invalidcertificateaction "ignore" -confirm:$false |out-null
$esxConnection = Connect-VIServer -Server $j.params.destinationESX -User $j.params.ESXadmin -Password $j.params.ESXpassword
ToLog $esxConnection
if($esxConnection -eq $null) {
        Write-Host "You do not have an active ESXi connection." -ForegroundColor Yellow
        Break
}

#############
#Quiesce DB(s)
#############
<#
blah blah blah
May recommend following https://docs.oracle.com/cd/E59133_01/doc.411/e57057/pwrshell.htm#OFSCN415
Or could play with this method: http://lvlnrd.com/oracle-database-queries-in-powershell-script-examples/
#>

#############
#Group Snap Volumes
#############
ToLog "Beginning group snap operation"
$groupSnapResult = New-SFGroupSnapshot -VolumeID (Get-SFVolume -Name $j.volumes.name).VolumeID -Name $j.params.clonePrefix
DO { sleep 1 } 
While ( $groupSnapResult.status -eq "running")
ToLog "Completed group snap operation"
If ( $groupSnapResult.status -ne "done" )
{
	#	something bad has happened. Report error and exit or something like that….
	ToLog " Error status of group snap operation is:", $groupSnapResult.status
	Break
}

#############
#Remove-HardDisk
#############
for ($i=0;$i -lt (Get-SFVolume -Name $j.volumes.name).volumeID.length; $i++ )
{
	
	$scsiCanonicalName = "naa." + (Get-SFVolume -Name ($j.params.clonePrefix + $j.volumes.name[$i])).ScsiNAADeviceID
	$scsiCanonicalName
	$removeTargetDisk = Get-HardDisk -VM $j.params.destVm | Where-Object {$_.ScsiCanonicalName -Contains $scsiCanonicalName}
	$removeTargetDisk
	ToLog "Attempting to Remove-HardDisk", (Get-SFVolume -Name ($j.params.clonePrefix + $j.volumes.name[$i])).Name, "Volume ID", (Get-SFVolume -Name ($j.params.clonePrefix + $j.volumes.name[$i])).VolumeID
	Remove-HardDisk $removeTargetDisk -Confirm:$false
	ToLog "Attempting to Remove-SFVolume", (Get-SFVolume -Name ($j.params.clonePrefix + $j.volumes.name[$i])).Name, "Volume ID", (Get-SFVolume -Name ($j.params.clonePrefix + $j.volumes.name[$i])).VolumeID
	Remove-SFVolume -VolumeID (Get-SFVolume -Name ($j.params.clonePrefix + $j.volumes.name[$i])).VolumeID -Confirm:$false
}
Get-VMhost $j.params.destinationESX | Get-VMhostStorage -RescanAllHba -RescanVMFs

###
# Need to think about any error checking for above code block. 
# Should we check if all LUNs were indeed removed? 
# Other?
###

#############
#CloneMultipleVolume && add as new RDMs
#############
# Target only specific snapshots even if there are other single or group snapshots in the cluster.
$snapshots=Get-SFSnapshot
$newSFDisk = New-Object System.Collections.ArrayList
foreach ($snap in $snapshots) 
{
# Make sure we snap only those listed in the JSON input file
	if ( $j.volumes.name -contains (Get-SFVolume -VolumeID $snap.VolumeID).Name )
	{
		ToLog "Attempting to create new SF volume from snap for", (Get-SFVolume -VolumeID $snap.VolumeID).Name, "with VolumeID", $snap.volumeID
		$response = New-SFClone -VolumeID $snap.volumeID -Name ($j.params.clonePrefix + (Get-SFVolume -VolumeID $snap.VolumeID).Name) -SnapshotID $snap.SnapshotID
		$newVolID=$response.volumeID
		$newCloneID=$response.CloneID
# Get-SFAsyncResult -ASyncResultID $response.AsyncHandle
# 1 second sleep seems to be a good wait for this. 
# The asynchandle is destroyed very quickly. Would prefer to watch handle. 
# Give it just one second to complete. Very soon thereafter $response becomes null. =(
# Not happy with this series of operations!
		sleep 1
		ToLog "Completed volume clone operation for clone ID", $newCloneID, "which created new volume ID", $newVolID	
		ToLog "Attempting to add volumeID", $newVolID "to volume acccess group", $j.params.destVAG
		Add-SFVolumeToVolumeAccessGroup -VolumeAccessGroupID (Get-SFVolumeAccessGroup -name $j.params.destVAG).volumeAccessGroupID -VolumeID $newVolID
		
# Now get parameters for new clone and apply
		foreach ($v in $j.volumes)
		{
			if ($v.name -eq (Get-SFVolume -VolumeID $snap.volumeID).name)
			{
				Set-SFVolume -VolumeID $newVolID -MinIOPS $v.min -MaxIOPS $v.max -BurstIOPS $v.burst -AccountID $v.account -Confirm:$false
			} 
		}
		$consoleDeviceName = "/vmfs/devices/disks/naa." + (Get-SFVolume -VolumeID $newVolID).ScsiNAADeviceID
		$newSFDisk.Add($consoleDeviceName)
	}
}
Get-VMhost $j.params.destinationESX| Get-VMhostStorage -RescanAllHba -RescanVMFs

# Bulk add new RDM clones to target VM
foreach ($i in $newSFDisk)
{
	ToLog "Attempting to create new RDM LUN", $i, "for VM", $j.params.destVM
	New-HardDisk -VM (Get-VM $j.params.destVM) -DiskType RawPhysical -DeviceName $i
}
ToLog "Attempting to remove GroupSnapshotID" $groupSnapResult.GroupSnapshotID
Remove-SFGroupSnapshot -GroupSnapshotID $groupSnapResult.GroupSnapshotID -Confirm:$false