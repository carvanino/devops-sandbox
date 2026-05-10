FROM python:3.11-slim

RUN addgroup --system appgroup && \
    adduser --system --ingroup appgroup appuser

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

USER appuser

ENV ENV_ID=unknown
ENV ENV_NAME=unknown

EXPOSE 3000

CMD ["python3", "main.py"]
