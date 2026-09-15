@echo off
cd /d C:\Users\User\Desktop\stock_app
set PYTHONIOENCODING=utf-8
set PATH=C:\Program Files\GitHub CLI;%PATH%
python live_scanner.py >> data\live_scanner_task.log 2>&1
