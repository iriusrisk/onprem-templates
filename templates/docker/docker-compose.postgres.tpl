version: '3.7'
networks:
  iriusrisk-backend:
services:
  postgres:
    image: docker.io/library/postgres:15.4
    container_name: iriusrisk-postgres
    ports:
      - "5432:5432"
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    networks:
      - iriusrisk-backend
    volumes:
      - "./postgres/data:/var/lib/postgresql/data:z"
    restart: always