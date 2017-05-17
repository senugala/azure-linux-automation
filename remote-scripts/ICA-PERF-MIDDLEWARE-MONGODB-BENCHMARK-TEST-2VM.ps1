﻿<#-------------Create Deployment Start------------------#>
Import-Module .\TestLibs\RDFELibs.psm1 -Force
$result = ""
$testResult = ""
$resultArr = @()
$threads=$currentTestData.TestParameters.param

$isDeployed = DeployVMS -setupType $currentTestData.setupType -Distro $Distro -xmlConfig $xmlConfig
if ($isDeployed)
{
	try
	{
		$noServer = $true
		$noClient = $true
		foreach ( $vmData in $allVMData )
		{
			if ( $vmData.RoleName -imatch "Server" )
			{
                $serverVMData = $vmData
				$noServer = $false
			}
			elseif ( $vmData.RoleName -imatch "Client" )
			{
				$clientVMData = $vmData
				$noClient = $fase
			}
		}
		if ( $noServer )
		{
			Throw "No any server VM defined. Be sure that, server VM role name matches with the pattern `"*server*`". Aborting Test."
		}
		if ( $noSlave )
		{
			Throw "No any client VM defined. Be sure that, client machine role names matches with pattern `"*client*`" Aborting Test."
		}
		#region CONFIGURE VMs for TEST

		LogMsg "CLIENT VM details :"
		LogMsg "  RoleName : $($clientVMData.RoleName)"
		LogMsg "  Public IP : $($clientVMData.PublicIP)"
		LogMsg "  SSH Port : $($clientVMData.SSHPort)"
		LogMsg "SERVER VM details :"
		LogMsg "  RoleName : $($serverVMData.RoleName)"
		LogMsg "  Public IP : $($serverVMData.PublicIP)"
		LogMsg "  SSH Port : $($serverVMData.SSHPort)"
		
		#
		# PROVISION VMS FOR LISA WILL ENABLE ROOT USER AND WILL MAKE ENABLE PASSWORDLESS AUTHENTICATION ACROSS ALL VMS IN SAME HOSTED SERVICE.	
		#
		##ProvisionVMsForLisa -allVMData $allVMData
		
		#endregion
		
		$mdXMLData = [xml](Get-Content -Path ".\XML\Perf_Middleware_MangoDB_2VM.xml") 

		LogMsg "Generating constansts.sh ..."
		$constantsFile = "$LogDir\constants.sh"
		Set-Content -Value "#Generated by Azure Automation." -Path $constantsFile
		foreach ($mdParam in $mdXMLData.config.testCases.test.testParams.param )
		{
			if ($mdParam -imatch "MD_SERVER")
			{
				Add-Content -Value "MD_SERVER=$($serverVMData.InternalIP)" -Path $constantsFile
				LogMsg "MD_SERVER=$($serverVMData.InternalIP) added to constansts.sh"
			}
			else
			{
				Add-Content -Value "$mdParam" -Path $constantsFile
				LogMsg "$mdParam added to constansts.sh"
			}
		}
		foreach ($testParam in $currentTestData.TestParameters.param )
		{
			Add-Content -Value "$testParam" -Path $constantsFile
			LogMsg "$testParam added to constansts.sh"
		}
		LogMsg "constanst.sh created successfully..."

		LogMsg "Generating MongoDB workload file ..."
		$workloadFile = "$LogDir\workloadAzure"
		Set-Content -Value "#Generated by Azure Automation." -Path $workloadFile
		foreach ($mdParam in $mdXMLData.config.testCases.test.testParams.mdparam )
		{
			Add-Content -Value "$mdParam" -Path $workloadFile 
			LogMsg "$mdParam added to workloadAzure"
		}		
		LogMsg "workloadAzure file created successfully..."
		#endregion

		#region EXECUTE TEST
		Set-Content -Value "/root/performance_middleware_mongod.sh &> mongodClientConsoleLogs.txt" -Path "$LogDir\StartMONGODTest.sh"
		$out = RemoteCopy -uploadTo $clientVMData.PublicIP -port $clientVMData.SSHPort -files ".\$constantsFile,.\remote-scripts\performance_middleware_mongod.sh,.\remote-scripts\run-ycsb.sh,.\$LogDir\StartMONGODTest.sh,.\$LogDir\workloadAzure" -username "root" -password $password -upload  2>&1 | Out-Null
		$out = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "chmod +x *.sh"
		$testJob = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "/root/StartMONGODTest.sh" -RunInBackground
		#endregion

		#region MONITOR TEST
		while ( (Get-Job -Id $testJob).State -eq "Running" )
		{
			$currentStatus = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "tail -n 1 /root/mongodClientConsoleLogs.txt"
			$testEndStatus = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "cat /root/mongodClientConsoleLogs.txt | grep 'TEST END' | tail -1"
			if($testEndStatus -imatch "TEST END")
			{
				$testStartStatus = "TEST START WITH NEXT THREAD"
			}
			$testStartStatus = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "cat /root/mongodClientConsoleLogs.txt | grep 'TEST RUNNING' | tail -1"
			LogMsg "Current Test Staus : $testEndStatus $testStartStatus `n $currentStatus"
			WaitFor -seconds 10
		}
		
		$out = RemoteCopy -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "/root/mongodClientConsoleLogs.txt"  2>&1 | Out-Null
		$out = RemoteCopy -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "/root/summary.log,/root/state.txt"  2>&1 | Out-Null
		$finalStatus = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "cat /root/state.txt"
		$mdSummary = Get-Content -Path "$LogDir\summary.log" -ErrorAction SilentlyContinue

		if ($finalStatus -imatch "TestCompleted")
		{
			$threads = $currentTestData.TestParameters.param
			$threads = $threads.Replace("test_threads_collection=",'').Replace("(","").Replace(")","").Replace("  "," ").Replace("  "," ").Replace("  "," ").Replace(" ",",")

			foreach ($thread in $threads.Split(","))
			{
				$threadStatus = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "cat /root/benchmark/mongodb/logs/$thread/$thread-mongodb.ycsb.run.log | grep 'OVERALL], Throughput'" -ignoreLinuxExitCode
				if (($threadStatus -imatch 'OVERALL') -and ($threadStatus -imatch 'Throughput'))
				{
					$overallThroghput = $threadStatus.Trim().Split()[2].Trim()
					$metaData = "$thread threads:  overallThroghput"
					$resultSummary +=  CreateResultSummary -testResult $overallThroghput -metaData $metaData -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
				}
				else
				{
					$resultSummary +=  CreateResultSummary -testResult "ERROR: Result not found. Possible test error." -metaData $testType -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
				}
			} 
		}
		else
		{
			$overallThroghput = ""
		 }
		#endregion
		
		
		if (!$mdSummary)
		{
			LogMsg "summary.log file is empty."
			$mdSummary = $finalStatus
		}
		if ( $finalStatus -imatch "TestFailed")
		{
			LogErr "Test failed. Last known status : $currentStatus."
			$testResult = "FAIL"
		}
		elseif ( $finalStatus -imatch "TestAborted")
		{
			LogErr "Test Aborted. Last known status : $currentStatus."
			$testResult = "ABORTED"
		}
		elseif ( $finalStatus -imatch "TestCompleted")
		{
			LogMsg "Test Completed. Result : $finalStatus."
			
			foreach ($thread in $threads.Split(","))
			{	
				mkdir $LogDir\$($clientVMData.RoleName)\$($thread) -Force| out-null
				RemoteCopy -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir\$($clientVMData.RoleName)\$($thread) -files "/root/benchmark/mongodb/logs/$($thread)/$($thread)-mongodb-client*"  2>&1 | Out-Null
				mkdir  $LogDir\$($serverVMData.RoleName)\$($thread) -Force| out-null
				RemoteCopy -downloadFrom $clientVMData.PublicIP -port $serverVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir\$($serverVMData.RoleName)\$($thread) -files "/root/benchmark/mongodb/logs/$($thread)/$($thread)-mongodb-server*"  2>&1 | Out-Null
				RemoteCopy -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "/root/benchmark/mongodb/logs/$($thread)/$($thread)-mongodb.ycsb.run.log"  2>&1 | Out-Null
			}
			RemoteCopy -downloadFrom $clientVMData.PublicIP -port $serverVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "/root/mongodServerConsole.txt"  2>&1 | Out-Null
			$testResult = "PASS"
		}
		elseif ( $finalStatus -imatch "TestRunning")
		{
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
DoTestCleanUp -result $result -testName $currentTestData.testName -deployedServices $isDeployed -ResourceGroups $isDeployed

#Return the result and summery to the test suite script..
return $result, $resultSummary