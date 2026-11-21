FROM python:3.12-slim-bookworm

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends build-essential libgmp-dev git && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir 'libp2p==0.8.0' redis multiaddr

COPY node.py .

ENV PYTHONUNBUFFERED=1

ENTRYPOINT ["python", "node.py"]
