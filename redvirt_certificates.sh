#!/bin/bash
# RED Virtualization 7.3: standalone Engine and VDSM on the same server.
# Uses only this server's existing CAs and private keys.
set -Eeo pipefail
umask 077
export LC_ALL=C

VERSION=20261015-universal-2
PKI=/etc/pki
ENGINE_PKI="$PKI/ovirt-engine"
SIGN_TOOL=/usr/share/ovirt-engine/bin/pki-enroll-request.sh
DB_TOOL=/usr/share/ovirt-engine/dbscripts/engine-psql.sh
MODE=''
WIZARD=0
FQDN=''
DAYS=398
REFERENCE_DATE=''
EXPECTED_CA=''
EXTRA_SAN=''
BACKUP_ROOT=/root
WAIT_SECONDS=180
WORK=''
HOST_STOPPED=0
INSTALL_STARTED=0
INSTALLED=0
ENGINE_PHASE=0
IDENTITY_BROKEN=0
CERTS_READY=0
SYNC_NOT_BEFORE=0
RUNTIME_BEFORE=''
ORIGINAL_CA=''
ORIGINAL_QEMU_CA=''
ORIGINAL_ENGINE_KEY=''
TARGETS=()
PENDING=()
PREVIOUS_UNITS=()
PREVIOUS_SOCKETS=()
HOST_SANS=()
HOST_SIGN_SPECS=()
HOST_LABELS=(vdsm libvirt-client spice vnc migrate)
HOST_CERTS=("$PKI/vdsm/certs/vdsmcert.pem" "$PKI/libvirt/clientcert.pem" "$PKI/vdsm/libvirt-spice/server-cert.pem" "$PKI/vdsm/libvirt-vnc/server-cert.pem" "$PKI/vdsm/libvirt-migrate/server-cert.pem")
HOST_KEYS=("$PKI/vdsm/keys/vdsmkey.pem" "$PKI/libvirt/private/clientkey.pem" "$PKI/vdsm/libvirt-spice/server-key.pem" "$PKI/vdsm/libvirt-vnc/server-key.pem" "$PKI/vdsm/libvirt-migrate/server-key.pem")
HOST_CAS=(ca ca ca ca qemu-ca)
ENGINE_LABELS=(engine apache jboss websocket-proxy)
ENGINE_CERTS=("$ENGINE_PKI/certs/engine.cer" "$ENGINE_PKI/certs/apache.cer" "$ENGINE_PKI/certs/jboss.cer" "$ENGINE_PKI/certs/websocket-proxy.cer")
ENGINE_KEYS=("$ENGINE_PKI/keys/engine_id_rsa" "$ENGINE_PKI/keys/apache.key.nopass" "$ENGINE_PKI/keys/jboss.p12" "$ENGINE_PKI/keys/websocket-proxy.key.nopass")

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'HELP'
RED Virtualization: Engine и хост на одном физическом сервере.
Запуск без аргументов открывает меню. Каждый сервер обрабатывается отдельно.

  bash redvirt_certificates.sh
  bash redvirt_certificates.sh --check
  bash redvirt_certificates.sh --renew-host --fqdn red3.cluster --date 2026-10-15
  bash redvirt_certificates.sh --renew-all --fqdn red3.cluster --date 2026-10-15
  bash redvirt_certificates.sh --recover-host --fqdn red3.cluster --date 2026-10-15

Режимы:
  --check          Проверить состояние, без изменений.
  --renew-host     Обновить VDSM, libvirt, SPICE, VNC и миграцию.
  --renew-engine   При необходимости запустить engine-setup --offline.
  --renew-all      При необходимости обновить Engine, затем сертификаты хоста.
  --recover-host   Восстановить связь при NonResponsive/Unknown ВМ, проверить
                   синхронизацию состояний после обновления Engine и хоста.

Параметры:
  --fqdn NAME         Полное имя текущего сервера; по умолчанию hostname -f.
  --days N            Срок сертификатов хоста, 1..1825 дней; по умолчанию 398.
  --date YYYY-MM-DD   Фактическая календарная дата, сравнивается с датой сервера.
  --ca-sha256 HEX     Ожидаемый SHA256 отпечаток собственного CA (необязательно).
  --san LIST         Дополнительные DNS/IP SAN, например DNS:alias,IP:10.0.0.3.
  --backup-root DIR   Существующая папка резервных копий; по умолчанию /root.
  --wait-seconds N    Ожидание синхронизации в --recover-host, 0..900; default 180.
  --help             Эта справка.

Для обновления нужны выключенные ВМ, действующие CA и их исходные ключи.
Неизвестный статус в портале допускается: проверяются реальные процессы ВМ.
Сначала сохраняются полная копия Engine и архив PKI/настроек в папке с mode 700.
Engine обновляется штатным engine-setup: на Renew certificates отвечайте Yes.
--days относится только к сертификатам хоста, срок Engine задаёт engine-setup.
HELP
}

set_mode() {
    [[ -z "$MODE" || "$MODE" == "$1" ]] || die 'Выберите один режим.'
    MODE=$1
}

while (( $# )); do
    case "$1" in
        --check) set_mode check; shift ;;
        --renew-host) set_mode host; shift ;;
        --renew-engine) set_mode engine; shift ;;
        --renew-all) set_mode all; shift ;;
        --recover-host) set_mode recover; shift ;;
        --fqdn|--days|--date|--ca-sha256|--san|--backup-root|--wait-seconds)
            (( $# >= 2 )) || die "Отсутствует значение $1."
            case "$1" in
                --fqdn) FQDN=$2 ;;
                --days) DAYS=$2 ;;
                --date) REFERENCE_DATE=$2 ;;
                --ca-sha256) EXPECTED_CA=$2 ;;
                --san) EXTRA_SAN=$2 ;;
                --backup-root) BACKUP_ROOT=$2 ;;
                --wait-seconds) WAIT_SECONDS=$2 ;;
            esac
            shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) die "Неизвестный параметр: $1. См. --help." ;;
    esac
