@echo off
title Harbor Startup
cd /d "%~dp0"

echo Starting CORS Proxy Server on port 1421...
start "Harbor Proxy" cmd /c "node proxy-server.js"

echo Opening Harbor in your browser...
timeout /t 2 >nul
start "" http://localhost:1420/

echo Starting Harbor Frontend Server on port 1420...
npx pnpm dev --host
