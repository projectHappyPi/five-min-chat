@echo off
chcp 65001 > nul
cd /d %~dp0
where node > nul 2>&1
if errorlevel 1 (
  echo Node.js 가 없어요. https://nodejs.org 에서 LTS 버전을 설치한 뒤 다시 실행해 주세요.
  pause
  exit /b 1
)
if not exist node_modules (
  echo 처음 실행이라 필요한 파일을 설치하는 중이에요...
  call npm install --omit=dev
)
node src\index.js
pause
