version: '3.7'

services:
  nginx:
    environment:
      - NG_SERVER_NAME=${HOST_NAME}

  tomcat:
    secrets:
      - source: db_pwd
        target: DB_PWD_GPG
        type: env
      - source: db_privkey
        target: DB_PRIVKEY_ASC
        type: env
    environment:
      - IRIUS_DB_URL=jdbc:postgresql://\${POSTGRES_IP}:5432/iriusprod?user=iriusprod
      - IRIUS_EXT_URL=https://\${HOST_NAME}

secrets:
  db_pwd:
    external: true
  db_privkey:
    external: true
