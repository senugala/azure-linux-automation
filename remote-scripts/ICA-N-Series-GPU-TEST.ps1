<#-------------Create Deployment Start------------------#>
Import-Module .\TestLibs\RDFELibs.psm1 -Force
$result = ""
$testResult = ""
$resultArr = @()
Set-Variable -Name OverrideVMSize -Value $currentTestData.OverrideVMSize -Scope Global
$isDeployed = DeployVMS -setupType $currentTestData.setupType -Distro $Distro -xmlConfig $xmlConfig
if ($isDeployed)
{
	try
	{
        $testResult = $null
		$clientVMData = $allVMData
		#region CONFIGURE VM FOR N SERIES GPU TEST
		LogMsg "Test VM details :"
		LogMsg "  RoleName : $($clientVMData.RoleName)"
		LogMsg "  Public IP : $($clientVMData.PublicIP)"
		LogMsg "  SSH Port : $($clientVMData.SSHPort)"
		#
		# PROVISION VMS FOR LISA WILL ENABLE ROOT USER AND WILL MAKE ENABLE PASSWORDLESS AUTHENTICATION ACROSS ALL VMS IN SAME HOSTED SERVICE.	
		#

		ProvisionVMsForLisa -allVMData $allVMData -installPackagesOnRoleNames "none"
        
		#endregion

		#region Install N-Vidia Drivers and reboot.
		$myString = @"
cd /root/
./GPU_Test.sh -logFolder /root &> GPUConsoleLogs.txt
. azuremodules.sh
collect_VM_properties
"@
        $StartScriptName = "StartGPUDriverInstall.sh"
		Set-Content "$LogDir\$StartScriptName" $myString
		RemoteCopy -uploadTo $clientVMData.PublicIP -port $clientVMData.SSHPort -files ".\remote-scripts\azuremodules.sh,.\remote-scripts\GPU_Test.sh,.\$LogDir\$StartScriptName" -username "root" -password $password -upload
		$out = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "chmod +x *.sh"
		$testJob = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "/root/$StartScriptName" -RunInBackground
		#endregion

		#region MONITOR TEST
		while ( (Get-Job -Id $testJob).State -eq "Running" )
		{
			$currentStatus = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "tail -n 1 GPUConsoleLogs.txt"
			LogMsg "Current Test Staus : $currentStatus"
			WaitFor -seconds 20
		}

        RemoteCopy -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "VM_properties.csv"
        RemoteCopy -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "GPUConsoleLogs.txt"
        

		$GPUDriverInstallLogs = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "cat GPU_Test_Logs.txt"

        if ($GPUDriverInstallLogs -imatch "GPU_DRIVER_INSTALLATION_SUCCESSFUL")
        {
            #Reboot VM.
            LogMsg "*********************************************************"
            LogMsg "GPU Drivers installed successfully. Restarting VM now..."
            LogMsg "*********************************************************"
            $restartStatus = RestartAllDeployments -allVMData $clientVMData
            if ($restartStatus -eq "True")
            {
                if (($clientVMData.InstanceSize -eq "Standard_NC6") -or ($clientVMData.InstanceSize -eq "Standard_NC6s_v2") -or ($clientVMData.InstanceSize -eq "Standard_NV6")) 
                {
                    $expectedCount = 1
                }
                elseif (($clientVMData.InstanceSize -eq "Standard_NC12") -or ($clientVMData.InstanceSize -eq "Standard_NC12s_v2") -or ($clientVMData.InstanceSize -eq "Standard_NV12"))
                {
                    $expectedCount = 2
                }
                elseif (($clientVMData.InstanceSize -eq "Standard_NC24") -or ($clientVMData.InstanceSize -eq "Standard_NC24s_v2") -or ($clientVMData.InstanceSize -eq "Standard_NV24"))
                {
                    $expectedCount = 4
                }
                elseif (($clientVMData.InstanceSize -eq "Standard_NC24r") -or ($clientVMData.InstanceSize -eq "Standard_NC24rs_v2"))
                {
                    $expectedCount = 4
                }	
                LogMsg "Test VM Size: $($clientVMData.InstanceSize). Expected GPU Adapters : $expectedCount"	
                $errorCount = 0
                #Adding sleep of 180 seconds, giving time to load nvidia drivers.
                LogMsg "Waiting 3 minutes. (giving time to load nvidia drivers)"
                Start-Sleep -Seconds 180
                #region PCI Express pass-through
                $PCIExpress = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "lsvmbus" -ignoreLinuxExitCode
                Set-Content -Value $PCIExpress -Path $LogDir\PIC-Express-pass-through.txt -Force
                if ( (Select-String -Path $LogDir\PIC-Express-pass-through.txt -Pattern "PCI Express pass-through").Matches.Count -eq $expectedCount )
                {
                    LogMsg "Expected `"PCI Express pass-through`" count: $expectedCount. Observed Count: $expectedCount"
                    $resultSummary +=  CreateResultSummary -testResult "PASS" -metaData "PCI Express pass-through" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
                }
                else
                {
                    $errorCount += 1
                    LogErr "Error in lsvmbus Outoput."
                    LogErr "$PCIExpress"
                    $resultSummary +=  CreateResultSummary -testResult "FAIL" -metaData "PCI Express pass-through" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
                }
                 #endregion

                #region lspci
                $lspci = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "lspci" -ignoreLinuxExitCode
                Set-Content -Value $lspci -Path $LogDir\lspci.txt -Force
                if ( (Select-String -Path $LogDir\lspci.txt -Pattern "NVIDIA Corporation").Matches.Count -eq $expectedCount )
                {
                    LogMsg "Expected `"3D controller: NVIDIA Corporation`" count: $expectedCount. Observed Count: $expectedCount"
                    $resultSummary +=  CreateResultSummary -testResult "PASS" -metaData "lspci" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
                }
                else
                {
                    $errorCount += 1
                    LogErr "Error in lspci Outoput."
                    LogErr "$lspci"
                    $resultSummary +=  CreateResultSummary -testResult "FAIL" -metaData "lspci" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
                }

                #endregion

                #region PCI lshw -c video
                $lshw = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "lshw -c video" -ignoreLinuxExitCode
                Set-Content -Value $lshw -Path $LogDir\lshw-c-video.txt -Force
                if ( ((Select-String -Path $LogDir\lshw-c-video.txt -Pattern "product: NVIDIA Corporation").Matches.Count -eq $expectedCount) -or ((Select-String -Path $LogDir\lshw-c-video.txt -Pattern "vendor: NVIDIA Corporation").Matches.Count -eq $expectedCount) )
                {
                    LogMsg "Expected Display adapters: $expectedCount. Observed adapters: $expectedCount"
                    $resultSummary +=  CreateResultSummary -testResult "PASS" -metaData "lshw -c video" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
                }
                else
                {
                    $errorCount += 1
                    LogErr "Error in display adapters."
                    LogErr "$lshw"
                    $resultSummary +=  CreateResultSummary -testResult "FAIL" -metaData "lshw -c video" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
                }

                #endregion

                #region PCI nvidia-smi
                $nvidiasmi = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "nvidia-smi" -ignoreLinuxExitCode
                Set-Content -Value $nvidiasmi -Path $LogDir\nvidia-smi.txt -Force
                if ( (Select-String -Path $LogDir\nvidia-smi.txt -Pattern "Tesla ").Matches.Count -eq $expectedCount )
                {
                    LogMsg "Expected Tesla count: $expectedCount. Observed count: $expectedCount"
                    $resultSummary +=  CreateResultSummary -testResult "PASS" -metaData "nvidia-smi" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
                }
                else
                {
                    $errorCount += 1
                    LogErr "Error in nvidia-smi."
                    LogErr "$nvidiasmi"
                    $resultSummary +=  CreateResultSummary -testResult "FAIL" -metaData "nvidia-smi" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
                }
                #endregion
            }
            else
            {
                LogErr "Unable to connect to test VM after restart"
                $testResult = "FAIL"
            }
		}
        else
        {

        }
		#endregion

		if ( ($errorCount -ne 0))
		{
			LogErr "Test failed. : $summary."
			$testResult = "FAIL"
		}
		elseif ( $errorCount -eq 0)
		{
			LogMsg "Test Completed."
			$testResult = "PASS"
		}
		LogMsg "Test result : $testResult"
		LogMsg "Test Completed"
	}
	catch
	{
		$ErrorMessage =  $_.Exception.Message
		LogMsg "EXCEPTION : $ErrorMessage"   
	}
	Finally
	{
		$metaData = "GPU Verification"
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
DoTestCleanUp -result $result -testName $currentTestData.testName -deployedServices $isDeployed -ResourceGroups $isDeployed

#Return the result and summery to the test suite script..
return $result, $resultSummary
