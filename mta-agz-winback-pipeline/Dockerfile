FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1

# ChannelAttribution requires gcc/g++ to compile its C++ bindings
RUN apt-get update && \
    apt-get install -y \
    build-essential \
    gcc \
    g++ \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/ml/processing

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Notebook is mounted by SageMaker Processing at runtime via S3 input
# No ENTRYPOINT needed — papermill is called by the dag_factory SageMakerProcessingOperator
