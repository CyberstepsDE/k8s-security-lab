FROM python:3.12-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends iputils-ping curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
COPY privileged-pod.json /opt/privileged-pod.json

EXPOSE 5000
CMD ["python", "app.py"]
