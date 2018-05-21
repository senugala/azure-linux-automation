﻿<#-------------Create Deployment Start------------------#>
Import-Module .\TestLibs\RDFELibs.psm1 -Force
$result = ""
$testResult = ""
$resultArr = @()


$isDeployed = DeployVMS -setupType $currentTestData.setupType -Distro $Distro -xmlConfig $xmlConfig
if ($isDeployed)
{
	try
	{
		LogMsg "Check 1: Checking call tracess again after 30 seconds sleep"
		Start-Sleep 30
		$noIssues = CheckKernelLogs -allVMData $allVMData
		if ($noIssues)
		{
			$RestartStatus = RestartAllDeployments -allVMData $allVMData
			if($RestartStatus -eq "True")
			{
				LogMsg "Check 2: Checking call tracess again after Reboot > 30 seconds sleep"
				Start-Sleep 30
				$noIssues = CheckKernelLogs -allVMData $allVMData
				if ($noIssues)
				{
					LogMsg "Test Result : PASS."
					$testResult = "PASS"
				}
				else
				{
					LogMsg "Test Result : FAIL."
					$testResult = "FAIL"
				}
			}
			else
			{
				LogMsg "Test Result : FAIL."
				$testResult = "FAIL"
			}
		}
		else
		{
			LogMsg "Test Result : FAIL."
			$testResult = "FAIL"
		}
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
#$resultSummary +=  CreateResultSummary -testResult $testResult -metaData $metaData -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName# if you want to publish all result then give here all test status possibilites. if you want just failed results, then give here just "FAIL". You can use any combination of PASS FAIL ABORTED and corresponding test results will be published!
	}
}

else
{
	$testResult = "FAIL"
	$resultArr += $testResult
}

$result = GetFinalResultHeader -resultarr $resultArr

#Clean up the setup
DoTestCleanUp -result $result -testName $currentTestData.testName -deployedServices $isDeployed -ResourceGroups $isDeployed

#Return the result and summery to the test suite script..
return $result
