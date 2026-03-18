version: '3.7'
networks:
  iriusrisk-backend:
services:
  jeff:
    environment:
      - IRIUS_HOST=https://tomcat:8080
      - CORS_ORIGINS=https://localhost:8003, http://tomcat:8080, https://tomcat:8080, https://tomcat:80, http://tomcat:80
      - RAG_HOST=http://rag:8010
      - ASH_HOST=http://ash:8009
      - HAVEN_HOST=http://haven:8012
      - AZURE_ENDPOINT=${AZURE_ENDPOINT}
      - BLACKLIST_ENABLED=False
    ports:
      - 8008:8008
    image: localhost/ai-jeff-4.6.2
    container_name: jeff
    restart: unless-stopped
    secrets:
      - source: azure_api_key
        target: AZURE_API_KEY_GPG
        type: env
      - source: azure_api_privkey
        target: AZURE_API_PRIVKEY_ASC
        type: env
    networks:
      - iriusrisk-backend
  rag:
    environment:
      - OPENAI_API_KEY=""
      - AZURE_API_VERSION=2025-03-01-preview
      - AZURE_DEPLOYMENT=text-embedding-3-small
      - AZURE_ENDPOINT=${AZURE_ENDPOINT}
      - EMBEDDING_MODEL=text-embedding-3-small
      - USE_AZURE=True
      - IRIUS_SECURE=True
      - DEBUG=False
    ports:
      - 8010:8010
    image: localhost/ai-rag-1.2.2
    container_name: rag
    restart: unless-stopped
    secrets:
      - source: azure_api_key
        target: AZURE_API_KEY_GPG
        type: env
      - source: azure_api_privkey
        target: AZURE_API_PRIVKEY_ASC
        type: env
    networks:
      - iriusrisk-backend
  ash:
    environment:
      - CORS_ORIGINS=http://localhost:5173, http://localhost:8003
      - RAG_HOST=http://rag:8010
      - GEMINI_API_BASE=${GEMINI_ENDPOINT}
      - AZURE_OPENAI_ENDPOINT=${AZURE_ENDPOINT}
    ports:
      - 8009:8009
    image: localhost/ai-ash-1.7.0
    container_name: ash
    restart: unless-stopped
    secrets:
      - source: gemini_api_key
        target: GEMINI_API_KEY_GPG
        type: env
      - source: gemini_api_privkey
        target: GEMINI_API_PRIVKEY_ASC
        type: env
      - source: azure_api_key
        target: AZURE_API_KEY_GPG
        type: env
      - source: azure_api_privkey
        target: AZURE_API_PRIVKEY_ASC
        type: env
    networks:
      - iriusrisk-backend
  haven:
    environment:
      - ENVIRONMENT=PROD
      - DEBUG=false
      - PORT=8012
      - CORS_ORIGINS=http://localhost:8012
      - AZURE_API_VERSION=2025-03-01-preview
      - AZURE_ENDPOINT=${AZURE_ENDPOINT}
      - AZURE_DEPLOYMENT=text-embedding-3-small
      - REDIS_URL=redis://redis:6379/0
    ports:
      - 8012:8012
    image: localhost/ai-haven-1.0.1
    container_name: haven
    restart: unless-stopped
    depends_on:
      - redis
    secrets:
      - source: azure_api_key
        target: AZURE_API_KEY_GPG
        type: env
      - source: azure_api_privkey
        target: AZURE_API_PRIVKEY_ASC
        type: env
      - source: redis_password
        target: REDIS_PASSWORD_GPG
        type: env
      - source: redis_privkey
        target: REDIS_PRIVKEY_ASC
        type: env
    networks:
      - iriusrisk-backend
  redis:
    image: localhost/redis-stack-gpg:latest
    container_name: redis
    restart: always
    ports:
      - "6379:6379"
      - "8001:8001"
    secrets:
      - source: redis_password
        target: REDIS_PASSWORD_GPG
        type: env
      - source: redis_privkey
        target: REDIS_PRIVKEY_ASC
        type: env
    networks:
      - iriusrisk-backend
secrets:
  azure_api_key:
    external: true
  azure_api_privkey:
    external: true
  gemini_api_key:
    external: true
  gemini_api_privkey:
    external: true
  redis_password:
    external: true
  redis_privkey:
    external: true
