FROM python:3.13-slim

WORKDIR /app

# Install dependencies
COPY pyproject.toml .
COPY src/ src/
RUN pip install --no-cache-dir -e .

# Copy schema (for init scripts if needed)
COPY schema/ schema/
COPY config.yaml .
COPY app/ app/

# Entry point: run consumer
CMD ["python", "-m", "nrt_mdm"]
