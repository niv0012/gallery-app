@echo off
cd /d "D:\picgallery\backend"
call venv\Scripts\activate
python -m uvicorn app.main:app --host 0.0.0.0 --port 8000
