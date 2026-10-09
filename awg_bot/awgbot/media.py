"""media.py — файлы для отправки: QR-код конфига и zip из файлов или из байтов."""

from __future__ import annotations

import io
import os
import zipfile

import qrcode
from qrcode.exceptions import DataOverflowError

# Как в awg2: длиннее — телефон уже не сканирует QR с экрана уверенно.
QR_MAX = 2800


def qr_png(text: str) -> bytes | None:
    """PNG с QR-кодом или None, если текст для QR слишком длинный."""
    if len(text.encode()) > QR_MAX:
        return None
    qr = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_L, box_size=8, border=2)
    try:
        qr.add_data(text)
        qr.make(fit=True)
    except DataOverflowError:
        return None
    buf = io.BytesIO()
    qr.make_image(fill_color="black", back_color="white").save(buf, format="PNG")
    return buf.getvalue()


def zip_files(paths: list[str]) -> bytes:
    """Zip из существующих файлов (без каталогов внутри архива)."""
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for p in paths:
            if p and os.path.isfile(p):
                z.write(p, arcname=os.path.basename(p))
    return buf.getvalue()


def zip_data(files: dict[str, bytes]) -> bytes:
    """Zip из готовых данных: имя в архиве → содержимое."""
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in files.items():
            z.writestr(name, data)
    return buf.getvalue()
