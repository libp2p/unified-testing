FROM python:3.10-slim

WORKDIR /app

RUN apt-get update && apt-get install -y gcc libgmp-dev && rm -rf /var/lib/apt/lists/*
RUN pip install libp2p redis multiaddr

COPY node.py .

ENV PYTHONUNBUFFERED=1

ENTRYPOINT ["python", "node.py"]
