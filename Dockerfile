FROM python:3.9-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# copy script and .env file
COPY .env .
COPY etl.py .

# copy data folder
COPY data/ ./data/ 

RUN ls -la data/raw

CMD ["python", "etl.py"]