done

[[ $EUID -eq 0 ]] || die 'Запустите от root на нужном сервере.'
for tool in openssl sha256sum awk ps hostname systemctl date readlink; do
    command -v "$tool" >/dev/null || die "Не найдена команда $tool."
done
PKCS12_READ_FLAGS=()
if [[ $(openssl version) == 'OpenSSL 3.'* ]]; then PKCS12_READ_FLAGS=(-legacy); fi
LOCAL_FQDN=$(hostname -f) || die 'Не удалось определить hostname -f.'
LOCAL_FQDN=${LOCAL_FQDN%.}
LOCAL_FQDN=${LOCAL_FQDN,,}
if [[ -z "$MODE" ]]; then
    WIZARD=1
    [[ -t 0 ]] || die 'Укажите --check или режим обновления; меню требует терминал.'
    say '1 — Проверить сертификаты и службы (по умолчанию)'
    say '2 — Обновить сертификаты хоста'
    say '3 — Обновить сертификаты Engine, если требуется'
    say '4 — Обновить Engine, если требуется, и сертификаты хоста'
    say '5 — Восстановить связь с хостом при неизвестных состояниях ВМ'
    read -r -p 'Режим [1]: ' answer || die 'Ввод прерван.'
    case "${answer:-1}" in 1) MODE=check ;; 2) MODE=host ;; 3) MODE=engine ;; 4) MODE=all ;; 5) MODE=recover ;; *) die 'Режим должен быть 1..5.' ;; esac
fi
if [[ "$MODE" != check && "$WIZARD" == 1 ]]; then
    if [[ -z "$FQDN" ]]; then
        read -r -p "FQDN этого сервера [$LOCAL_FQDN]: " FQDN || die 'Ввод прерван.'
    fi
    read -r -p "Срок сертификатов хоста, дней [$DAYS]: " answer || die 'Ввод прерван.'
    DAYS=${answer:-$DAYS}
    if [[ -z "$REFERENCE_DATE" ]]; then
        date '+Дата и время сервера: %Y-%m-%d %H:%M:%S %Z'
        read -r -p 'Фактическая дата по календарю (ГГГГ-ММ-ДД): ' REFERENCE_DATE || die 'Ввод прерван.'
    fi
