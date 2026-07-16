FROM python:3.10-slim

WORKDIR /app

RUN apt-get update && apt-get install -y gcc libgmp-dev git && rm -rf /var/lib/apt/lists/*
# Pin libp2p: 0.7.0 renamed libp2p.tools.async_service -> anyio_service (trio->anyio),
# which node.py (trio-based) is not compatible with. 0.6.0 is the last trio release
# that still ships kad_dht + records.validator + tools.async_service.
RUN pip install 'git+https://github.com/sumanjeet0012/py-libp2p.git@fix-kad-dht-routing-0.6.0' redis multiaddr

COPY node.py .

ENV PYTHONUNBUFFERED=1

ENTRYPOINT ["python", "node.py"]
