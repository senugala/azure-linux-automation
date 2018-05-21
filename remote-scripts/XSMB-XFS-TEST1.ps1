<#-------------Create Deployment Start------------------#>
Import-Module .\TestLibs\RDFELibs.psm1 -Force
$result = ""
$testResult = ""
$resultArr = @()
$AzureShare=$currentTestData.AzureShareUrl
$resourceName=$AzureShare.Split("//")[2].Split(".")[0]
$AccessKey=(Get-AzureRmStorageAccountKey -ResourceGroupName $resourceName -Name $resourceName).value[0]
#$AccessKey=(Get-AzureRmStorageAccountKey -ResourceGroupName $AzureShare.Split("//")[2].Split(".")[0] -Name $AzureShare.Split("//")[2].Split(".")[0]).value[0]
$MountPoint=$currentTestData.MountPoint

$isDeployed = DeployVMS -setupType $currentTestData.setupType -Distro $Distro -xmlConfig $xmlConfig
if ($isDeployed)
{
	try
	{
		$testVMData = $allVMData
		ProvisionVMsForLisa -allVMData $allVMData -installPackagesOnRoleNames "none"
	
		RemoteCopy -uploadTo $testVMData.PublicIP -port $testVMData.SSHPort -files ".\remote-scripts\azuremodules.py,.\remote-scripts\XSMB-XFS-TEST.py,.\remote-scripts\GetXsmbXfsTestStatus.sh" -username "root" -password $password -upload
		RunLinuxCmd -ip $testVMData.PublicIP -port $testVMData.SSHPort -username "root" -password $password -command "chmod +x *.sh" -runAsSudo
		RunLinuxCmd -ip $testVMData.PublicIP -port $testVMData.SSHPort -username "root" -password $password -command "mkdir $MountPoint" -runAsSudo
		RunLinuxCmd -ip $testVMData.PublicIP -port $testVMData.SSHPort -username "root" -password $password -command "mount -t cifs $AzureShare $MountPoint -o vers=3.0,username=xsmbforcifs,password=$AccessKey,dir_mode=0777,file_mode=0777,sec=ntlmssp" -runAsSudo
		LogMsg "Mounting Share on remote Machine"
		#LogMsg "Executing : $($currentTestData.testScript)"
		$testJob=RunLinuxCmd -username root -password $password -ip $testVMData.PublicIP -port $testVMData.SSHPort -command "python $($currentTestData.testScript) -p $AccessKey -s $AzureShare -m $MountPoint > /root/test.txt" -runAsSudo -runmaxallowedtime 1000 -ignoreLinuxExitCode 
		while ( (Get-Job -Id $testJob).State -eq "Running" )
		{
			$currentStatus = RunLinuxCmd -ip $testVMData.PublicIP -port $testVMData.SSHPort -username root -password $password -command "tail -1 runlog.txt" -runAsSudo
			LogMsg "Current Test Staus : $currentStatus"
			WaitFor -seconds 30
		}
		
		WaitFor -seconds 10
		$TStatus=RunLinuxCmd -username root -password $password -ip $testVMData.PublicIP -port $testVMData.SSHPort -command "cat xfstest.log" -runAsSudo -ignoreLinuxExitCode
		
		if(!$TStatus -imatch "FSTYP.*cifs")
		{
			$total_time = 0
			$interval = 600
			WaitFor -seconds 120
			while($true)
			{	
				$xStatus=RunLinuxCmd -username root -password $password -ip $testVMData.PublicIP -port $testVMData.SSHPort -command "cat /xfstests/results/check.log " -runAsSudo -ignoreLinuxExitCode
				$checkStatus=RunLinuxCmd -username root -password $password -ip $testVMData.PublicIP -port $testVMData.SSHPort -command "pgrep check|wc -l" -runAsSudo -ignoreLinuxExitCode
				if($xStatus -imatch "Failed.*of.*tests")
				{
					$testResult = "PASS"
					LogMsg "$($currentTestData.testScript) Completed.. "
					break
				}elseif(!$checkStatus)
				{
					$testResult = "FAIL"
					LogMsg "$($currentTestData.testScript) Completed.. "
					break   
				}

				if ($total_time -gt 720000)
				{
					$testResult = "FAIL"
					LogMsg "$($currentTestData.testScript) is taking more than 20 hrs this is bad.. "
					break					
				}
				WaitFor -seconds $interval
				$total_time += $interval
			}
		}
		else
		{
			$testResult = "Failed"
			LogMsg "xfstests not started.. "
			LogMsg "Error: $TStatus"
			$testResult = "PASS"
		}
		if($testResult -eq "PASS")
		{
			$out=RunLinuxCmd -username root -password $password -ip $testVMData.PublicIP -port $testVMData.SSHPort -command "/bin/bash GetXsmbXfsTestStatus.sh" -runAsSudo -ignoreLinuxExitCode
			LogMsg "Xfs Test Status : $out"
		}
		$out=RunLinuxCmd -username root -password $password -ip $testVMData.PublicIP -port $testVMData.SSHPort -command "cp -r xfstests /home/$user/, cp -r xfsprogs /home/$user/, tar -cvzf xfstestfull.tar.gz /home/$user/ " -runAsSudo
		RemoteCopy -download -downloadFrom $testVMData.PublicIP -files "xfstest.log,Summary.log,Runtime.log, xfstestfull.tar.gz" -downloadTo $LogDir -port $testVMData.SSHPort -username root -password $password
		LogMsg "Test result : $testResult"
		$resultSummary +=  CreateResultSummary -testResult $testResult -metaData "" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
	}
	catch
	{
		$ErrorMessage =  $_.Exception.Message
		LogMsg "EXCEPTION : $ErrorMessage"   
	}
	Finally
	{
		$metaData = ""
		if (!$testResult)
		{
			$testResult = "Aborted"
		}
		$resultArr += $testResult
	}   
}

else
{
	$testResult = "Aborted"
	$resultArr += $testResult
}

$result = GetFinalResultHeader -resultarr $resultArr

#Clean up the setup
#DoTestCleanUp -result $result -testName $currentTestData.testName -deployedServices $isDeployed
DoTestCleanUp -result $result -testName $currentTestData.testName -deployedServices $isDeployed -ResourceGroups $isDeployed


#Return the result and summery to the test suite script..
return $result
