# A lancer UNE FOIS dans un PowerShell ouvert "en tant qu'administrateur" sur le PC du chantier :
#   cd <dossier backend> ; .\install-local.ps1
# - ouvre le port 3000 du pare-feu pour le reseau PRIVE uniquement (pas internet)
# - cree la tache planifiee qui demarre le serveur local a l'ouverture de session et le relance s'il s'arrete
# - desactive la mise en veille sur secteur
# Pour tout annuler : .\install-local.ps1 -Remove

param([switch]$Remove)

$ErrorActionPreference = 'Stop'
$name = 'Briques-Paie-Local'
$cmd = Join-Path $PSScriptRoot 'start-local.cmd'

if ($Remove) {
  Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
  Remove-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue
  Write-Host 'Tache et regle de pare-feu supprimees.'
  exit 0
}

New-NetFirewallRule -DisplayName $name -Direction Inbound -Protocol TCP -LocalPort 3000 -Action Allow -Profile Private | Out-Null

$action = New-ScheduledTaskAction -Execute $cmd -WorkingDirectory $PSScriptRoot
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1) `
  -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null

powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0

Write-Host "OK. Adresse a donner aux telephones : http://$((Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like '192.168.*' -or $_.IPAddress -like '10.*' } | Select-Object -First 1).IPAddress):3000"
Write-Host 'Reste a faire a la main : ouverture de session automatique de Windows, "rallumer apres coupure" dans le BIOS, IP fixe (reservation DHCP du routeur).'
