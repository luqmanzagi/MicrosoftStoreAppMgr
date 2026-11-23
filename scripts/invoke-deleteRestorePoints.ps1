$points = @(Get-ComputerRestorePoint | Where-Object { $_.Description -eq 'MicrosoftStoreAppMgr test baseline' })
$points | Format-Table SequenceNumber, Description, CreationTime

Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public class RestorePoint {
    [DllImport("Srclient.dll")]
    public static extern int SRRemoveRestorePoint(int index);
}
'@

foreach ($point in $points) {
    $code = [RestorePoint]::SRRemoveRestorePoint([int]$point.SequenceNumber)
    "Sequence $($point.SequenceNumber) -> $code"
}