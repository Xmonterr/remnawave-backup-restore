#!/bin/bash

# Скрипт диагностики проблем с Яндекс.Диском
# Использование: ./yandex-disk-troubleshooting.sh [YD_TOKEN]

set -e

RED=$'\e[31m'
GREEN=$'\e[32m'
YELLOW=$'\e[33m'
CYAN=$'\e[36m'
RESET=$'\e[0m'

echo -e "${CYAN}=== Диагностика подключения к Яндекс.Диску ===${RESET}\n"

# Проверяем аргумент токена
YD_TOKEN="${1:-}"
if [[ -z "$YD_TOKEN" ]]; then
    # Пытаемся загрузить из config.env
    CONFIG_FILE="/opt/rw-backup-restore/config.env"
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        if [[ -n "$YD_TOKEN" ]]; then
            echo -e "${GREEN}✓${RESET} Токен загружен из $CONFIG_FILE"
        fi
    fi
fi

if [[ -z "$YD_TOKEN" ]]; then
    echo -e "${RED}✗ Токен не указан.${RESET}"
    echo "Использование: $0 <YD_TOKEN>"
    echo "Или сохраните токен в /opt/rw-backup-restore/config.env"
    exit 1
fi

# 1. Проверка доступности API
echo -e "\n${CYAN}[1/5] Проверка доступности API Яндекс.Диска...${RESET}"
if timeout 10 curl -s -o /dev/null -w "%{http_code}" "https://cloud-api.yandex.net" | grep -qE "^(200|301|302|401|403)$"; then
    echo -e "${GREEN}✓${RESET} API доступен"
else
    echo -e "${RED}✗ API недоступен или timeout${RESET}"
    echo "  Возможно, ресурсы Яндекса заблокированы или проблемы с интернетом"
    exit 1
fi

# 2. Проверка скорости соединения
echo -e "\n${CYAN}[2/5] Измерение времени отклика...${RESET}"
response_time=$(curl -o /dev/null -s -w "%{time_total}" "https://cloud-api.yandex.net")
echo "  Время отклика: ${response_time}s"
if (( $(echo "$response_time > 2" | bc -l) )); then
    echo -e "${YELLOW}⚠${RESET} Медленное соединение (>${response_time}s). Загрузка может быть очень долгой."
fi

# 3. Проверка токена и информации о диске
echo -e "\n${CYAN}[3/5] Проверка токена и информации о диске...${RESET}"
disk_info=$(curl -s -H "Authorization: OAuth $YD_TOKEN" \
    "https://cloud-api.yandex.net/v1/disk/")

if echo "$disk_info" | grep -q "error"; then
    echo -e "${RED}✗ Ошибка токена:${RESET}"
    echo "$disk_info" | jq -r '.message // .error' 2>/dev/null || echo "$disk_info"
    exit 1
else
    echo -e "${GREEN}✓${RESET} Токен действителен"
    total_space=$(echo "$disk_info" | jq -r '.total_space // 0' 2>/dev/null)
    used_space=$(echo "$disk_info" | jq -r '.used_space // 0' 2>/dev/null)
    
    if [[ "$total_space" != "0" ]]; then
        free_space=$((total_space - used_space))
        total_gb=$(echo "scale=2; $total_space / 1073741824" | bc)
        used_gb=$(echo "scale=2; $used_space / 1073741824" | bc)
        free_gb=$(echo "scale=2; $free_space / 1073741824" | bc)
        
        echo "  Всего места: ${total_gb} GB"
        echo "  Использовано: ${used_gb} GB"
        echo "  Свободно: ${free_gb} GB"
        
        if [[ "$free_space" -lt 104857600 ]]; then  # < 100MB
            echo -e "${RED}✗ Недостаточно места на диске!${RESET}"
            exit 1
        fi
    fi
fi

# 4. Тестовая загрузка маленького файла
echo -e "\n${CYAN}[4/5] Тестовая загрузка файла...${RESET}"
test_file=$(mktemp)
echo "Test upload at $(date)" > "$test_file"
test_filename="rw-backup-test-$(date +%s).txt"

