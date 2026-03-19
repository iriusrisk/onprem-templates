version: '3.7'

networks:
  iriusrisk-frontend:
  iriusrisk-backend:

services:

  nginx:
    ports:
      - "80:80"
      - "443:443"
    image: ${NGINX_IMAGE}
    container_name: iriusrisk-nginx
    networks:
      - iriusrisk-frontend
    mem_reservation: 50M
    mem_limit: 200M
    cpu_shares: 128
    restart: unless-stopped
    volumes:
      - "./cert.pem:/etc/nginx/ssl/star_iriusrisk_com.crt:ro"
      - "./key.pem:/etc/nginx/ssl/star_iriusrisk_com.key:ro"

  tomcat:
    environment:
      - IRIUS_EDITION=onprem
      - grails_env=production
      - STARTLEFT_URL=http://startleft:8081/api/v1/startleft/iac
      - IRIUS_JWT_PRIVATE_KEY_PATH=/etc/irius/ec_private.pem
      - IRIUS_REPORTING_MODULE_URL=http://reporting-module:3000
      - CATALINA_OPTS=
            -XX:+UseParallelGC
            -XX:+UseContainerSupport
            -XX:MetaspaceSize=2G
            -XX:MaxMetaspaceSize=2G
            -XX:ReservedCodeCacheSize=2G
            -XX:MaxRAMPercentage=50
    image: ${TOMCAT_IMAGE}
    container_name: iriusrisk-tomcat
    networks:
      - iriusrisk-frontend
      - iriusrisk-backend
    mem_reservation: 2G
    cpu_shares: 1024
    volumes:
      - "./ec_private.pem:/etc/irius/ec_private.pem"

  startleft:
    environment:
      - IRIUS_SERVER=http://tomcat:80
    image: ${STARTLEFT_IMAGE}
    container_name: iriusrisk-startleft
    command: ["uvicorn", "startleft.startleft.api.fastapi_server:webapp", "--host", "0.0.0.0", "--port", "8081"]
    networks:
      - iriusrisk-backend
    mem_reservation: 1G
    mem_limit: 2G
    restart: unless-stopped
    cpu_shares: 128

  reporting-module:
    image: ${REPORTING_MODULE_IMAGE}
    container_name: reporting-module
    networks:
      - iriusrisk-backend
    ports:
      - '3000:3000'
