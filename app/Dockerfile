# syntax=docker/dockerfile:1.7
# Minimal, reproducible image used in BOTH demos.
# Build-time ARG IMAGE_VARIANT selects "clean" or "tampered" behaviour.
# In the secure demo only the "clean" variant is signed by Cosign in CI.
FROM python:3.12-slim AS base

ARG IMAGE_VARIANT=clean
ENV IMAGE_VARIANT=${IMAGE_VARIANT} \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

# Drop privileges
RUN useradd -u 10001 -m -s /sbin/nologin appuser
USER appuser

EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=2s --start-period=3s \
    CMD python -c "import urllib.request,sys; \
        sys.exit(0) if urllib.request.urlopen('http://127.0.0.1:8080/healthz').status==200 else sys.exit(1)"

ENTRYPOINT ["python", "app.py"]