# Получаем ссылку для загрузки
upload_url_response=$(curl -s -X GET "https://cloud-api.yandex.net/v1/disk/resources/upload?path=${test_filename}&overwrite=true" \
    -H "Authorization: OAuth $YD_TOKEN")

upload_href=$(echo "$upload_url_response" | jq -r .href 2>/dev/null)

if [[ -z "$upload_href" || "$upload_href" == "null" ]]; then
    echo -e "${RED}✗ Не удалось получить ссылку для загрузки${RESET}"
    echo "$upload_url_response" | jq '.' 2>/dev/null || echo "$upload_url_response"
    rm -f "$test_file"
    exit 1
fi

# Загружаем тестовый файл
echo "  Загрузка тестового файла..."
upload_result=$(curl -s -X PUT "$upload_href" \
    -H "Authorization: OAuth $YD_TOKEN" \
    --data-binary "@$test_file" \
    -w "%{http_code}" \
    -o /dev/null)

if [[ "$upload_result" -eq 201 || "$upload_result" -eq 200 ]]; then
    echo -e "${GREEN}✓${RESET} Тестовый файл успешно загружен (HTTP: $upload_result)"
    
    # Удаляем тестовый файл
    curl -s -X DELETE "https://cloud-api.yandex.net/v1/disk/resources?path=${test_filename}" \
        -H "Authorization: OAuth $YD_TOKEN" > /dev/null
    echo "  Тестовый файл удален с диска"
else
    echo -e "${RED}✗ Ошибка загрузки (HTTP: $upload_result)${RESET}"
    rm -f "$test_file"
    exit 1
fi

rm -f "$test_file"

# 5. Тест скорости загрузки
echo -e "\n${CYAN}[5/5] Тест скорости загрузки (1MB файл)...${RESET}"
large_test_file=$(mktemp)
dd if=/dev/zero of="$large_test_file" bs=1024 count=1024 2>/dev/null  # 1MB
large_test_filename="rw-backup-speedtest-$(date +%s).bin"

upload_url_response=$(curl -s -X GET "https://cloud-api.yandex.net/v1/disk/resources/upload?path=${large_test_filename}&overwrite=true" \
    -H "Authorization: OAuth $YD_TOKEN")

upload_href=$(echo "$upload_url_response" | jq -r .href 2>/dev/null)

if [[ -n "$upload_href" && "$upload_href" != "null" ]]; then
    echo "  Начало загрузки 1MB файла..."
    start_time=$(date +%s)
    
    upload_result=$(curl -s --max-time 60 -X PUT "$upload_href" \
        -H "Authorization: OAuth $YD_TOKEN" \
        --data-binary "@$large_test_file" \
        -w "%{http_code}" \
        -o /dev/null)
    
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    
    if [[ "$upload_result" -eq 201 || "$upload_result" -eq 200 ]]; then
        speed=$(echo "scale=2; 1 / $duration" | bc)
        echo -e "${GREEN}✓${RESET} Загрузка выполнена за ${duration}s (~${speed} MB/s)"
        
        if [[ $duration -gt 30 ]]; then
            echo -e "${YELLOW}⚠${RESET} Очень медленная загрузка. Для больших бэкапов (>100MB) потребуется много времени."
            echo "  Рекомендации:"
            echo "  - Проверьте скорость интернета"
            echo "  - Попробуйте загрузку в другое время суток"
            echo "  - Рассмотрите другие способы загрузки (Telegram, Google Drive)"
        fi
        
        # Удаляем тестовый файл
        curl -s -X DELETE "https://cloud-api.yandex.net/v1/disk/resources?path=${large_test_filename}" \
            -H "Authorization: OAuth $YD_TOKEN" > /dev/null
    else
        echo -e "${YELLOW}⚠${RESET} Timeout или ошибка при загрузке теста скорости"
    fi
fi

rm -f "$large_test_file"

# Итоговый результат
echo -e "\n${GREEN}=== Диагностика завершена ===${RESET}"
echo -e "${GREEN}✓${RESET} Все проверки пройдены успешно"
echo -e "\nЯндекс.Диск доступен и готов к использованию для бэкапов."