fi
FQDN=${FQDN:-$LOCAL_FQDN}
FQDN=${FQDN%.}
FQDN=${FQDN,,}
[[ ${#FQDN} -le 253 && "$FQDN" == *.* && "$FQDN" != *..* ]] || die 'Укажите полное DNS-имя, например red3.cluster.'
IFS=. read -r -a fqdn_labels <<<"$FQDN"
for label in "${fqdn_labels[@]}"; do
    [[ ${#label} -ge 1 && ${#label} -le 63 && "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die 'Недопустимое DNS-имя.'
done
[[ "$DAYS" =~ ^[0-9]{1,4}$ ]] || die 'Срок должен быть целым числом дней.'
DAYS=$((10#$DAYS))
(( DAYS >= 1 && DAYS <= 1825 )) || die 'Допустимый срок: 1..1825 дней.'
[[ "$WAIT_SECONDS" =~ ^[0-9]{1,3}$ ]] || die 'Ожидание должно быть целым числом 0..900.'
WAIT_SECONDS=$((10#$WAIT_SECONDS))
(( WAIT_SECONDS <= 900 )) || die 'Допустимое ожидание: 0..900 секунд.'

cert_hash() {
    openssl x509 -in "$1" -noout -pubkey 2>/dev/null |
        openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}'
}

key_hash() {
    if [[ "$1" == *.p12 ]]; then
        openssl pkcs12 "${PKCS12_READ_FLAGS[@]}" -in "$1" -passin pass:mypass -nocerts -nodes 2>/dev/null |
            openssl pkey -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}'
    else
        openssl pkey -in "$1" -passin pass: -pubout -outform DER 2>/dev/null |
            sha256sum | awk '{print $1}'
    fi
}

fingerprint() {
    local fp
    fp=$(openssl x509 -in "$1" -noout -fingerprint -sha256) || return 1
    fp=${fp#*=}; fp=${fp//:/}; fp=${fp^^}
    printf '%s' "$fp"
}

pair_matches() {
    local a b
    a=$(cert_hash "$1") && b=$(key_hash "$2") && [[ "$a" == "$b" ]]
}

engine_containers_match() {
    local i pem_hash container_hash
    for ((i=0; i<${#ENGINE_LABELS[@]}; i++)); do
        pem_hash=$(openssl x509 -in "${ENGINE_CERTS[$i]}" -outform DER 2>/dev/null | sha256sum | awk '{print $1}') || return 1
        container_hash=$(openssl pkcs12 "${PKCS12_READ_FLAGS[@]}" -in "$ENGINE_PKI/keys/${ENGINE_LABELS[$i]}.p12" -passin pass:mypass -clcerts -nokeys 2>/dev/null |
            openssl x509 -outform DER 2>/dev/null | sha256sum | awk '{print $1}') || return 1
        [[ "$pem_hash" == "$container_hash" ]] || return 1
    done
}

host_san() {
    local cert=$1 line token result="DNS:$FQDN"
    local entries=()
    line=$(openssl x509 -in "$cert" -noout -text | awk '
        /X509v3 Subject Alternative Name:/ {san=1; next}
        san && /^[[:space:]]*(DNS:|IP Address:)/ {gsub(/IP Address:/,"IP:"); printf "%s,",$0; next}
        san {exit}') || return 1
    IFS=, read -r -a entries <<<"$line,$EXTRA_SAN"
    for token in "${entries[@]}"; do
        token=${token//[[:space:]]/}
        [[ -n "$token" ]] || continue
        case "$token" in
            DNS:*) [[ ${token#DNS:} =~ ^[A-Za-z0-9*_.-]+$ ]] || die 'Некорректный DNS SAN.' ;;
            IP:*) [[ ${token#IP:} =~ ^[A-Fa-f0-9:.]+$ ]] || die 'Некорректный IP SAN.' ;;
            *) die 'Для --san поддерживаются DNS:имя и IP:адрес.' ;;
        esac
        [[ ",$result," == *",$token,"* ]] || result="$result,$token"
    done
    printf '%s' "$result"
}

vm_processes() {
    local found proc exe base pid
    found=$(ps -eo pid=,comm= | awk '$2 ~ /^(qemu-system-|qemu-kvm$|kvm$|qemu$)/ {print}') || return 1
    if [[ -n "$found" ]]; then printf '%s\n' "$found"; return; fi
    # Also detect QEMU whose process name was changed with -name process=...
    for proc in /proc/[0-9]*; do
        exe=$(readlink "$proc/exe" 2>/dev/null) || continue
        base=${exe##*/}; base=${base% (deleted)}
        case "$base" in
            qemu-system-*|qemu-kvm|kvm|qemu)
                pid=${proc##*/}; printf '%s %s\n' "$pid" "$base" ;;
        esac
    done
}

show_vm_process_details() {
    local found=$1 pid rest arg previous name uuid
    while read -r pid rest; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        [[ -r "/proc/$pid/cmdline" ]] || continue
        previous=''; name=''; uuid=''
        while IFS= read -r -d '' arg; do
            if [[ "$previous" == -name ]]; then name=${arg#guest=}; name=${name%%,*}; fi
            if [[ "$previous" == -uuid && "$arg" =~ ^[a-fA-F0-9-]{36}$ ]]; then uuid=$arg; fi
            previous=$arg
        done <"/proc/$pid/cmdline"
        printf 'QEMU_PID=%s NAME=%q UUID=%s\n' "$pid" "${name:-unknown}" "${uuid:-unknown}"
    done <<<"$found"
}

require_no_vms() {
    local found
    found=$(vm_processes) || die 'Не удалось проверить процессы ВМ.'
    if [[ -n "$found" ]]; then
        printf 'RUNNING_QEMU_PROCESSES:\n%s\n' "$found" >&2
        show_vm_process_details "$found" >&2 || true
        say 'Список через локальный libvirt: virsh --readonly --connect qemu:///system list --all' >&2
        die 'Реальные ВМ работают. Для выбора способа их штатного завершения сохраните этот вывод; состояния в портале могут быть устаревшими.'
    fi
}

# Metadata reads only. PGOPTIONS also protects against accidental DB writes.
engine_query() {
    local output
    [[ -x "$DB_TOOL" ]] || return 1
    if ! output=$(timeout 12s env PGCONNECT_TIMEOUT=5 \
        PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout=5000 -c lock_timeout=2000' \
        "$DB_TOOL" -X -A -t -v ON_ERROR_STOP=1 -c "$1" 2>&1); then
        [[ -z "$WORK" ]] || printf '%s\n' "$output" >>"$WORK/runtime-query-errors.log"
        return 1
    fi
    case "$output" in
        *'ERROR:'*|*'FATAL:'*|*'PANIC:'*|*'ОШИБКА:'*|psql:*)
            [[ -z "$WORK" ]] || printf '%s\n' "$output" >>"$WORK/runtime-query-errors.log"
            return 1 ;;
    esac
    printf '%s\n' "$output"
}

runtime_cte() {
    cat <<SQL
WITH exact_hosts AS (
    SELECT vds_id FROM public.vds_static
    WHERE lower(host_name) = '$FQDN' OR lower(vds_name) = '$FQDN'
), chosen_hosts AS (
    SELECT vds_id FROM exact_hosts
    UNION ALL
    SELECT vds_id FROM public.vds_static
    WHERE NOT EXISTS (SELECT 1 FROM exact_hosts)
      AND (SELECT count(*) FROM public.vds_static) = 1
), local_vms AS (
    SELECT d.vm_guid, d.status FROM public.vm_dynamic d
    WHERE d.run_on_vds IN (SELECT vds_id FROM chosen_hosts)
       OR (d.run_on_vds IS NULL AND (SELECT count(*) FROM public.vds_static) = 1)
)
SQL
}

runtime_summary() {
    local output sql
    sql="$(runtime_cte)
SELECT (SELECT count(*) FROM chosen_hosts),
       COALESCE((SELECT d.status FROM public.vds_dynamic d
                 JOIN chosen_hosts h ON h.vds_id = d.vds_id LIMIT 1), -1),
       (SELECT count(*) FROM local_vms WHERE status IN (-1,7,8)),
       (SELECT count(*) FROM local_vms WHERE status IN (1,2,4,5,6,8,9,10,11,12,16)),
       (SELECT count(*) FROM local_vms),
       COALESCE((SELECT extract(epoch FROM max(d._update_date))::bigint
                 FROM public.vds_dynamic d JOIN chosen_hosts h ON h.vds_id=d.vds_id), 0);"
    output=$(engine_query "$sql") || return 1
    [[ "$output" =~ ^[0-9]+\|-?[0-9]+\|[0-9]+\|[0-9]+\|[0-9]+\|[0-9]+$ ]] || return 1
    printf '%s\n' "$output"
}

capture_runtime() {
    local label=$1 summary rows
    if ! summary=$(runtime_summary); then
        printf 'ENGINE_RUNTIME_%s=UNAVAILABLE\n' "$label"
        return 1
    fi
    [[ "$label" != BEFORE ]] || RUNTIME_BEFORE=$summary
    printf 'ENGINE_RUNTIME_%s=%s\n' "$label" "$summary"
    say 'Fields: matched_hosts | host_status | unknown_vms | active_vm_records | vm_records | host_updated_epoch'
    rows=$(engine_query "$(runtime_cte)
SELECT s.vm_name, d.status,
       CASE d.status WHEN -1 THEN 'Unassigned' WHEN 0 THEN 'Down' WHEN 1 THEN 'Up'
         WHEN 2 THEN 'PoweringUp' WHEN 4 THEN 'Paused' WHEN 5 THEN 'MigratingFrom'
         WHEN 6 THEN 'MigratingTo' WHEN 7 THEN 'Unknown' WHEN 8 THEN 'NotResponding'
         WHEN 9 THEN 'WaitForLaunch' WHEN 10 THEN 'RebootInProgress'
         WHEN 11 THEN 'SavingState' WHEN 12 THEN 'RestoringState'
         WHEN 13 THEN 'Suspended' WHEN 14 THEN 'ImageIllegal' WHEN 15 THEN 'ImageLocked'
         WHEN 16 THEN 'PoweringDown' ELSE 'Other' END
FROM local_vms d JOIN public.vm_static s ON s.vm_guid=d.vm_guid ORDER BY s.vm_name;") || return 1
    printf '%s\n' "$rows"
}

host_status_name() {
    case "$1" in
        1) printf Down ;; 2) printf Maintenance ;; 3) printf Up ;;
        4) printf NonResponsive ;; 10) printf NonOperational ;;
        12) printf Initializing ;; 13) printf Connecting ;; *) printf 'status_%s' "$1" ;;
    esac
}

wait_for_host_sync() {
    local deadline=$((SECONDS+WAIT_SECONDS)) summary count status unknown active total updated actual remaining delay fresh
    say 'Ожидание данных VDSM: хост Up и актуальные состояния ВМ...'
    while :; do
        if summary=$(runtime_summary); then
            IFS='|' read -r count status unknown active total updated <<<"$summary"
            fresh=0
            if (( updated >= SYNC_NOT_BEFORE )); then fresh=1; fi
            # Older installations may have a NULL _update_date. A changed status
            # after this operation is also evidence that Engine received data.
            if [[ -n "$RUNTIME_BEFORE" && "${summary%|*}" != "${RUNTIME_BEFORE%|*}" ]]; then fresh=1; fi
            printf 'HOST_MATCHES=%s HOST_STATUS=%s UNKNOWN_VMS=%s ACTIVE_VM_RECORDS=%s FRESH_REPORT=%s\n' \
                "$count" "$(host_status_name "$status")" "$unknown" "$active" "$fresh"
            if [[ "$count" == 1 && "$status" == 3 && "$unknown" == 0 && "$fresh" == 1 ]]; then
                actual=$(vm_processes) || return 1
                if [[ -n "$actual" || "$active" == 0 ]]; then
                    capture_runtime AFTER >"$WORK/runtime-after.txt" || true
                    say 'ENGINE_HOST_RECOVERY=OK'
                    return 0
                fi
                say 'Engine ещё считает ВМ работающими, а процессов QEMU нет; ожидаем следующий опрос.'
            fi
            if [[ "$count" == 1 && ( "$status" == 1 || "$status" == 2 ) ]]; then
                say 'Хост в Down/Maintenance: после обновления сертификатов выберите Management -> Activate в портале.'
                break
            fi
        else
            say 'ENGINE_RUNTIME=UNAVAILABLE; ожидаем доступность базы Engine.'
        fi
        (( SECONDS < deadline )) || break
        remaining=$((deadline-SECONDS)); delay=5
        (( remaining >= delay )) || delay=$remaining
        sleep "$delay"
    done
    capture_runtime AFTER >"$WORK/runtime-after.txt" || true
    printf 'RUNTIME_REPORT=%s/runtime-after.txt\n' "$WORK"
    say 'Связь/состояния ВМ ещё не подтверждены; сертификаты уже обновлены. Сохраните вывод для разбора.'
    return 1
}

show_cert() {
    local label=$1 cert=$2 key=$3 ca=$4 signature=UNKNOWN valid=UNKNOWN pair=FAIL
    if [[ ! -s "$cert" ]]; then printf '%s: MISSING\n' "$label"; return; fi
    printf '%s: ' "$label"
    openssl x509 -in "$cert" -noout -enddate || return
    if [[ -s "$ca" ]]; then
        if openssl verify -no_check_time -CAfile "$ca" "$cert" >/dev/null 2>&1; then signature=OK; else signature=FAIL; fi
        if openssl verify -CAfile "$ca" "$cert" >/dev/null 2>&1; then valid=OK; else valid=FAIL; fi
    fi
    if pair_matches "$cert" "$key"; then pair=OK; fi
    printf '  KEY=%s SIGNATURE=%s VALID_NOW=%s\n' "$pair" "$signature" "$valid"
}

report() {
    local unit status found name i
    printf 'SCRIPT_VERSION=%s\nMODE=%s\nFQDN=%s\n' "$VERSION" "$MODE" "$FQDN"
    date -u '+CURRENT_TIME=%Y-%m-%d %H:%M:%S UTC'
    if command -v rpm >/dev/null; then rpm -q ovirt-engine vdsm || true; fi
    found=$(vm_processes) || die 'Не удалось прочитать список процессов.'
    printf 'RUNNING_QEMU_PROCESSES=%s\n' "${found:-NONE}"
    [[ -z "$found" ]] || show_vm_process_details "$found" || true
    for unit in ovirt-engine libvirtd vdsmd; do
        status=$(systemctl is-active "$unit" 2>/dev/null) || true
        printf 'SERVICE_%s=%s\n' "$unit" "$status"
    done
    for name in ca qemu-ca; do
        printf '\nENGINE_%s\n' "$name"
        if [[ -s "$ENGINE_PKI/$name.pem" ]]; then
            openssl x509 -in "$ENGINE_PKI/$name.pem" -noout -subject -dates -fingerprint -sha256
        else say MISSING; fi
    done
    say ''
    for ((i=0; i<${#ENGINE_CERTS[@]}; i++)); do
        show_cert "ENGINE_${ENGINE_LABELS[$i]}" "${ENGINE_CERTS[$i]}" "${ENGINE_KEYS[$i]}" "$ENGINE_PKI/ca.pem" || true
    done
    for ((i=0; i<${#HOST_CERTS[@]}; i++)); do
        show_cert "HOST_${HOST_LABELS[$i]}" "${HOST_CERTS[$i]}" "${HOST_KEYS[$i]}" "$ENGINE_PKI/${HOST_CAS[$i]}.pem" || true
    done
    if engine_containers_match; then say 'ENGINE_PKCS12_CERTIFICATES=OK'; else say 'ENGINE_PKCS12_CERTIFICATES=FAIL'; fi
    if command -v timeout >/dev/null && [[ -x "$DB_TOOL" ]]; then capture_runtime CURRENT || true; fi
    say 'CERTIFICATE_CHECK_FINISHED'
}

if [[ "$MODE" == check ]]; then
    report
    exit 0
fi

finish() {
    local rc=$? i target tmp rollback_ok=1
    trap - EXIT HUP INT TERM
    set +e
    if (( rc != 0 && INSTALL_STARTED && ! INSTALLED )); then
        say 'Откат установки сертификатов хоста...'
        for ((i=0; i<${#TARGETS[@]}; i++)); do
            target=${TARGETS[$i]}
            tmp=$(mktemp "${target%/*}/.redvirt-rollback-XXXXXXXX")
            if [[ -n "$tmp" ]] && cp --preserve=all -- "$WORK/original/$i" "$tmp" && mv -fT -- "$tmp" "$target"; then :
            else rollback_ok=0; [[ -z "$tmp" ]] || rm -f -- "$tmp"; fi
        done
        if (( rollback_ok )); then say 'HOST_CERTIFICATE_ROLLBACK=OK'; else say 'HOST_CERTIFICATE_ROLLBACK=FAILED'; fi
    fi
    for tmp in "${PENDING[@]}"; do [[ ! -f "$tmp" ]] || rm -f -- "$tmp"; done
    if (( rc != 0 && HOST_STOPPED && ! CERTS_READY )); then
        if (( INSTALLED )); then
            say 'Установленные действующие сертификаты сохранены. Последние ошибки служб:'
            journalctl -b -u libvirtd -u vdsmd -u ovirt-engine -n 25 --no-pager -o cat >&2
        fi
        if (( rollback_ok )); then
            for unit in "${PREVIOUS_SOCKETS[@]}" "${PREVIOUS_UNITS[@]}"; do
                [[ "$unit" != ovirt-engine || "$IDENTITY_BROKEN" == 0 ]] || continue
                systemctl start "$unit" >/dev/null 2>&1
            done
        fi
    fi
    if (( rc != 0 )); then
        [[ -z "$WORK" ]] || printf 'RECOVERY_DIRECTORY=%s\n' "$WORK" >&2
        if (( ENGINE_PHASE )); then
            say 'Engine-setup мог изменить конфигурацию. Его база и PKI сохранены в текущем состоянии; нужен разбор ошибки.' >&2
        fi
        if (( CERTS_READY )); then say 'ENGINE_HOST_RECOVERY=PENDING' >&2
        else say 'CERTIFICATE_RENEWAL=FAILED' >&2; fi
    fi
    exit "$rc"
}
trap finish EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

for tool in engine-backup tar cp mv mktemp flock grep cmp cat mkdir rm tail journalctl timeout; do
    command -v "$tool" >/dev/null || die "Не найдена команда $tool."
done
[[ "${LOCAL_FQDN,,}" == "$FQDN" ]] || die "FQDN должен совпадать с hostname -f: $LOCAL_FQDN."
[[ "$REFERENCE_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die 'Укажите фактическую дату через --date YYYY-MM-DD или меню.'
[[ $(date -d "$REFERENCE_DATE" +%F 2>/dev/null) == "$REFERENCE_DATE" ]] || die 'Некорректная календарная дата.'
[[ $(date +%F) == "$REFERENCE_DATE" ]] || die 'Дата сервера не совпадает с фактической. Сначала восстановите правильное время.'
[[ -d "$ENGINE_PKI" && -d "$PKI/vdsm" ]] || die 'Нужны Engine и VDSM на одном сервере.'
[[ "$BACKUP_ROOT" == /* && -d "$BACKUP_ROOT" ]] || die '--backup-root должен указывать на существующую абсолютную папку.'
if systemctl is-active --quiet ovirt-ha-agent || systemctl is-active --quiet ovirt-ha-broker; then
    die 'Обнаружены службы HostedEngine. Этот сценарий предназначен для standalone Engine с локальным VDSM.'
fi
exec 9>/run/redvirt-certificates.lock
flock -n 9 || die 'Другой процесс этого скрипта уже работает.'
if [[ "$MODE" == recover ]]; then
    [[ -x "$DB_TOOL" ]] || die 'Для проверки восстановления нужен engine-psql.sh.'
    say 'Режим восстановления: статусы Unknown/Up в панели не блокируют обновление; проверяем фактические процессы.'
fi
require_no_vms
printf 'SCRIPT_VERSION=%s\nMODE=%s\nFQDN=%s\nHOST_CERTIFICATE_DAYS=%s\n' "$VERSION" "$MODE" "$FQDN" "$DAYS"
date -u '+CURRENT_TIME=%Y-%m-%d %H:%M:%S UTC'
say 'RUNNING_QEMU_PROCESSES=NONE'

ORIGINAL_CA=$(fingerprint "$ENGINE_PKI/ca.pem") || die 'Не читается CA Engine.'
ORIGINAL_QEMU_CA=$(fingerprint "$ENGINE_PKI/qemu-ca.pem") || die 'Не читается QEMU CA Engine.'
if [[ -n "$EXPECTED_CA" ]]; then
    EXPECTED_CA=${EXPECTED_CA##*=}; EXPECTED_CA=${EXPECTED_CA//:/}; EXPECTED_CA=${EXPECTED_CA// /}; EXPECTED_CA=${EXPECTED_CA^^}
    [[ "$EXPECTED_CA" =~ ^[0-9A-F]{64}$ && "$EXPECTED_CA" == "$ORIGINAL_CA" ]] || die 'Отпечаток CA не совпадает с указанным.'
fi
printf 'ENGINE_CA_SHA256=%s\n' "$ORIGINAL_CA"
for name in ca qemu-ca; do
    ca="$ENGINE_PKI/$name.pem"
    openssl verify -CAfile "$ca" "$ca" >/dev/null || die "Недействующий $name CA. Нужен отдельный разбор CA."
    openssl x509 -in "$ca" -noout -checkend "$((DAYS*86400))" >/dev/null || die "$name CA истекает раньше запрошенного срока сертификата."
    pair_matches "$ca" "$ENGINE_PKI/private/$name.pem" || die "CA $name не соответствует своему приватному ключу."
done
ORIGINAL_ENGINE_KEY=$(key_hash "$ENGINE_PKI/keys/engine_id_rsa") || die 'Не читается исходный приватный ключ Engine.'
[[ $(key_hash "$ENGINE_PKI/keys/engine.p12") == "$ORIGINAL_ENGINE_KEY" ]] || die 'engine.p12 и engine_id_rsa содержат разные ключи.'
for ((i=0; i<${#ENGINE_CERTS[@]}; i++)); do
    pair_matches "${ENGINE_CERTS[$i]}" "${ENGINE_KEYS[$i]}" || die "Сертификат/ключ Engine ${ENGINE_LABELS[$i]} не совпадают."
    openssl verify -no_check_time -CAfile "$ENGINE_PKI/ca.pem" "${ENGINE_CERTS[$i]}" >/dev/null || die "Сертификат Engine ${ENGINE_LABELS[$i]} подписан другим CA."
done
if [[ "$MODE" == host || "$MODE" == all || "$MODE" == recover ]]; then
    [[ -x "$SIGN_TOOL" ]] || die 'Не найден pki-enroll-request.sh.'
    grep -q -- '--ca-file=' "$SIGN_TOOL" || die 'Инструмент подписи не поддерживает выбор QEMU CA.'
    for ((i=0; i<${#HOST_CERTS[@]}; i++)); do
        pair_matches "${HOST_CERTS[$i]}" "${HOST_KEYS[$i]}" || die "Сертификат/ключ хоста ${HOST_LABELS[$i]} не совпадают."
        HOST_SANS[$i]=$(host_san "${HOST_CERTS[$i]}") || die 'Не удалось определить SAN хоста.'
    done
    # A replaced main CA requires restoring its original trust chain first.
    openssl verify -no_check_time -CAfile "$ENGINE_PKI/ca.pem" "${HOST_CERTS[0]}" >/dev/null || die 'VDSM подписан другим CA. Нужен отдельный разбор исходной PKI.'
fi
say 'EXISTING_CA_AND_PRIVATE_KEYS=OK'

engine_needs_renewal() {
    local cert
    engine_containers_match || return 0
    for cert in "${ENGINE_CERTS[@]}"; do
        openssl verify -CAfile "$ENGINE_PKI/ca.pem" "$cert" >/dev/null 2>&1 || return 0
        openssl x509 -in "$cert" -noout -checkend 5184000 >/dev/null 2>&1 || return 0
    done
    return 1
}

if [[ "$MODE" == host ]]; then
    engine_containers_match || die 'Сертификаты Engine в PKCS12 не соответствуют PEM; сначала нужен разбор PKI Engine.'
    for cert in "${ENGINE_CERTS[@]}"; do
        openssl verify -CAfile "$ENGINE_PKI/ca.pem" "$cert" >/dev/null || die 'Сначала обновите просроченные сертификаты Engine: режим 4 или --renew-all.'
    done
fi
if [[ "$MODE" == all || "$MODE" == engine || "$MODE" == recover ]]; then
    if engine_needs_renewal; then command -v engine-setup >/dev/null || die 'Не найден engine-setup.'; fi
fi

WORK=$(mktemp -d "$BACKUP_ROOT/redvirt-certs-${FQDN}-$(date +%Y%m%d-%H%M%S)-XXXXXXXX")
mkdir "$WORK/original"
printf 'RECOVERY_DIRECTORY=%s\n' "$WORK"
backup_paths=(etc/pki etc/ovirt-engine)
for path in etc/ovirt-engine-setup.conf.d etc/ovirt-engine-dwh etc/vdsm etc/libvirt; do
    [[ ! -e "/$path" ]] || backup_paths+=("$path")
done
tar --acls --xattrs --selinux -czf "$WORK/pki-config-before.tar.gz" -C / "${backup_paths[@]}"
tar -tzf "$WORK/pki-config-before.tar.gz" >/dev/null
say 'PKI_CONFIG_BACKUP=OK'
say 'Создание полной резервной копии Engine...'
engine-backup --mode=backup --scope=all --file="$WORK/engine-before.backup" --log="$WORK/engine-before.log" >"$WORK/engine-backup.out" 2>&1 || die "Ошибка резервного копирования Engine. Журнал: $WORK/engine-backup.out"
tar -tf "$WORK/engine-before.backup" >/dev/null
sha256sum "$WORK/pki-config-before.tar.gz" "$WORK/engine-before.backup" >"$WORK/SHA256SUMS"
printf 'FQDN=%s\nMODE=%s\nCA_SHA256=%s\nQEMU_CA_SHA256=%s\nENGINE_KEY_SPKI=%s\n' "$FQDN" "$MODE" "$ORIGINAL_CA" "$ORIGINAL_QEMU_CA" "$ORIGINAL_ENGINE_KEY" >"$WORK/recovery-info.txt"
say 'ENGINE_FULL_BACKUP=OK'
if [[ "$MODE" == recover ]]; then
    capture_runtime BEFORE >"$WORK/runtime-before.txt" || true
    cat "$WORK/runtime-before.txt"
fi

assert_engine_identity() {
    if [[ $(fingerprint "$ENGINE_PKI/ca.pem") != "$ORIGINAL_CA" ||
          $(fingerprint "$ENGINE_PKI/qemu-ca.pem") != "$ORIGINAL_QEMU_CA" ||
          $(key_hash "$ENGINE_PKI/keys/engine_id_rsa") != "$ORIGINAL_ENGINE_KEY" ||
          $(key_hash "$ENGINE_PKI/keys/engine.p12") != "$ORIGINAL_ENGINE_KEY" ]]; then
        IDENTITY_BROKEN=1
        systemctl stop ovirt-engine >/dev/null 2>&1 || true
        die 'CA или исходный ключ Engine изменился. Engine остановлен; требуется разбор по резервной копии.'
    fi
}

if [[ "$MODE" == all || "$MODE" == engine || "$MODE" == recover ]]; then
    if engine_needs_renewal; then
        require_no_vms
        say 'Обновление Engine штатным engine-setup --offline.'
        say 'На Renew certificates отвечайте Yes. На резервное копирование базы — Yes.'
        ENGINE_PHASE=1
        engine-setup --offline || die 'Engine-setup завершился с ошибкой; сертификаты хоста ещё не устанавливались.'
        assert_engine_identity
        engine_containers_match || die 'После engine-setup сертификаты PEM и PKCS12 не совпадают.'
        for ((i=0; i<${#ENGINE_CERTS[@]}; i++)); do
            pair_matches "${ENGINE_CERTS[$i]}" "${ENGINE_KEYS[$i]}" || die 'После engine-setup сертификат и ключ Engine не совпадают.'
            openssl verify -CAfile "$ENGINE_PKI/ca.pem" "${ENGINE_CERTS[$i]}" >/dev/null || die 'После engine-setup сертификаты Engine ещё недействительны.'
            openssl x509 -in "${ENGINE_CERTS[$i]}" -noout -checkend 5184000 >/dev/null || die 'Сертификат Engine не обновлён; повторите setup с ответом Yes на обновление сертификатов.'
        done
        systemctl restart ovirt-engine
        ENGINE_PHASE=0
        say 'ENGINE_CERTIFICATES_RENEWED=OK'
    else
        say 'ENGINE_CERTIFICATES_ALREADY_VALID=OK'
    fi
fi
if [[ "$MODE" == engine ]]; then
    assert_engine_identity
    say 'ENGINE_PRIVATE_KEY_UNCHANGED=OK'
    say 'CERTIFICATE_RENEWAL=OK'
    exit 0
fi

require_no_vms
assert_engine_identity
prefix="redvirt-renew-$(date -u +%Y%m%d%H%M%S)-$$"
for ((i=0; i<${#HOST_CERTS[@]}; i++)); do
    name="$prefix-${HOST_LABELS[$i]}"
    san=${HOST_SANS[$i]}
    # Reuse a certificate when roles already share the key, subject and SAN.
    # This also preserves installations where certificate paths are symlinks.
    spec="$(key_hash "${HOST_KEYS[$i]}")|$(openssl x509 -in "${HOST_CERTS[$i]}" -noout -subject -nameopt RFC2253)|${HOST_CAS[$i]}|$san"
    HOST_SIGN_SPECS[$i]=$spec
    reused=0
    for ((j=0; j<i; j++)); do
        if [[ "$spec" == "${HOST_SIGN_SPECS[$j]}" ]]; then
            cp -- "${WORK}/${HOST_LABELS[$j]}.pem" "$WORK/${HOST_LABELS[$i]}.pem"
            reused=1
            break
        fi
    done
    if (( reused )); then continue; fi
    openssl x509 -x509toreq -in "${HOST_CERTS[$i]}" -signkey "${HOST_KEYS[$i]}" -passin pass: \
        -out "$ENGINE_PKI/requests/$name.req" >>"$WORK/signing.log" 2>&1
    "$SIGN_TOOL" --name="$name" --days="$DAYS" --ca-file="${HOST_CAS[$i]}" --san="$san" >>"$WORK/signing.log" 2>&1 || {
        tail -n 18 "$WORK/signing.log" >&2
        die "Ошибка подписи ${HOST_LABELS[$i]}."
    }
    openssl x509 -in "$ENGINE_PKI/certs/$name.cer" -out "$WORK/${HOST_LABELS[$i]}.pem"
    pair_matches "$WORK/${HOST_LABELS[$i]}.pem" "${HOST_KEYS[$i]}" || die 'Новый сертификат не соответствует исходному ключу.'
    for purpose in sslserver sslclient; do
        openssl verify -CAfile "$ENGINE_PKI/${HOST_CAS[$i]}.pem" -purpose "$purpose" \
            -verify_hostname "$FQDN" "$WORK/${HOST_LABELS[$i]}.pem" >/dev/null
    done
done
say 'NEW_HOST_CERTIFICATES_VALIDATED=OK'

prepare_replacement() {
    local source=$1 target=$2 real tmp i
    [[ -s "$target" ]] || die "Отсутствует файл назначения $target."
    real=$(readlink -f -- "$target")
    [[ "$real" == "$PKI/"* && -f "$real" ]] || die "Неожиданный путь назначения $target."
    if cmp -s -- "$source" "$real"; then return; fi
    [[ "$real" != "$ENGINE_PKI/"* ]] || die 'Файл хоста ссылается на PKI Engine. Нужен отдельный разбор.'
    for ((i=0; i<${#TARGETS[@]}; i++)); do
        if [[ "${TARGETS[$i]}" == "$real" ]]; then
            cmp -s -- "${PENDING[$i]}" "$source" || die 'Разные сертификаты используют один файл через symlink. Нужен отдельный разбор.'
            return
        fi
    done
    i=${#TARGETS[@]}
    cp --preserve=all -- "$real" "$WORK/original/$i"
    printf '%s\t%s\n' "$i" "$real" >>"$WORK/replacements.tsv"
    tmp=$(mktemp "${real%/*}/.redvirt-cert-XXXXXXXX")
    TARGETS+=("$real"); PENDING+=("$tmp")
    cp --preserve=all -- "$real" "$tmp"
    cat -- "$source" >"$tmp"
}
for ((i=0; i<${#HOST_CERTS[@]}; i++)); do prepare_replacement "$WORK/${HOST_LABELS[$i]}.pem" "${HOST_CERTS[$i]}"; done
for target in "$PKI/vdsm/certs/cacert.pem" "$PKI/CA/cacert.pem" "$PKI/vdsm/libvirt-spice/ca-cert.pem" "$PKI/vdsm/libvirt-vnc/ca-cert.pem"; do
    prepare_replacement "$ENGINE_PKI/ca.pem" "$target"
done
prepare_replacement "$ENGINE_PKI/qemu-ca.pem" "$PKI/vdsm/libvirt-migrate/ca-cert.pem"
for unit in libvirtd supervdsmd vdsmd ovirt-engine; do
    if systemctl is-active --quiet "$unit"; then PREVIOUS_UNITS+=("$unit"); fi
done
for unit in libvirtd.socket libvirtd-ro.socket libvirtd-admin.socket libvirtd-tls.socket libvirtd-tcp.socket; do
    if systemctl is-active --quiet "$unit"; then PREVIOUS_SOCKETS+=("$unit"); fi
done

require_no_vms
say 'Временная остановка Engine, VDSM и libvirt для установки сертификатов...'
HOST_STOPPED=1
systemctl stop ovirt-engine
require_no_vms
systemctl stop vdsmd
if systemctl cat supervdsmd >/dev/null 2>&1; then systemctl stop supervdsmd; fi
for unit in "${PREVIOUS_SOCKETS[@]}"; do systemctl stop "$unit"; done
systemctl stop libvirtd
require_no_vms
assert_engine_identity

INSTALL_STARTED=1
for ((i=0; i<${#TARGETS[@]}; i++)); do mv -fT -- "${PENDING[$i]}" "${TARGETS[$i]}"; done
if command -v restorecon >/dev/null; then restorecon "${TARGETS[@]}"; fi
assert_engine_identity
INSTALLED=1
say 'HOST_CERTIFICATES_INSTALLED=OK'
systemctl reset-failed libvirtd vdsmd
if systemctl cat supervdsmd >/dev/null 2>&1; then systemctl reset-failed supervdsmd; fi
for unit in "${PREVIOUS_SOCKETS[@]}"; do systemctl start "$unit"; done
systemctl start libvirtd
systemctl start vdsmd
SYNC_NOT_BEFORE=$(date +%s)
systemctl start ovirt-engine
for unit in libvirtd vdsmd ovirt-engine; do
    status=$(systemctl is-active "$unit")
    printf 'SERVICE_%s=%s\n' "$unit" "$status"
done
for ((i=0; i<${#HOST_CERTS[@]}; i++)); do
    pair_matches "${HOST_CERTS[$i]}" "${HOST_KEYS[$i]}" || die 'Проверка установленного сертификата/ключа не прошла.'
    openssl verify -CAfile "$ENGINE_PKI/${HOST_CAS[$i]}.pem" "${HOST_CERTS[$i]}" >/dev/null
done
say 'ENGINE_PRIVATE_KEY_UNCHANGED=OK'
openssl x509 -in "${HOST_CERTS[0]}" -noout -subject -dates
printf 'RECOVERY_DIRECTORY=%s\n' "$WORK"
CERTS_READY=1
say 'CERTIFICATE_RENEWAL=OK'
if [[ "$MODE" == recover ]]; then
    if ! wait_for_host_sync; then exit 2; fi
fi
say 'Обновите страницу Hosts в портале и проверьте статус хоста.'
