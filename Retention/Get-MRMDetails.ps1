﻿# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

#
# Get-MRMDetails.ps1
# Version: v2.0

# Syntax for running this script:
#
# .\Get-MRMDetails.ps1 -Mailbox <user>
#
# Example:
#
# .\Get-MRMDetails.ps1 -Mailbox rob@contoso.com
#

param (
    [Parameter(Mandatory = $true, HelpMessage = 'You must specify the name of a mailbox user')][string] $Mailbox
)

$ErrorActionPreference = 'SilentlyContinue'

function funcRetentionProperties {
    # Export's All Retention Policies and Retention Policy Tags for the entire tenant
    Get-RetentionPolicy | Select-Object * | Export-Clixml "$Mailbox - MRM Retention Policies for entire Tenant.xml"
    [array]$Tags = Get-RetentionPolicyTag
    #Next line adds new property to each object in the array.
    $Tags = $Tags | Add-Member @{OctetRetentionIDAsSeenInMFCMAPI = "" } -PassThru
    foreach ($t in $Tags) {
        #Convert each GUID to the Octet version that is seen in MFCMAPI's Properties
        $t.OctetRetentionIDAsSeenInMFCMAPI = [System.String]::Join("", ($t.RetentionId.ToByteArray() | ForEach-Object { $_.ToString('x2') })).ToUpper()
    }
    $Tags | Select-Object * | Export-Clixml "$Mailbox - MRM Retention Policies for entire Tenant.xml"

    # Export the users mailbox information
    $MailboxProps | Select-Object * | Out-File "$Mailbox - Mailbox Information.txt"
    $MbxStatistics = get-MailboxStatistics $MailboxProps.ExchangeGuid.guid.ToString()
    #4 quotas of concern - total mailbox, recoverable mailbox, total archive, recoverable archive
    [string]$tempState = $MailboxProps.ProhibitSendReceiveQuota.split("(")[1]
    # Not Used Yet [long]$MbxQuota = $tempState.split("bytes")[0]
    $tempState = $MailboxProps.RecoverableItemsQuota.split("(")[1]
    [long]$MbxRIQuota = $tempState.split("bytes")[0]
    $tempState = $MbxStatistics.TotalItemSize.value.ToString().split("(")[1]
    [long]$MbxTotalSize = $tempState.split("bytes")[0]
    $tempState = $MbxStatistics.TotalDeletedItemSize.value.ToString().split("(")[1]
    [long]$MbxDeletedSize = $tempState.split("bytes")[0]
    # Not Used Yet [int]$PercentOfPrimaryMBXQuota = $MbxTotalSize / $MbxQuota * 100
    [int]$PercentOfPrimaryMbxRiQuota = $MbxDeletedSize / $MbxRIQuota * 100

    if (($NULL -ne $MailboxProps.ArchiveDatabase) -and ($MailboxProps.ArchiveGuid -ne "00000000-0000-0000-0000-000000000000")) {
        #		$ArchiveMbxProps = get-mailbox $MailboxProps.ExchangeGuid.guid -archive
        $ArchiveMbxStats = get-MailboxStatistics $MailboxProps.ExchangeGuid.guid -archive

        [string]$tempState = $MailboxProps.ArchiveQuota.split("(")[1]
        [long]$ArchiveMbxQuota = $tempState.split("bytes")[0]
        #Archive Mailbox Recoverable Items quota does not appear to be visible to admins in PowerShell.  However, recoverable Items quota can be inferred from 3 properties
        #Those properties are the RecoverableItemsQuota of the primary mailbox, Litigation Hold and In-Place Hold.  https://technet.microsoft.com/en-us/library/mt668450.aspx
        [long]$ArchiveMbxRIQuota = $MbxRIQuota

        $tempState = $ArchiveMbxStats.TotalItemSize.value.ToString().split("(")[1]
        [long]$ArchiveMbxTotalSize = $tempState.split("bytes")[0]
        $tempState = $ArchiveMbxStats.TotalDeletedItemSize.value.ToString().split("(")[1]
        [long]$ArchiveMbxDeletedSize = $tempState.split("bytes")[0]
        [int]$PrimaryArchiveTotalFillPercentage = $ArchiveMbxTotalSize / $ArchiveMbxQuota * 100
        [int]$PrimaryArchiveRIFillPercentage = $ArchiveMbxDeletedSize / $ArchiveMbxRIQuota * 100
    }
    # Get the Diagnostic Logs for user
    $logProps = Export-MailboxDiagnosticLogs $Mailbox -ExtendedProperties
    $xmlProps = [xml]($logProps.MailboxLog)
    $ELCRunLastData = $xmlProps.Properties.MailboxTable.Property | Where-Object { $_.Name -like "*elc*" }
    [DateTime]$ELCLastSuccess = [DateTime](($ELCRunLastData | Where-Object { $_.name -eq "ELCLastSuccessTimestamp" }).value)

    # Get the Component Diagnostic Logs for user
    $error.Clear()
    $ELCLastRunFailure = (Export-MailboxDiagnosticLogs $Mailbox -ComponentName MRM).MailboxLog
    ($error[0]).Exception | Out-File "$Mailbox - MRM Component Diagnostic Logs.txt" -Append
    if ($NULL -ne $ELCLastRunFailure) {
        $ELCLastRunFailure | Out-File "$Mailbox - MRM Component Diagnostic Logs.txt"
        [DateTime]$ELCLastFailure = [DateTime]$ELCLastRunFailure.MailboxLog.split("Exception")[0]
        if ($ELCLastSuccess -gt $ELCLastFailure) {
            "MRM has run successfully since the last failure.  This makes the Component Diagnostic Logs file much less interesting.
		----------------------------------------------------------------------------------------------------------------------
		" | Out-File "$Mailbox - Mailbox Diagnostic Logs.txt"
            $ELCRunLastData | Out-File "$Mailbox - Mailbox Diagnostic Logs.txt" -Append
            "MRM has run successfully since the failure recorded in this file.  This failure is much less interesting.
		----------------------------------------------------------------------------------------------------------------------
		" | Out-File "$Mailbox - MRM Component Diagnostic Logs.txt"
            $ELCLastRunFailure | Out-File "$Mailbox - MRM Component Diagnostic Logs.txt" -Append
        } else {
            "MRM has FAILED recently.  See the Component Diagnostic Logs file for details.
		-----------------------------------------------------------------------------
		" | Out-File "$Mailbox - Mailbox Diagnostic Logs.txt"
            $ELCRunLastData | Out-File "$Mailbox - Mailbox Diagnostic Logs.txt" -Append
            "This log contains an interesting and very recent failure.
		---------------------------------------------------------
		" | Out-File "$Mailbox - MRM Component Diagnostic Logs.txt"
            $ELCLastRunFailure | Out-File "$Mailbox - MRM Component Diagnostic Logs.txt" -Append
        }
    } else {
        "MRM has not encountered a failure.  Component Diagnostic Log is empty." | Out-File "$Mailbox - MRM Component Diagnostic Logs.txt"
        "MRM has never failed for this user.
      -----------------------------------
      " | Out-File "$Mailbox - Mailbox Diagnostic Logs.txt"
        $ELCRunLastData | Out-File "$Mailbox - Mailbox Diagnostic Logs.txt" -Append
    }

    Search-AdminAuditLog -Cmdlets Start-ManagedFolderAssistant, Set-RetentionPolicy, Set-RetentionPolicyTag, Set-MailboxPlan, Set-Mailbox | Export-Csv "$Mailbox - MRM Component Audit Logs.csv" -NoTypeInformation
    # Get the Mailbox Folder Statistics
    $folderStats = Get-MailboxFolderStatistics $MailboxProps.Identity -IncludeAnalysis -IncludeOldestAndNewestItems
    $folderStats | Sort-Object FolderPath | Out-File "$Mailbox - Mailbox Folder Statistics.txt"
    $folderStats | Select-Object FolderPath, ItemsInFolder, ItemsInFolderAndSubFolders, FolderAndSubFolderSize, NewestItemReceivedDate, OldestItemReceivedDate | Sort-Object FolderPath | Format-Table -AutoSize -Wrap | Out-File "$Mailbox - Mailbox Folder Statistics (Summary).txt"
    # Get the MRM 2.0 Policy and Tags Summary
    $MailboxRetentionPolicy = Get-RetentionPolicy $MailboxProps.RetentionPolicy
    $mrmPolicy = $MailboxRetentionPolicy | Select-Object -ExpandProperty Name
    $mrmMailboxTags = Get-RetentionPolicyTag -Mailbox $MailboxProps.Identity
    $msgRetentionProperties = "This Mailbox has the following Retention Hold settings assigned:"
    $msgRetentionProperties >> ($File)
    $msgRetentionProperties = "##################################################################################################################"
    $msgRetentionProperties >> ($File)
    $msgRetentionProperties = "Retention Hold is " + ($MailboxProps).RetentionHoldEnabled + " for the mailbox (True is Enabled, False is Disabled)"
    $msgRetentionProperties >> ($File)
    $msgRetentionProperties = "Retention Hold will start on " + ($MailboxProps).StartDateForRetentionHold + " (no value is Disabled)"
    $msgRetentionProperties >> ($File)
    $msgRetentionProperties = "Retention Hold will end on " + ($MailboxProps).EndDateForRetentionHold + " (no value is Disabled)"
    $msgRetentionProperties >> ($File)
    $msgRetentionProperties = ""
    $msgRetentionProperties >> ($File)
    $msgRetentionProperties = "This Mailbox has the following Retention Policy assigned:"
    $msgRetentionProperties >> ($File)
    $msgRetentionProperties = "##################################################################################################################"
    $msgRetentionProperties >> ($File)
    $msgRetentionProperties = $mrmPolicy
    $msgRetentionProperties >> ($File)
    $msgRetentionProperties = ""
    $msgRetentionProperties >> ($File)
    $msgRetentionProperties = "The Retention Policy " + $mrmPolicy + " has the following tags assigned to the mailbox " + $MailboxProps + ":"
    $msgRetentionProperties >> ($File)
    $msgRetentionProperties = "##################################################################################################################"
    $msgRetentionProperties >> ($File)
    $msgRetentionProperties = ($MailboxRetentionPolicy).RetentionPolicyTagLinks | Sort-Object
    $msgRetentionProperties >> ($File)
    $msgRetentionProperties = ""
    $msgRetentionProperties >> ($File)
    $msgRetentionProperties = "The Mailbox " + $MailboxProps.Identity + " says it has all of the following tags assigned to it (If different than above user added personal tags via OWA):"
    $msgRetentionProperties >> ($File)
    $msgRetentionProperties = "##########################################################################################################################################"
    $msgRetentionProperties >> ($File)
    $msgRetentionProperties = ($mrmMailboxTags).Name | Sort-Object
    $msgRetentionProperties >> ($File)
    $msgRetentionProperties = ""
    $msgRetentionProperties >> ($File)
    $msgRetentionProperties = "Here are the Details of the Retention Policy Tags for this Mailbox:"
    $msgRetentionProperties >> ($File)
    $msgRetentionProperties = "##################################################################################################################"
    $msgRetentionProperties >> ($File)
    foreach ($Tag in $MailboxRetentionPolicy.RetentionPolicyTagLinks) {
        Get-RetentionPolicyTag $Tag | Format-List Name, Description, Comment, AddressForJournaling, AgeLimitForRetention, LocalizedComment, LocalizedRetentionPolicyTagName, MessageClass, MessageFormatForJournaling, MustDisplayCommentEnabled, RetentionAction, RetentionEnabled, RetentionId, SystemTag, Type >> ($File)
    }
    $msgRetentionProperties = "##################################################################################################################"
    $msgRetentionProperties >> ($File)
    if ($MbxTotalSize -le 10485760 ) {
        #If the Total Item size in the mailbox is less than or equal to 10MB MRM will not run. Both values converted to bytes.
        $msgRetentionProperties = "Primary Mailbox is less than 10MB.  MRM will not run until mailbox exceeds 10MB.  Current Mailbox size is " + $MbxTotalSize.ToString() + " bytes."
        $msgRetentionProperties >> ($File)
        $msgRetentionProperties = "##################################################################################################################"
        $msgRetentionProperties >> ($File)
    } else {
        $msgRetentionProperties = "Primary Mailbox exceeds 10MB.  Minimum mailbox size requirement for MRM has been met.  Current Mailbox size is " + $MbxTotalSize.ToString() + " bytes."
        $msgRetentionProperties >> ($File)
        $msgRetentionProperties = "##################################################################################################################"
        $msgRetentionProperties >> ($File)
    }
    if ($PercentOfPrimaryMbxRiQuota -gt 98) {
        #if Recoverable items in the primary mailbox is more than 98% full highlight it as a problem.
        $msgRetentionProperties = "Primary Mailbox is critically low on free quota for Recoverable Items. "
        $msgRetentionProperties >> ($File)
        $msgRetentionProperties = $MbxDeletedSize.ToString() + " bytes consumed in Recoverable Items."
        $msgRetentionProperties >> ($File)
        $msgRetentionProperties = $MbxRIQuota.ToString() + " bytes is the maximum. "
        $msgRetentionProperties >> ($File)
        $msgRetentionProperties = "##################################################################################################################"
        $msgRetentionProperties >> ($File)
    } else {
        $msgRetentionProperties = "Primary Mailbox Recoverable Items are not yet at quota."
        $msgRetentionProperties >> ($File)
        $msgRetentionProperties = $MbxTotalSize.ToString() + " bytes is the current Recoverable Items size in Primary Mailbox."
        $msgRetentionProperties >> ($File)
        $msgRetentionProperties = $MbxRIQuota.ToString() + " bytes is the maximum."
        $msgRetentionProperties >> ($File)
        $msgRetentionProperties = "##################################################################################################################"
        $msgRetentionProperties >> ($File)
    }
    if ($PrimaryArchiveRIFillPercentage -gt 98) {
        #if Recoverable items in the primary archive mailbox is more than 98% full highlight it as a problem.
        $msgRetentionProperties = "Primary Archive Mailbox is critically low on free quota for Recoverable Items. "
        $msgRetentionProperties >> ($File)
        $msgRetentionProperties = $ArchiveMbxDeletedSize.ToString() + " bytes consumed in Recoverable Items."
        $msgRetentionProperties >> ($File)
        $msgRetentionProperties = $ArchiveMbxRIQuota.ToString() + " bytes is the maximum."
        $msgRetentionProperties >> ($File)
        $msgRetentionProperties = "##################################################################################################################"
        $msgRetentionProperties >> ($File)
    } else {
        $msgRetentionProperties = "Primary Archive Mailbox is not in imminent danger of filling Recoverable Items Quota."
        $msgRetentionProperties >> ($File)
        $msgRetentionProperties = $ArchiveMbxDeletedSize.ToString() + " bytes consumed in Recoverable Items."
        $msgRetentionProperties >> ($File)
        $msgRetentionProperties = $ArchiveMbxRIQuota.ToString() + " bytes is the maximum available."
        $msgRetentionProperties >> ($File)
        $msgRetentionProperties = "##################################################################################################################"
        $msgRetentionProperties >> ($File)
    }
    if ($PrimaryArchiveTotalFillPercentage -gt 98) {
        #if Recoverable items in the primary archive mailbox is more than 98% full highlight it as a problem.
        $msgRetentionProperties = "Primary Archive Mailbox is critically low on free quota for Visible Items. "
        $msgRetentionProperties >> ($File)
        $msgRetentionProperties = $ArchiveMbxTotalSize.ToString() + " bytes consumed in Recoverable Items."
        $msgRetentionProperties >> ($File)
        $msgRetentionProperties = $ArchiveMbxQuota.ToString() + " bytes is the maximum."
        $msgRetentionProperties >> ($File)
        $msgRetentionProperties = "##################################################################################################################"
        $msgRetentionProperties >> ($File)
    } else {
        $msgRetentionProperties = "Primary Archive Mailbox is not in imminent danger of filling the mailbox quota."
        $msgRetentionProperties >> ($File)
        $msgRetentionProperties = $ArchiveMbxTotalSize.ToString() + " bytes consumed in Recoverable Items."
        $msgRetentionProperties >> ($File)
        $msgRetentionProperties = $ArchiveMbxQuota.ToString() + " bytes is the maximum."
        $msgRetentionProperties >> ($File)
        $msgRetentionProperties = "##################################################################################################################"
        $msgRetentionProperties >> ($File)
    }

    return
}

