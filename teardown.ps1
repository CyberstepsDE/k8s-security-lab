# Tears down the whole lab cluster (Windows PowerShell). Same as teardown.sh.
# Run from the repo folder:
#   powershell -ExecutionPolicy Bypass -File .\teardown.ps1

$ErrorActionPreference = 'Stop'
& minikube delete
if ($LASTEXITCODE -ne 0) { throw 'Failed: minikube delete' }
