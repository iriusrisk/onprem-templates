version: '3.7'
networks:
  iriusrisk-backend:
services:
  postgres:
    image: localhost/postgres-gpg:15.4
    container_name: iriusrisk-postgres
    ports:
      - "5432:5432"
    secrets:
      - source: db_pwd
        target: DB_PWD_GPG
        type: env
      - source: db_privkey
        target: DB_PRIVKEY_ASC
        type: env
    environment:
      POSTGRES_USER: postgres
    networks:
      - iriusrisk-backend
    volumes:
      - "./postgres/data:/var/lib/postgresql/data:z"
secrets:
  db_pwd:
    external: true
  db_privkey:
    external: true