function funcManagedFolderProperties {
    Get-ManagedFolderMailboxPolicy | Select-Object * | Export-Clixml "$Mailbox - MRM Managed Folder Mailbox Policies - All.xml"
    Get-ManagedFolder | Select-Object * | Export-Clixml "$Mailbox - MRM Managed Folders - All.xml"
    Get-ManagedContentSettings | Select-Object * | Export-Clixml "$Mailbox - MRM Managed Content Settings - All.xml"
    $MailboxManagedFolderPolicy = Get-ManagedFolderMailboxPolicy $MailboxProps.ManagedFolderMailboxPolicy
    $msgRetentionProperties = "This Mailbox has the following Retention Policy assigned:"
    $msgRetentionProperties >> ($File)
    $msgRetentionProperties = "##################################################################################################################"
    $msgRetentionProperties >> ($File)
    $msgRetentionProperties = $MailboxManagedFolderPolicy | Select-Object -ExpandProperty Name
    $msgRetentionProperties >> ($File)
    $msgRetentionProperties = ""
    $msgRetentionProperties >> ($File)
    $msgRetentionProperties = "Here are the Details of the Managed Folders for this Mailbox:"
    $msgRetentionProperties >> ($File)
    $msgRetentionProperties = "##################################################################################################################"
    $msgRetentionProperties >> ($File)
    foreach ($Folder in $MailboxManagedFolderPolicy.ManagedFolderLinks) {
        Get-ManagedFolder $Folder | Format-List Name, Description, Comment, FolderType, FolderName, StorageQuota, LocalizedComment, MustDisplayCommentEnabled, BaseFolderOnly, TemplateIds >> ($File)
    }
    $msgRetentionProperties = "Here are the Details of the Managed Content Settings for this Mailbox:"
    $msgRetentionProperties >> ($File)
    $msgRetentionProperties = "##################################################################################################################"
    $msgRetentionProperties >> ($File)
    foreach ($Folder in $MailboxManagedFolderPolicy.ManagedFolderLinks.FolderType) {
        Get-ManagedContentSettings -Identity $Folder | Format-List Name, Identity, Description, MessageClassDisplayName, MessageClass, RetentionEnabled, RetentionAction, AgeLimitForRetention, MoveToDestinationFolder, TriggerForRetention, MessageFormatForJournaling, JournalingEnabled, AddressForJournaling, LabelForJournaling, ManagedFolder, ManagedFolderName >> ($File)
    }
    return
}

