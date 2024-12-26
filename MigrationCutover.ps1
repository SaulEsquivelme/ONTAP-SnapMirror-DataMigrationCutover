#Main variables
$sourceClusterIp = "10.11.11.11"
$targetClusterIp = "10.22.22.22"
$sourceCluster = "sourceClusterName"
$sourceVserver = "svm_source"
$targetCluster = "targetClusterName"
$targetVserver = "svm_target"

$user = "ONTAPUser"
$securestring = Get-Content -Path "C:\Users\User1\Documents\user.txt" | ConvertTo-SecureString
$credential = new-object management.automation.pscredential $user, $securestring


#ExtractVols_CVO.ps1
$file_path = "C:\Users\User1\Documents\Source_volumes.csv"
try{
    Connect-NcController $sourceCusterIp
    $volumes = Get-NcVol | Select-Object Name, Vserver, TotalSize, Tiering  | Where {$_.Name -ne "vol0" -and $_.Name -notlike "*root*"} | Export-Csv -Path $file_path
}
catch [NetApp.Ontapi.NaConnectionTimeoutException]{
    Write-Host "Error on cluster: "$sourceCluster
}


#NewDPVols
$aggregateName = "aggr1"
try{
    $input_file_path = "C:\Users\User1\Documents\Source_volumes.csv"
    Connect-NcController $targetClusterIp -Credential $credential
    Import-Csv -Path $input_file_path | ForEach-Object {
        New-NcVol -Name $($_.Name) -Size $($_.TotalSize) -Type DP -Aggregate $aggregateName -VserverContext $targetVserver -TieringPolicy all
    }
    #Get-NcVol
}
catch [NetApp.Ontapi.NaConnectionTimeoutException]{
    Write-Host "Error on cluster: "$targetCluster
}


#SnapMirror_Create.ps1
$input_file_path = "C:\Users\User1\Documents\Source_volumes.csv"
Connect-NcController $targetClusterIp -Credential $credential
Import-Csv -Path $input_file_path | ForEach-Object {
New-NcSnapmirror -DestinationCluster $targetCluster -DestinationVserver $targetVserver -DestinationVolume $($_.Name) -SourceCluster $sourceCluster -SourceVserver $sourceVserver -SourceVolume $($_.Name) -Policy MirrorAllSnapshots
#Invoke-NcSnapmirrorInitialize -DestinationCluster $targetCluster -DestinationVserver $targetVserver -DestinationVolume $($_.Name) -SourceCluster $sourceCluster -SourceVserver $sourceVserver -SourceVolume $($_.Name)
#break
}
Get-NcSnapmirror


#SnapmirrorInitialize
Connect-NcController $tagetClusterIp -Credential $credential
if (Get-NcSnapmirror -ZapiCall | Where-Object {$_.Status -eq "transferring"}){
    Write-Host "Tansfer in progress...."
}
else{
    $volumes = Get-NcSnapmirror -ZapiCall | Where-Object {$_.MirrorState -eq "uninitialized"} | Select-Object -ExpandProperty SourceVolume
    foreach ($volume in $volumes){
        $randomSchedule = Get-NcJobCronSchedule <#-JobScheduleName "keyword*"#>| Get-Random | Select-Object -ExpandProperty JobScheduleName
        Set-NcSnapMirror -DestinationCluster $targetCluster -DestinationVserver $targetVserver -DestinationVolume $volume -SourceCluster $sourceCluster -SourceVserver $sourceVserver -SourceVolume $volume -Schedule $randomSchedule
        Invoke-NcSnapmirrorInitialize -DestinationCluster $targetCluster -DestinationVserver $targetVserver -DestinationVolume $volume -SourceCluster $sourceCluster -SourceVserver $sourceVserver -SourceVolume $volume
        break
    }
}


#MountShare management source
Connect-NcController $sourceClusterip -Credential $credential
$Vols = Import-Csv "C:\Users\User1\Documents\Source_volumes.csv"
$volObject = @()
foreach($vol in $Vols){
    $jp = Get-NcVol -Name $vol.Name | Select-Object -ExpandProperty JunctionPath
    $shareDetails = Get-NcCifsShare -ZapiCall | Where-Object {$_.Volume -eq $vol.Name} | Select-Object Name, Comment, Path
    foreach ($singleShare in $shareDetails){
        $vol.Name
        $volObject += New-Object psobject -Property @{
            volume = $vol.Name
            jp = $jp
            shareName = $singleShare.Name
            shareComment = $singleShare.Comment
            sharePath = $singleShare.Path
    }
    }
}
$volObject | Export-Csv -Path "C:\Users\User1\Documents\volObjectSource.csv"


#volumeMount CifsshareCreate
Connect-NcController $targetClusterIp -Credential $credential
$volumeObjects = Import-Csv -Path "C:\Users\User1\Documents\volObjectSource.csv"
foreach ($volumeObj in $volumeObjects){
    Mount-NcVol -Name $volumeObj.Volume -JunctionPath $volumeObj.jp -VserverContext $targetVserver
    Add-NcCifsShare -VserverContext $targetVserver -Name $volumeObj.shareName -Path $volumeObj.sharePath
}


#cutover
Connect-NcController $targetCluserIp -Credential $credential
$volumes = Import-Csv -Path "C:\Users\User1\Documents\Source_volumes.csv"
foreach ($volume in $volumes){
    #Last update
    Invoke-NcSnapmirrorUpdate -DestinationCluster $targetCluster -DestinationVserver $targetVserver -DestinationVolume $volume -SourceCluster $sourceCluster -SourceVserver $sourceVserver -SourceVolume $volume
    Start-Sleep -seconds 2
    #Snapmirror break
    #Invoke-NcSnapmirrorQuiesce 
    #Invoke-NcSnapmirrorBreak #-Confirm:$false
    #Invoke-NcSSH "volume modify -vserver $targetVserver -volume $volume -snapshot-policy "snapshotPolicy_name" "
}


#Vol offline
Connect-NcController $sourceClusterIp -Credential $credential
$volumeObjects = Import-Csv -Path "C:\Users\User1\Documents\Source_volumes.csv"
foreach ($volumeObj in $volumeObjects){
    Dismount-NcVol -Name $volumeObj.Name -VserverContext $sourceVserver
    #Set-NcVol -Name $volumeObj.Name -Offline -VserverContext $sourceVserver #-Confirm:$false
}
