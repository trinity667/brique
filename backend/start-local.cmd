@echo off
rem Demarre le serveur LOCAL (hors ligne : base .localdb, appli web incluse) sur http://<ip du PC>:3000.
rem Journal : local.log. Lance au demarrage de Windows par install-local.ps1.
cd /d "%~dp0"
node scripts/local-server.js >> local.log 2>&1
