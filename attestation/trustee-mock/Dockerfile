# syntax=docker/dockerfile:1.7
FROM python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir flask==3.0.3
COPY main.py .
RUN useradd -u 10001 -m -s /sbin/nologin trustee
USER trustee
EXPOSE 8080
ENTRYPOINT ["python", "main.py"]