function funcConvertPrStartTime {
    # Example:
    # ConvertPrStartTime 000000008AF3B39BE681D001
    #
    param($byteString)
    $bytesReversed = ""
    for ($x = $byteString.Length - 2; $x -gt 7; $x -= 2) { $bytesReversed += $byteString.Substring($x, 2) }
    [DateTime]::FromFileTimeUtc([Int64]::Parse($bytesReversed, "AllowHexSpecifier"))
}

function funcUltArchive {
    param(
        [string]$mbx
    )
    $m = get-mailbox $mbx
    $mbxLocations = Get-MailboxLocation -User $m.Identity
    Write-Host ""
    Write-Host ""
    Write-Host "There is a total of $($mbxLocations.Count-2) auxiliary archive mailboxes for [$strMailbox]."
    Write-Host ""
    Write-Host ""
    Write-Host "Archive mailbox statistics:"
    Write-Host ""
    Write-Host "Mailbox Type`tMailbox GUID`t`t`t`t`t`t`tMailbox Size(MB)"
    Write-Host "-------------------------------------------------------------------------------"
    $totalArchiveSize = 0
    foreach ($x in $mbxLocations) {
        if ($x.MailboxLocationType -ne "Primary") {
            $stats = Get-MailboxStatistics -Identity ($x.MailboxGuid).Guid | Select-Object @{name = "TotalItemSize"; expression = { [math]::Round(($_.TotalItemSize.ToString().Split("(")[1].Split(" ")[0].Replace(",", "") / 1MB), 2) } }
            Write-Host "$($x.MailboxLocationType)`t`t$($x.MailboxGUID)`t$($stats.TotalItemSize)"
            if ($stats) {
                $totalArchiveSize = $totalArchiveSize + $stats.TotalItemSize
            }
        }
    }
    Write-Host "-------------------------------------------------------------------------------"
    Write-Host "Total archive size:`t`t`t`t$totalArchiveSize MB"
    Write-Host ""
    Write-Host ""
    Write-Host ""
}

