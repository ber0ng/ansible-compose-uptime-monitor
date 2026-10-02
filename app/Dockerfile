# one image, two roles: api default cmd and the worker command override in compose
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# install deps first so this layer is cached when only code changes 
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY *.py .

# don't run as root
RUN useradd --create-home appuser
USER appuser

EXPOSE 8080

# api health check 
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries= \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/healthz')"

CMD ["uvicorn", "api:app", "--host", "0.0.0.0", "--port", "8000"]