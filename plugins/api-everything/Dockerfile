FROM mcr.microsoft.com/playwright/python:v1.50.0-noble

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY sites.json .
COPY app ./app
# The Hub image places this directory beside the plugin before the image is built.
COPY framework-lib-script /app/framework-lib-script

ENV PYTHONUNBUFFERED=1
ENV PYTHONPATH=/app/framework-lib-script
EXPOSE 8080
CMD ["python", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
