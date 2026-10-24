#!/bin/bash
# markdown source -> docx (python-docx, my md2docx.py) -> pdf (LibreOffice headless)
cd "$(dirname "$0")"
python3 md2docx.py UART_IP_Core_Report.md UART_IP_Core_Report.docx
soffice --headless --convert-to pdf UART_IP_Core_Report.docx >/dev/null 2>&1
ls -la UART_IP_Core_Report.*
