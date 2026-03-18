version: '3.7'

services:

  nginx:
    environment:
      - NG_SERVER_NAME=${HOST_NAME}

  tomcat:
    environment:
      - IRIUS_DB_URL=jdbc:postgresql://\${POSTGRES_IP}:5432/iriusprod?user=iriusprod&password\=${POSTGRES_PASSWORD}
      - IRIUS_EXT_URL=https\://${HOST_NAME}
