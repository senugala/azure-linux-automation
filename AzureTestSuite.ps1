#v-shisav : STILL IN BETA VERSION

param($xmlConfig, [string] $Distro, [string] $cycleName, [int] $testIterations)


$user = $xmlConfig.config.Azure.Deployment.Data.UserName
$password = $xmlConfig.config.Azure.Deployment.Data.Password
Set-Variable -Name user -Value $user -Scope Global
Set-Variable -Name password -Value $password -Scope Global
$dtapServerIp = $xmlConfig.config.Azure.Deployment.Data.DTAP.IP

Import-Module .\TestLibs\UtilLibs.psm1 -Force
Import-Module .\TestLibs\RDFELibs.psm1 -Force
Import-Module .\TestLibs\DataBase\DataBase.psm1 -Force
Import-Module .\TestLibs\PerfTest\PerfTest.psm1 -Force

Function CollectLogs()
{}

Function AddReproVMDetailsToHtmlReport()
{
	$reproVMHtmlText += "<br><font size=`"2`"><em>Repro VMs: </em></font>"
	if ( $UserAzureResourceManager )
	{
		foreach ( $vm in $allVMData )
		{
			$reproVMHtmlText += "<br><font size=`"2`">ResourceGroup : $($vm.ResourceGroup), IP : $($vm.PublicIP), SSH : $($vm.SSHPort)</font>"
		}
	}
	else
	{
		foreach ( $vm in $allVMData )
		{
			$reproVMHtmlText += "<br><font size=`"2`">ServiceName : $($vm.ServiceName), IP : $($vm.PublicIP), SSH : $($vm.SSHPort)</font>"
		}
	}
	return $reproVMHtmlText
}

Function GetCurrentCycleData($xmlConfig, $cycleName)
{
	foreach ($Cycle in $xmlConfig.config.testCycles.Cycle )
	{
		if($cycle.cycleName -eq $cycleName)
		{
		return $cycle
		break
		}
	}

}


#This function will check in the xmlConfig for test data and will return the object.
Function GetCurrentTestData($xmlConfig, $testName)
{
	foreach ($test in $xmlConfig.config.testsDefinition.test)
	{
		if ($test.testName -eq $testName)
		{
		LogMsg "Loading the test data for $($test.testName)"
		Set-Variable -Name CurrentTestData -Value $test -Scope Global -Force
		return $test
		break
		}
	}
}

Function RefineTestResult2 ($testResult)
{
	$i=0
	$tempResult = @()
	foreach ($cmp in $testResult)
	{
		if(($cmp -eq "PASS") -or ($cmp -eq "FAIL") -or ($cmp -eq "ABORTED"))
		{
			$tempResult += $testResult[$i]
			$tempResult += $testResult[$i+1]
			$testResult = $tempResult
			break
		}
		$i++;
	}
	return $testResult
}

Function RefineTestResult1 ($tempResult)
{
	foreach ($new in $tempResult)
	{
		$lastObject = $new
	}
	$tempResultSplitted = $lastObject.Split(" ")
	if($tempResultSplitted.Length > 1 )
	{
		Write-Host "Test Result =  $lastObject" -ForegroundColor Gray
	}
	$lastWord = ($tempResultSplitted.Length - 1)

	return $tempResultSplitted[$lastWord]
}

Function RunTestsOnCycle ($cycleName , $xmlConfig, $Distro, $testIterations )
{
	$StartTime = [Datetime]::Now.ToUniversalTime()
	LogMsg "Starting the Cycle - $($CycleName.ToUpper())"
	$executionCount = 0
	$dbEnvironment = "Azure"
	$dbTestCycle = $CycleName.Trim()
	$dbExecutionID = $dbDateTimeUTC = "$($StartTime.Year)-$($StartTime.Month)-$($StartTime.Day) $($StartTime.Hour):$($StartTime.Minute):$($StartTime.Second)"
	$dbLocation = ($xmlConfig.config.Azure.General.Location).Replace('"','').Replace(" ","").ToLower()
	$dbOverrideVMSize = $OverrideVMSize
	if ( $EnableAcceleratedNetworking )
	{
		$dbNetworking = "SRIOV"
	}
	else
	{
		$dbNetworking = "Synthetic"
	}
	foreach ( $tempDistro in $xmlConfig.config.Azure.Deployment.Data.Distro )
	{
		if ( ($tempDistro.Name).ToUpper() -eq ($Distro).ToUpper() )
		{
			if ( $UseAzureResourceManager )
			{
				if ( $tempDistro.ARMImage )
				{
					Set-Variable -Name ARMImage -Value $tempDistro.ARMImage -Scope Global
					LogMsg "ARMImage name - $($ARMImage.Publisher) : $($ARMImage.Offer) : $($ARMImage.Sku) : $($ARMImage.Version)"
					$dbARMImage = "$($ARMImage.Publisher) $($ARMImage.Offer) $($ARMImage.Sku) $($ARMImage.Version)"
				}
				if ( $tempDistro.OsVHD )
				{
					$BaseOsVHD = $tempDistro.OsVHD.Trim()
					Set-Variable -Name BaseOsVHD -Value $BaseOsVHD -Scope Global
					LogMsg "Base VHD name - $BaseOsVHD"
				}
			}
			else
			{
				if ( $tempDistro.OsImage )
				{
					$BaseOsImage = $tempDistro.OsImage.Trim()
					Set-Variable -Name BaseOsImage -Value $BaseOsImage -Scope Global
					LogMsg "Base image name - $BaseOsImage"
				}
			}
		}
	}
	if (!$BaseOsImage  -and !$UseAzureResourceManager)
	{
		Throw "Please give ImageName or OsVHD for ASM deployment."
	}
	if (!$($ARMImage.Publisher) -and !$BaseOSVHD -and $UseAzureResourceManager)
	{
		Throw "Please give ARM Image / VHD for ARM deployment."
	}

	#If Base OS VHD is present in another storage account, then copy to test storage account first.
	if ($BaseOsVHD -imatch "/")
	{
		#Check if the test storage account is same as VHD's original storage account.
		$givenVHDStorageAccount = $BaseOsVHD.Replace("https://","").Replace("http://","").Split(".")[0]
		$ARMStorageAccount = $xmlConfig.config.Azure.General.ARMStorageAccount

		if ($givenVHDStorageAccount -ne $ARMStorageAccount )
		{
			LogMsg "Your test VHD is not in target storage account ($ARMStorageAccount)."
			LogMsg "Your VHD will be copied to $ARMStorageAccount now."
			$sourceContainer =  $BaseOsVHD.Split("/")[$BaseOsVHD.Split("/").Count - 2]
			$vhdName =  $BaseOsVHD.Split("/")[$BaseOsVHD.Split("/").Count - 1]
			if ($ARMStorageAccount -inotmatch "NewStorage_")
			{
				$copyStatus = CopyVHDToAnotherStorageAccount -sourceStorageAccount $givenVHDStorageAccount -sourceStorageContainer $sourceContainer -destinationStorageAccount $ARMStorageAccount -destinationStorageContainer "vhds" -vhdName $vhdName
				if (!$copyStatus)
				{
					Throw "Failed to copy the VHD to $ARMStorageAccount"
				}
				else
				{
					Set-Variable -Name BaseOsVHD -Value $vhdName -Scope Global
					LogMsg "New Base VHD name - $vhdName"
				}
			}
			else
			{
				Throw "Automation only supports copying VHDs to existing storage account."
			}
			#Copy the VHD to current storage account.
		}
	}

	LogMsg "Loading the cycle Data..."

	$currentCycleData = GetCurrentCycleData -xmlConfig $xmlConfig -cycleName $cycleName

	$xmlElementsToAdd = @("currentTest", "stateTimeStamp", "state", "emailSummary", "htmlSummary", "jobID", "testCaseResults")
	foreach($element in $xmlElementsToAdd)
	{
		if (! $testCycle.${element})
		{
			$newElement = $xmlConfig.CreateElement($element)
			$newElement.set_InnerText("")
			$results = $testCycle.AppendChild($newElement)
		}
	}


	$testSuiteLogFile=$logFile
	$testSuiteResultDetails=@{"totalTc"=0;"totalPassTc"=0;"totalFailTc"=0;"totalAbortedTc"=0}
	$id = ""

	# Start JUnit XML report logger.
	$reportFolder = "$pwd/report"
	if(!(Test-Path $reportFolder))
	{
		New-Item -ItemType "Directory" $reportFolder
	}
	StartLogReport("$reportFolder/report_$($testCycle.cycleName).xml")
	$testsuite = StartLogTestSuite "CloudTesting"

	$testCount = $currentCycleData.test.Length
	if (-not $testCount)
	{
		$testCount = 1
	}

	foreach ($test in $currentCycleData.test)
	{
		$originalTest = $test
		if (-not $test)
		{
			$test = $currentCycleData.test
			$originalTest = $test
		}
		if ($RunSelectedTests)
		{
			if ($RunSelectedTests.Trim().Replace(" ","").Split(",") -contains $test.Name)
			{
				$currentTestData = GetCurrentTestData -xmlConfig $xmlConfig -testName $test.Name
				$originalTestName = $currentTestData.testName
				if ( $currentTestData.AdditionalCustomization.Networking -eq "SRIOV" )
				{
					Set-Variable -Name EnableAcceleratedNetworking -Value $true -Scope Global
				}
			}
			else
			{
				LogMsg "Skipping $($test.Name) because it is not in selected tests to run."
				Continue;
			}
		}
		else
		{
			$currentTestData = GetCurrentTestData -xmlConfig $xmlConfig -testName $test.Name
			$originalTestName = $currentTestData.testName
		}
		# Generate Unique Test
		for ( $testIterationCount = 1; $testIterationCount -le $testIterations; $testIterationCount ++ )
		{
			if ( $testIterations -ne 1 )
			{
				$currentTestData.testName = "$($originalTestName)-$testIterationCount"
				$test.Name = "$($originalTestName)-$testIterationCount"
			}
			$server = $xmlConfig.config.global.ServerEnv.Server
			$cluster = $xmlConfig.config.global.ClusterEnv.Cluster
			$rdosVersion = $xmlConfig.config.global.ClusterEnv.RDOSVersion
			$fabricVersion = $xmlConfig.config.global.ClusterEnv.FabricVersion
			$Location = $xmlConfig.config.global.ClusterEnv.Location
			$testId = $currentTestData.TestId
			$testSetup = $currentTestData.setupType
			$lisBuild = $xmlConfig.config.global.VMEnv.LISBuild
			$lisBuildBranch = $xmlConfig.config.global.VMEnv.LISBuildBranch
			$VMImageDetails = $xmlConfig.config.global.VMEnv.VMImageDetails
			$waagentBuild=$xmlConfig.config.global.VMEnv.waagentBuild
			# For the last test running in economy mode, set the IsLastCaseInCycle flag so that the deployments could be cleaned up
			if ($EconomyMode -and $counter -eq ($testCount - 1))
			{
				Set-Variable -Name IsLastCaseInCycle -Value $true -Scope Global
			}
			else
			{
				Set-Variable -Name IsLastCaseInCycle -Value $false -Scope Global
			}
			if ($currentTestData)
			{

				if ( $UseAzureResourceManager -and !($currentTestData.SupportedExecutionModes -imatch "AzureResourceManager"))
				{
					LogMsg "$($currentTestData.testName) does not support AzureResourceManager execution mode."
					continue;
				}
				if (!$UseAzureResourceManager -and !($currentTestData.SupportedExecutionModes -imatch "AzureServiceManagement"))
				{
					LogMsg "$($currentTestData.testName) does not support AzureServiceManagement execution mode."
					continue;
				}
				if(($testPriority -imatch $currentTestData.Priority ) -or (!$testPriority))
				{
					$testcase = StartLogTestCase $testsuite "$($test.Name)" "CloudTesting.$($testCycle.cycleName)"
					$testSuiteResultDetails.totalTc = $testSuiteResultDetails.totalTc +1
					$stopWatch = SetStopWatch
					mkdir $testDir\$($test.Name) -ErrorAction SilentlyContinue | out-null
					Set-Variable -Name currentTestData -Value $currentTestData -Scope Global
					$testCaseLogFile = $testDir + "\" + $($currentTestData.testName) + "\" + "azure_ica.log"
					$global:logFile  = $testCaseLogFile
					if ((!$currentTestData.SubtestValues -and !$currentTestData.TestMode))
					{
						#Tests With No subtests and no SubValues will be executed here..
						try
						{
							$testMode =  "single"
							$testResult = ""
							$LogDir = "$testDir\$($currentTestData.testName)"
							Set-Variable -Name LogDir -Value $LogDir -Scope Global
							LogMsg "~~~~~~~~~~~~~~~TEST STARTED : $($currentTestData.testName)~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
							$testScriptPs1 = $currentTestData.testScriptPs1
							$startTime = [Datetime]::Now.ToUniversalTime()
							$command = ".\remote-scripts\" + $testScriptPs1
							LogMsg "Starting test $($currentTestData.testName)"
							$testResult = Invoke-Expression $command
						}
						catch
						{
							$testResult = "Aborted"
							$ErrorMessage =  $_.Exception.Message
							LogMsg "EXCEPTION : $ErrorMessage"
						}
						finally
						{
							$executionCount += 1
							$testResult = RefineTestResult1 -tempResult $testResult
							$endTime = [Datetime]::Now.ToUniversalTime()
							$vmRam= GetTestVMHardwareDetails -xmlConfigFile $xmlConfig -setupType $testSetup  -RAM
							$vmVcpu = GetTestVMHardwareDetails -xmlConfigFile $xmlConfig -setupType $testSetup  -VCPU
							$testRunDuration = GetStopWatchElapasedTime $stopWatch "mm"
							$testCycle.emailSummary += "$($currentTestData.testName) Execution Time: $testRunDuration minutes<br />"
							$testCycle.emailSummary += "	$($currentTestData.testName) : $testResult <br />"
							$testResultRow = ""
							LogMsg "~~~~~~~~~~~~~~~TEST END : $($currentTestData.testName)~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
							$dbTestName = $($currentTestData.testName)
							$dbTestResult = $testResult
						}
						if($testResult -imatch "PASS")
						{
							$testSuiteResultDetails.totalPassTc = $testSuiteResultDetails.totalPassTc +1
							$testResultRow = "<span style='color:green;font-weight:bolder'>PASS</span>"
							FinishLogTestCase $testcase
							$testCycle.htmlSummary += "<tr><td><font size=`"3`">$executionCount</font></td><td>$($currentTestData.testName)</td><td>$testRunDuration min</td><td>$testResultRow</td></tr>"
						}
						elseif($testResult -imatch "FAIL")
						{
							$testSuiteResultDetails.totalFailTc = $testSuiteResultDetails.totalFailTc +1
							$testResultRow = "<span style='color:red;font-weight:bolder'>FAIL</span>"
							$caseLog = Get-Content -Raw $testCaseLogFile
							FinishLogTestCase $testcase "FAIL" "$($test.Name) failed." $caseLog
							$testCycle.htmlSummary += "<tr><td><font size=`"3`">$executionCount</font></td><td>$($currentTestData.testName)$(AddReproVMDetailsToHtmlReport)</td><td>$testRunDuration min</td><td>$testResultRow</td></tr>"
						}
						elseif($testResult -imatch "ABORTED")
						{
							$testSuiteResultDetails.totalAbortedTc = $testSuiteResultDetails.totalAbortedTc +1
							$testResultRow = "<span style='background-color:yellow;font-weight:bolder'>ABORT</span>"
							$caseLog = Get-Content -Raw $testCaseLogFile
							FinishLogTestCase $testcase "ERROR" "$($test.Name) is aborted." $caseLog
							$testCycle.htmlSummary += "<tr><td><font size=`"3`">$executionCount</font></td><td>$($currentTestData.testName)$(AddReproVMDetailsToHtmlReport)</td><td>$testRunDuration min</td><td>$testResultRow</td></tr>"
						}
						else
						{
							LogErr "Test Result is empty."
							$testSuiteResultDetails.totalAbortedTc = $testSuiteResultDetails.totalAbortedTc +1
							$caseLog = Get-Content -Raw $testCaseLogFile
							$testResultRow = "<span style='background-color:yellow;font-weight:bolder'>ABORT</span>"
							FinishLogTestCase $testcase "ERROR" "$($test.Name) is aborted." $caseLog
							$testCycle.htmlSummary += "<tr><td><font size=`"3`">$executionCount</font></td><td>$tempHtmlText$(AddReproVMDetailsToHtmlReport)</td><td>$testRunDuration min</td><td>$testResultRow</td></tr>"
						}
					}
					else
					{
						try
						{
							$testMode =  "multi"
							$testResult = @()
							$LogDir = "$testDir\$($currentTestData.testName)"
							Set-Variable -Name LogDir -Value $LogDir -Scope Global
							LogMsg "~~~~~~~~~~~~~~~TEST STARTED : $($currentTestData.testName)~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
							$testScriptPs1 = $currentTestData.testScriptPs1
							$command = ".\remote-scripts\" + $testScriptPs1
							LogMsg "$command"
							LogMsg "Starting multiple tests : $($currentTestData.testName)"
							$startTime = [Datetime]::Now.ToUniversalTime()
							$testResult = Invoke-Expression $command
						}
						catch
						{
							$testResult[0] = "ABORTED"
							$ErrorMessage =  $_.Exception.Message
							LogMsg "EXCEPTION : $ErrorMessage"
						}
						finally
						{
							$testResult = RefineTestResult2 -testResult $testResult
							try {
								$tempHtmlText = ($testResult[1]).Substring(0,((($testResult[1]).Length)-6))
							}
							catch {
								$tempHtmlText = "Unable to parse the results. Will be fixed shortly."
							}
							$executionCount += 1
							$testRunDuration = GetStopWatchElapasedTime $stopWatch "mm"
							$testRunDuration = $testRunDuration.ToString()
							$testCycle.emailSummary += "$($currentTestData.testName) Execution Time: $testRunDuration minutes<br />"
							$testCycle.emailSummary += "	$($currentTestData.testName) : $($testResult[0])  <br />"
							$testCycle.emailSummary += "$($testResult[1])"
							$summary = "$($testResult[1])"
							LogMsg "~~~~~~~~~~~~~~~TEST END : $($currentTestData.testName)~~~~~~~~~~"
						}
						if($testResult[0] -imatch "PASS")
						{
							$testSuiteResultDetails.totalPassTc = $testSuiteResultDetails.totalPassTc +1
							$testResultRow = "<span style='color:green;font-weight:bolder'>PASS</span>"
							FinishLogTestCase $testcase
							$testCycle.htmlSummary += "<tr><td><font size=`"3`">$executionCount</font></td><td>$tempHtmlText</td><td>$testRunDuration min</td><td>$testResultRow</td></tr>"
						}
						elseif($testResult[0] -imatch "FAIL")
						{
							$testSuiteResultDetails.totalFailTc = $testSuiteResultDetails.totalFailTc +1
							$caseLog = Get-Content -Raw $testCaseLogFile
							$testResultRow = "<span style='color:red;font-weight:bolder'>FAIL</span>"
							FinishLogTestCase $testcase "FAIL" "$($test.Name) failed." $caseLog
							$testCycle.htmlSummary += "<tr><td><font size=`"3`">$executionCount</font></td><td>$tempHtmlText$(AddReproVMDetailsToHtmlReport)</td><td>$testRunDuration min</td><td>$testResultRow</td></tr>"
						}
						elseif($testResult[0] -imatch "ABORTED")
						{
							$testSuiteResultDetails.totalAbortedTc = $testSuiteResultDetails.totalAbortedTc +1
							$caseLog = Get-Content -Raw $testCaseLogFile
							$testResultRow = "<span style='background-color:yellow;font-weight:bolder'>ABORT</span>"
							FinishLogTestCase $testcase "ERROR" "$($test.Name) is aborted." $caseLog
							$testCycle.htmlSummary += "<tr><td><font size=`"3`">$executionCount</font></td><td>$tempHtmlText$(AddReproVMDetailsToHtmlReport)</td><td>$testRunDuration min</td><td>$testResultRow</td></tr>"
						}
						else
						{
							LogErr "Test Result is empty."
							$testSuiteResultDetails.totalAbortedTc = $testSuiteResultDetails.totalAbortedTc +1
							$caseLog = Get-Content -Raw $testCaseLogFile
							$testResultRow = "<span style='background-color:yellow;font-weight:bolder'>ABORT</span>"
							FinishLogTestCase $testcase "ERROR" "$($test.Name) is aborted." $caseLog
							$testCycle.htmlSummary += "<tr><td><font size=`"3`">$executionCount</font></td><td>$tempHtmlText$(AddReproVMDetailsToHtmlReport)</td><td>$testRunDuration min</td><td>$testResultRow</td></tr>"
						}
					}
					if ($xmlSecrets)
					{
						try
						{
							$testLogFolder = "TestLogs"
							$testLogStorageAccount = $xmlSecrets.secrets.testLogsStorageAccount
							$testLogStorageAccountKey = $xmlSecrets.secrets.testLogsStorageAccountKey
							$ticks= (Get-Date).Ticks
							$uploadFileName = ".\temp\$($currentTestData.testName)-$ticks.zip"
							$out = ZipFiles -zipfilename $uploadFileName -sourcedir $LogDir
							$uploadLink = .\Extras\UploadFilesToStorageAccount.ps1 -filePaths $uploadFileName -destinationStorageAccount $testLogStorageAccount -destinationContainer "logs" -destinationFolder "$testLogFolder" -destinationStorageKey $testLogStorageAccountKey
							$utctime = (Get-Date).ToUniversalTime()
							$dbDateTimeUTC = "$($utctime.Year)-$($utctime.Month)-$($utctime.Day) $($utctime.Hour):$($utctime.Minute):$($utctime.Second)"
							$dataSource = $xmlSecrets.secrets.DatabaseServer
							$dbuser = $xmlSecrets.secrets.DatabaseUser
							$dbpassword = $xmlSecrets.secrets.DatabasePassword
							$database = $xmlSecrets.secrets.DatabaseName
							$dataTableName = "AzureTestResultsMasterTable"
							$dbTestName = $($currentTestData.testName)
							$SQLQuery = "INSERT INTO $dataTableName (DateTimeUTC,Environment,TestCycle,ExecutionID,TestName,TestResult,ARMImage,OsVHD,KernelVersion,LISVersion,GuestDistro,AzureHost,Location,OverrideVMSize,Networking,LogFile,BuildURL) VALUES "
							if ($testMode -eq "multi")
							{
								$SQLQuery += "('$dbDateTimeUTC','$dbEnvironment','$dbTestCycle','$dbExecutionID','$dbTestName','$($testResult[0])','$dbARMImage','$BaseOsVHD','$finalKernelVersion','$finalLISVersion','$GuestDistro','$HostVersion','$dbLocation','$dbOverrideVMSize','$dbNetworking','$uploadLink', '$env:BUILD_URL`consoleFull'),"
								foreach ($tempResult in $summary.Split('>'))
								{
									if ($tempResult)
									{
										$tempResult = $tempResult.Trim().Replace("<br /","").Trim()
										$subTestResult = $tempResult.Split(":")[$tempResult.Split(":").Count -1 ].Trim()
										$subTestName = $tempResult.Replace("$subTestResult","").Trim().TrimEnd(":").Trim()
										$SQLQuery += "('$dbDateTimeUTC','$dbEnvironment','$dbTestCycle','$dbExecutionID','SubTest-$subTestName','$subTestResult','$dbARMImage','$BaseOsVHD','$finalKernelVersion','$finalLISVersion','$GuestDistro','$HostVersion','$dbLocation','$dbOverrideVMSize','$dbNetworking', '$uploadLink', '$env:BUILD_URL`consoleFull'),"
									}
								}
							}
							elseif ( $testMode -eq "single")
							{
								$dbTestResult = $testResult
								$SQLQuery += "('$dbDateTimeUTC','$dbEnvironment','$dbTestCycle','$dbExecutionID','$dbTestName','$dbTestResult','$dbARMImage','$BaseOsVHD','$finalKernelVersion','$finalLISVersion','$GuestDistro','$HostVersion','$dbLocation','$dbOverrideVMSize','$dbNetworking', '$uploadLink', '$env:BUILD_URL`consoleFull')"
							}
							$SQLQuery = $SQLQuery.TrimEnd(',')
							$connectionString = "Server=$dataSource;uid=$dbuser; pwd=$dbpassword;Database=$database;Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30;"
							$connection = New-Object System.Data.SqlClient.SqlConnection
							$connection.ConnectionString = $connectionString
							$connection.Open()
							$command = $connection.CreateCommand()
							$command.CommandText = $SQLQuery
							$result = $command.executenonquery()
							$connection.Close()
							LogMsg "Uploading test results to database :  done!!"
						}
						catch
						{
							LogErr "Uploading test results to database :  ERROR"
							LogMsg $SQLQuery
						}
					}
					Write-Host $testSuiteResultDetails.totalPassTc,$testSuiteResultDetails.totalFailTc,$testSuiteResultDetails.totalAbortedTc
					#Back to Test Suite Main Logging
					$global:logFile = $testSuiteLogFile
					$currentJobs = Get-Job
					foreach ( $job in $currentJobs )
					{
						$jobStatus = Get-Job -Id $job.ID
						if ( $jobStatus.State -ne "Running" )
						{
							Remove-Job -Id $job.ID -Force
							if ( $? )
							{
								LogMsg "Removed $($job.State) background job ID $($job.Id)."
							}
						}
						else
						{
							LogMsg "$($job.Name) is running."
						}
					}
				}
				else
				{
					LogMsg "Skipping $($currentTestData.Priority) test : $($currentTestData.testName)"
				}
			}
			else
			{
				LogErr "No Test Data found for $($test.Name).."
			}
		}
	}

	LogMsg "Checking background cleanup jobs.."
	$cleanupJobList = Get-Job | where { $_.Name -imatch "DeleteResourceGroup"}
	$isAllCleaned = $false
	while(!$isAllCleaned)
	{
		$runningJobsCount = 0
		$isAllCleaned = $true
		$cleanupJobList = Get-Job | where { $_.Name -imatch "DeleteResourceGroup"}
		foreach ( $cleanupJob in $cleanupJobList )
		{

			$jobStatus = Get-Job -Id $cleanupJob.ID
			if ( $jobStatus.State -ne "Running" )
			{

				$tempRG = $($cleanupJob.Name).Replace("DeleteResourceGroup-","")
				LogMsg "$tempRG : Delete : $($jobStatus.State)"
				Remove-Job -Id $cleanupJob.ID -Force
			}
			else
			{
				LogMsg "$($cleanupJob.Name) is running."
				$isAllCleaned = $false
				$runningJobsCount += 1
			}
		}
		if ($runningJobsCount -gt 0)
		{
			Write-Host "$runningJobsCount background cleanup jobs still running. Waiting 30 seconds..."
			sleep -Seconds 30
		}
	}
	Write-Host "All background cleanup jobs finished."
	$azureContextFiles = Get-Item "$env:TEMP\*.azurecontext"
	$out = $azureContextFiles | Remove-Item -Force | Out-Null
	LogMsg "Removed $($azureContextFiles.Count) context files."
	LogMsg "Cycle Finished.. $($CycleName.ToUpper())"
	$EndTime =  [Datetime]::Now.ToUniversalTime()

	FinishLogTestSuite($testsuite)
	FinishLogReport

	$testSuiteResultDetails
}

RunTestsOnCycle -cycleName $cycleName -xmlConfig $xmlConfig -Distro $Distro -testIterations $testIterations