#===================================================================
# MAIN
#===================================================================

if ($SDE -eq $True) {
    funcConvertPrStartTime
}

$MailboxProps = (Get-Mailbox $Mailbox)

if ($Null -ne $MailboxProps) {
    Write-Host -ForegroundColor "Green" "Found Mailbox $Mailbox, please wait while information is being gathered..."
}

else {
    Write-Host -ForegroundColor "Red" "The Mailbox $Mailbox cannot be found, please check spelling and try again!"
    exit
}

$File = "$Mailbox - MRM Summary.txt"

$Msg = "export complete, see file please send all files that start with $Mailbox - to your Microsoft Support Engineer"

if (($Null -eq $MailboxProps.RetentionPolicy) -and ($Null -eq $MailboxProps.ManagedFolderMailboxPolicy)) {
    Write-Host -ForegroundColor "Yellow" "The Mailbox does not have a Retention Policy or Managed Folder Policy applied!"
    exit
}

elseif ($Null -ne $MailboxProps.RetentionPolicy) {
    New-Item $File -Type file -Force | Out-Null
    funcRetentionProperties
    Write-Host -ForegroundColor "Green" $Msg
}

else {
    New-Item $File -Type file -Force | Out-Null
    funcManagedFolderProperties
    Write-Host -ForegroundColor "Green" $Msg
}
