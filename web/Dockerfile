FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt
COPY app.py /app/app.py
COPY static /app/static
RUN useradd --uid 10001 --create-home bsm
USER 10001:10001
EXPOSE 8788
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8788", "--proxy-headers", "--forwarded-allow-ips", "*"]
