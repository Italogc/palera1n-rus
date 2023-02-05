#!/usr/bin/env bash

pushd $(dirname "$0") &> /dev/null

mkdir -p logs
set -e 

log="$(date +%T)"-"$(date +%F)"-"$(uname)"-"$(uname -r)".log
cd logs
touch "$log"
cd ..

{

echo "[*] Команда запущена:`if [ $EUID = 0 ]; then echo " sudo"; fi` ./palera1n.sh $@"

# =========
# Variables
# =========
ipsw=""
network_timeout=-1 # seconds; -1 - unlimited
version="1.4.1"
os=$(uname)
dir="$(pwd)/binaries/$os"
commit=$(git rev-parse --short HEAD || true)
branch=$(git rev-parse --abbrev-ref HEAD || true)
max_args=1
arg_count=0
disk=8
fs=disk0s1s$disk

# =========
# Functions
# =========
remote_cmd() {
    "$dir"/sshpass -p 'alpine' ssh -o StrictHostKeyChecking=no -p6413 root@localhost "$@"
}

remote_cp() {
    "$dir"/sshpass -p 'alpine' scp -o StrictHostKeyChecking=no -P6413 $@
}

step() {
    for i in $(seq "$1" -1 0); do
        if [ "$(get_device_mode)" = "dfu" ]; then
            break
        fi
        printf '\r\e[K\e[1;36m%s (%d)' "$2" "$i"
        sleep 1
    done
    printf '\e[0m\n'
}

print_help() {
    cat << EOF
Использование: $0 [Options] [ subcommand | iOS version ]
iOS 15.0-16.3 инструмент джейлбрейка для checkm8 устройств

Опции:
    --help              Напишите это для помощи
    --tweaks            Активировать твики
    --semi-tethered     При использовании с --tweaks джейлбрейк станет полупривязанным, а не привязанным.
    --dfuhelper         Помощник, помогающий перевести устройства A11 в режим DFU из режима восстановления.
    --skip-fakefs       Не создавайть fakefs, даже если указан --semi-tethered
    --no-baseband       Укажите, что устройство не имеет baseband
    --restorerootfs     Удалить джейлбрейк (На самом деле больше, чем восстановление rootfs)
    --debug             Отладка скрипта
    --china             Включить специальные обходные пути для материкового Китая (启用对中国大陆网络环境的替代办法)
    --ipsw              Укажите пользовательский IPSW для использования
    --serial            Enable serial output on the device (only needed for testing with a serial cable)

Подкоманды:
    dfuhelper           Псевдоним для --dfuhelper
    clean               Удаляет созданные загрузочные файлы

Версией iOS в команде должена быть версия iOS вашего устройства.
Это требуется при запуске из режима DFU.
EOF
}

parse_opt() {
    case "$1" in
        --)
            no_more_opts=1
            ;;
        --tweaks)
            tweaks=1
            ;;
        --semi-tethered)
            semi_tethered=1
            ;;
        --dfuhelper)
            dfuhelper=1
            ;;
        --skip-fakefs)
            skip_fakefs=1
            ;;
        --no-baseband)
            no_baseband=1
            ;;
        --serial)
            serial=1
            ;;
        --dfu)
            echo "[!] Устройства в режиме DFU теперь обнаруживаются автоматически, а параметр --dfu устарел."
            ;;
        --restorerootfs)
            restorerootfs=1
            ;;
        --china)
            china=1
            ;;
        --ipsw)
            ipsw=$2
            ;;
        --ipsw=*)
            ipsw=${1#*=}
            ;;
        --debug)
            debug=1
            ;;
        --help)
            print_help
            exit 0
            ;;
        *)
            echo "[-] Неизвестная опция $1. Используйте $0 --help для помощи."
            exit 1;
    esac
}

parse_arg() {
    arg_count=$((arg_count + 1))
    case "$1" in
        dfuhelper)
            dfuhelper=1
            ;;
        clean)
            clean=1
            ;;
        *)
            version="$1"
            ;;
    esac
}

parse_cmdline() {
    for arg in $@; do
        if [[ "$arg" == --* ]] && [ -z "$no_more_opts" ]; then
            parse_opt "$arg";
        elif [ "$arg_count" -lt "$max_args" ]; then
            parse_arg "$arg";
        elif [[ $arg == http* ]]; then
            continue
        else
            echo "[-] Слишком много аргументов. Используйте $0 --help для помощи.";
            exit 1;
        fi
    done
}

recovery_fix_auto_boot() {
    if [ "$tweaks" = "1" ]; then
        "$dir"/irecovery -c "setenv auto-boot false"
        "$dir"/irecovery -c "saveenv"
    else
        "$dir"/irecovery -c "setenv auto-boot true"
        "$dir"/irecovery -c "saveenv"
    fi

    if [ "$semi_tethered" = "1" ]; then
        "$dir"/irecovery -c "setenv auto-boot true"
        "$dir"/irecovery -c "saveenv"
    fi
}

_info() {
    if [ "$1" = 'восстановление' ]; then
        echo $("$dir"/irecovery -q | grep "$2" | sed "s/$2: //")
    elif [ "$1" = 'обычный' ]; then
        echo $("$dir"/ideviceinfo | grep "$2: " | sed "s/$2: //")
    fi
}

_pwn() {
    pwnd=$(_info recovery PWND)
    if [ "$pwnd" = "" ]; then
        echo "[*] Pwning устройства"
        "$dir"/gaster pwn
        sleep 2
        #"$dir"/gaster reset
        #sleep 1
    fi
}

_reset() {
    echo "[*] Сброс состояния DFU"
    "$dir"/gaster reset
}

get_device_mode() {
    if [ "$os" = "Darwin" ]; then
        apples="$(system_profiler SPUSBDataType 2> /dev/null | grep -B1 'Vendor ID: 0x05ac' | grep 'Product ID:' | cut -dx -f2 | cut -d' ' -f1 | tail -r)"
    elif [ "$os" = "Linux" ]; then
        apples="$(lsusb | cut -d' ' -f6 | grep '05ac:' | cut -d: -f2)"
    fi
    local device_count=0
    local usbserials=""
    for apple in $apples; do
        case "$apple" in
            12a8|12aa|12ab)
            device_mode=normal
            device_count=$((device_count+1))
            ;;
            1281)
            device_mode=recovery
            device_count=$((device_count+1))
            ;;
            1227)
            device_mode=dfu
            device_count=$((device_count+1))
            ;;
            1222)
            device_mode=diag
            device_count=$((device_count+1))
            ;;
            1338)
            device_mode=checkra1n_stage2
            device_count=$((device_count+1))
            ;;
            4141)
            device_mode=pongo
            device_count=$((device_count+1))
            ;;
        esac
    done
    if [ "$device_count" = "0" ]; then
        device_mode=none
    elif [ "$device_count" -ge "2" ]; then
        echo "[-] Подключите только одно устройство" > /dev/tty
        kill -30 0
        exit 1;
    fi
    if [ "$os" = "Linux" ]; then
        usbserials=$(cat /sys/bus/usb/devices/*/serial)
    elif [ "$os" = "Darwin" ]; then
        usbserials=$(system_profiler SPUSBDataType 2> /dev/null | grep 'Serial Number' | cut -d: -f2- | sed 's/ //')
    fi
    if grep -qE '(ramdisk tool|SSHRD_Script) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) [0-9]{1,2} [0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2}' <<< "$usbserials"; then
        device_mode=ramdisk
    fi
    echo "$device_mode"
}

_wait() {
    if [ "$(get_device_mode)" != "$1" ]; then
        echo "[*] Ожидание устройства в режиме: $1"
    fi

    while [ "$(get_device_mode)" != "$1" ]; do
        sleep 1
    done

    if [ "$1" = 'восстановление' ]; then
        recovery_fix_auto_boot;
    fi
}

dfuhelper_first_try=true
_dfuhelper() {
    local step_one;
    deviceid=$( [ -z "$deviceid" ] && _info normal ProductType || echo $deviceid )
    if [[ "$1" = 0x801* && "$deviceid" != *"iPad"* ]]; then
        step_one="Удерживайте громкость вниз + боковую кнопку питания"
    else
        step_one="Зажмите «Домой» + кнопку питания"
    fi
    if $dfuhelper_first_try; then
        echo "[*] Нажмите любую клавишу, когда будете готовы к режиму DFU."
        read -n 1 -s
        dfuhelper_first_try=false
    fi
    step 3 "Приготовьтесь"
    step 4 "$step_one" &
    sleep 3
    "$dir"/irecovery -c "reset" &
    wait
    if [[ "$1" = 0x801* && "$deviceid" != *"iPad"* ]]; then
        step 10 'Отпустите кнопку питания, но продолжайте удерживать громкость вниз'
    else
        step 10 'Отпустите кнопку питания, но продолжайте удерживать кнопку «Домой»'
    fi
    sleep 1
    
    if [ "$(get_device_mode)" = "dfu" ]; then
        echo "[*] Устройство вошло в DFU!"
        dfuhelper_first_try=true
    else
        echo "[-] Устройство не перешло в режим DFU"
        return -1
    fi
}

function _wait_for() {
    timeout=$1
    shift 1
    until [ $timeout -eq 0 ] || ("$@" &> /dev/null); do
        sleep 1
        timeout=$(( timeout - 1 ))
    done
    if [ $timeout -eq 0 ]; then
        return -1
    fi
}

function _network() {
    ping -q -c 1 -W 1 static.palera.in &>/dev/null
}

function _check_network_connection() {
    if ! _network; then
        echo "[*] Ожидание сети"
        if ! _wait_for $network_timeout _network; then
            echo "[-] Сеть недоступна. Проверьте подключение и повторите попытку"
            exit 1
        fi
    fi
}

_kill_if_running() {
    if (pgrep -u root -x "$1" &> /dev/null > /dev/null); then
        # yes, it's running as root. kill it
        sudo killall $1 &> /dev/null
    else
        if (pgrep -x "$1" &> /dev/null > /dev/null); then
            killall $1 &> /dev/null
        fi
    fi
}

_exit_handler() {
    [ $? -eq 0 ] && exit
    echo "[-] Произошла ошибка"

    if [ -d "logs" ]; then
        cd logs
        mv "$log" FAIL_${log}
        cd ..
    fi

    echo "[*] Ведется лог неудач. Если вы собираетесь обратиться за помощью, пожалуйста, прикрепите последний лог."
}
trap _exit_handler EXIT

# ===========
# Fixes
# ===========

# ============
# Start
# ============

echo "palera1n | Version $version-$branch-$commit"
echo "Сделано с ❤ разработчиками: Nebula, Mineek, Nathan, llsc12, Ploosh, и Nick Chan"
echo "Переведено на русский язык: JustRals"
echo "P.S. В переводе могут содержаться незначительные ошибки."
echo ""

version=""
parse_cmdline "$@"

if [ "$debug" = "1" ]; then
    set -o xtrace
fi

# ============
# Dependencies
# ============

# Check for required commands
if [ "$os" = 'Linux' ]; then
    linux_cmds='lsusb'
fi

for cmd in curl unzip python3 git ssh scp killall sudo grep pgrep ${linux_cmds}; do
    if ! command -v "${cmd}" > /dev/null; then
        echo "[-] Команда '${cmd}' не установлена, пожалуйста установите её!";
        cmd_not_found=1
    fi
done
if [ "$cmd_not_found" = "1" ]; then
    exit 1
fi

# Download gaster
if [ -e "$dir"/gaster ]; then
    "$dir"/gaster &> /dev/null > /dev/null | grep -q 'usb_timeout: 5' && rm "$dir"/gaster
fi

if [ ! -e "$dir"/gaster ]; then
    echo '[-] gaster не установлен. Нажмите любую клавишу, чтобы установить его, или нажмите ctrl + c, чтобы отменить'
    read -n 1 -s
    _check_network_connection
    curl -sLO https://static.palera.in/deps/gaster-"$os".zip
    unzip gaster-"$os".zip
    mv gaster "$dir"/
    rm -rf gaster gaster-"$os".zip
fi

# Check for pyimg4
if ! python3 -c 'import pkgutil; exit(not pkgutil.find_loader("pyimg4"))'; then
    echo '[-] pyimg4 не установлен. Нажмите любую клавишу, чтобы установить его, или нажмите ctrl + c, чтобы отменить'
    read -n 1 -s
    _check_network_connection
    python3 -m pip install pyimg4
fi

# ============
# Prep
# ============

# Update submodules
if [ "$china" != "1" ]; then
    git submodule update --init --recursive
elif ! [ -f ramdisk/sshrd.sh ]; then
    curl -LO https://static.palera.in/deps/ramdisk.tgz
    tar xf ramdisk.tgz
fi

# Re-create work dir if it exists, else, make it
if [ -e work ]; then
    rm -rf work
    mkdir work
else
    mkdir work
fi

chmod +x "$dir"/*
#if [ "$os" = 'Darwin' ]; then
#    xattr -d com.apple.quarantine "$dir"/*
#fi

if [ "$clean" = "1" ]; then
    rm -rf boot* work .tweaksinstalled
    echo "[*] Удалены созданные загрузочные файлы"
    exit
fi

if [ -z "$tweaks" ] && [ "$semi_tethered" = "1" ]; then
    echo "[!] --semi-tethered нельзя использовать с Rootless"
    echo "    Rootless уже semi-tethered"
    >&2 echo " Подсказка: чтобы использовать твики на semi-tethered, укажите --tweaks опцию"
    exit 1;
fi

if [ "$tweaks" = 1 ] && [ ! -e ".tweaksinstalled" ] && [ ! -e ".disclaimeragree" ] && [ -z "$semi_tethered" ] && [ -z "$restorerootfs" ]; then
    echo "!!! ПРЕДУПРЕЖДЕНИЕ ПРЕДУПРЕЖДЕНИЕ ПРЕДУПРЕЖДЕНИЕ !!!"
    echo "This flag will add tweak support BUT WILL BE TETHERED."
    echo "ЭТО ТАКЖЕ ОЗНАЧАЕТ, ЧТО ВАМ ПОТРЕБУЕТСЯ ПК КАЖДЫЙ РАЗ ДЛЯ ЗАГРУЗКИ."
    echo "ЭТО РАБОТАЕТ НА 15.0-16.3"
    echo "НЕ ЗЛИТЕСЬ НА НАС, ЕСЛИ ВАШЕ УСТРОЙСТВО ЗАБЛОКИРОВАЛОСЬ, ЭТО ВАША САМАЯ ВИНА, И МЫ ВАС ПРЕДУПРЕЖДАЛИ"
    echo "ВЫ ПОНИМАЕТЕ? НАПИШИТЕ «Yes, do as I say», ЧТОБЫ ПРОДОЛЖИТЬ"
    read -r answer
    if [ "$answer" = 'Yes, do as I say' ]; then
        echo "Вы ДЕЙСТВИТЕЛЬНО уверены? МЫ ВАС ПРЕДУПРЕЖДАЕМ!"
        echo "Введите «Yes, I am sure», чтобы продолжить"
        read -r answer
        if [ "$answer" = 'Yes, I am sure' ]; then
            echo "[*] Активируем твики"
            tweaks=1
            touch .disclaimeragree
        else
            echo "[-] Пожалуйста, введите его точно, если вы хотите продолжить. В противном случае удалите --tweaks или добавьте --semi-tethered"
            exit
        fi
    else
        echo "[-] Пожалуйста, введите его точно, если вы хотите продолжить. В противном случае удалите --tweaks или добавьте --semi-tethered"
        exit
    fi
fi

function _wait_for_device() {
    # Get device's iOS version from ideviceinfo if in normal mode
    echo "[*] Ожидание устройств"
    while [ "$(get_device_mode)" = "none" ]; do
        sleep 1;
    done
    echo $(echo "[*] Обнаружен $(get_device_mode) режим устройства" | sed 's/dfu/DFU/')

    if grep -E 'pongo|checkra1n_stage2|diag' <<< "$(get_device_mode)"; then
        echo "[-] Обнаруженное устройство в неподдерживаемом режиме '$(get_device_mode)'"
        exit 1;
    fi

    if [ "$(get_device_mode)" != "normal" ] && [ -z "$version" ] && [ "$dfuhelper" != "1" ]; then
        echo "[-] Вы должны вставить версию, на которой находится ваше устройство, если вы не запускаете его из обычного режима."
        exit
    fi

    if [ "$(get_device_mode)" = "ramdisk" ]; then
        # If a device is in ramdisk mode, perhaps iproxy is still running?
        _kill_if_running iproxy
        echo "[*] Перезагрузка устройства в SSH Ramdisk"
        if [ "$os" = 'Linux' ]; then
            sudo "$dir"/iproxy 6413 22 >/dev/null &
        else
            "$dir"/iproxy 6413 22 >/dev/null &
        fi
        sleep 2
        remote_cmd "/usr/sbin/nvram auto-boot=false"
        remote_cmd "/sbin/reboot"
        _kill_if_running iproxy
        _wait recovery
    fi

    if [ "$(get_device_mode)" = "normal" ]; then
        version=${version:-$(_info normal ProductVersion)}
        arch=$(_info normal CPUArchitecture)
        if [ "$arch" = "arm64e" ]; then
            echo "[-] palera1n не работает и никогда не будет работать на устройствах, не поддерживающих checkm8."
            exit
        fi
        echo "Привет, $(_info normal ProductType) на $version!"

        echo "[*] Переключение устройства в режим восстановления..."
        "$dir"/ideviceenterrecovery $(_info normal UniqueDeviceID)
        _wait recovery
    fi

    # Grab more info
    echo "[*] Получение информации об устройстве..."
    cpid=$(_info recovery CPID)
    model=$(_info recovery MODEL)
    deviceid=$(_info recovery PRODUCT)

    if (( 0x8020 <= cpid )) && (( cpid < 0x8720 )); then
        echo "[-] palera1n не работает и никогда не будет работать на устройствах, не поддерживающих checkm8."
        exit
    fi

    if [ "$dfuhelper" = "1" ]; then
        echo "[*] Запуск помощника DFU"
        _dfuhelper "$cpid" || {
            echo "[-] Не удалось войти в режим DFU, повторите попытку"
            sleep 3
            _wait_for_device
        }
        exit
    fi

    if [ ! "$ipsw" = "" ]; then
        ipswurl=$ipsw
    else
        #buildid=$(curl -sL https://api.ipsw.me/v4/ipsw/$version | "$dir"/jq '.[0] | .buildid' --raw-output)
        if [[ "$deviceid" == *"iPad"* ]]; then
            device_os=iPadOS
            device=iPad
        elif [[ "$deviceid" == *"iPod"* ]]; then
            device_os=iOS
            device=iPod
        else
            device_os=iOS
            device=iPhone
        fi

        _check_network_connection
        buildid=$(curl -sL https://api.ipsw.me/v4/ipsw/$version | "$dir"/jq '[.[] | select(.identifier | startswith("'$device'")) | .buildid][0]' --raw-output)
        if [ "$buildid" == "19B75" ]; then
            buildid=19B74
        fi
        ipswurl=$(curl -sL https://api.appledb.dev/ios/$device_os\;$buildid.json | "$dir"/jq -r .devices\[\"$deviceid\"\].ipsw)
    fi

    if [ "$restorerootfs" = "1" ]; then
        rm -rf "blobs/"$deviceid"-"$version".der" "boot-$deviceid" work .tweaksinstalled ".fs-$deviceid"
    fi

    # Have the user put the device into DFU
    if [ "$(get_device_mode)" != "dfu" ]; then
        recovery_fix_auto_boot;
        _dfuhelper "$cpid" || {
            echo "[-] Не удалось войти в режим DFU, повторите попытку."
            sleep 3
            _wait_for_device
        }
    fi
    sleep 2
}
_wait_for_device

# ============
# Ramdisk
# ============

# Dump blobs, and install pogo if needed 
if [ -f blobs/"$deviceid"-"$version".der ]; then
    if [ -f .rd_in_progress ]; then
        rm blobs/"$deviceid"-"$version".der
    fi
fi

if [ ! -f blobs/"$deviceid"-"$version".der ]; then
    mkdir -p blobs
    _kill_if_running iproxy

    cd ramdisk
    chmod +x sshrd.sh
    echo "[*] Создание ramdisk"
    ./sshrd.sh `if [[ "$version" == *"16"* ]]; then echo "16.0.3"; else echo "15.6"; fi` `if [ -z "$tweaks" ]; then echo "rootless"; fi`

    echo "[*] Загрузка ramdisk"
    ./sshrd.sh boot
    cd ..
    # remove special lines from known_hosts
    if [ -f ~/.ssh/known_hosts ]; then
        if [ "$os" = "Darwin" ]; then
            sed -i.bak '/localhost/d' ~/.ssh/known_hosts
            sed -i.bak '/127\.0\.0\.1/d' ~/.ssh/known_hosts
        elif [ "$os" = "Linux" ]; then
            sed -i '/localhost/d' ~/.ssh/known_hosts
            sed -i '/127\.0\.0\.1/d' ~/.ssh/known_hosts
        fi
    fi

    # Execute the commands once the rd is booted
    if [ "$os" = 'Linux' ]; then
        sudo "$dir"/iproxy 6413 22 >/dev/null &
    else
        "$dir"/iproxy 6413 22 >/dev/null &
    fi

    while ! (remote_cmd "echo connected" &> /dev/null); do
        sleep 1
    done

    touch .rd_in_progress
    
    if [ "$tweaks" = "1" ]; then
        echo "[*] Проверка наличия baseband"
        if [ "$(remote_cmd "/usr/bin/mgask HasBaseband | grep -E 'true|false'")" = "true" ] && [[ "${cpid}" == *"0x700"* ]]; then
            disk=7
        elif [ "$(remote_cmd "/usr/bin/mgask HasBaseband | grep -E 'true|false'")" = "false" ]; then
            if [[ "${cpid}" == *"0x700"* ]]; then
                disk=6
            else
                disk=7
            fi
        fi

        if [ -z "$semi_tethered" ]; then
            disk=1
        fi

        if [[ "$version" == *"16"* ]]; then
            fs=disk1s$disk
        else
            fs=disk0s1s$disk
        fi

        echo "$disk" > .fs-"$deviceid"
    fi

    # mount filesystems, no user data partition
    remote_cmd "/usr/bin/mount_filesystems_nouser"

    has_active=$(remote_cmd "ls /mnt6/active" 2> /dev/null)
    if [ ! "$has_active" = "/mnt6/active" ]; then
        echo "[!] Активный файл не существует! Пожалуйста, используйте SSH для его создания"
        echo "    /mnt6/active должен содержать имя UUID в /mnt6"
        echo "    Когда закончите, введите reboot в сеансе SSH, затем перезапустите скрипт."
        echo "    ssh root@localhost -p 6413"
        exit
    fi
    active=$(remote_cmd "cat /mnt6/active" 2> /dev/null)

    if [ "$restorerootfs" = "1" ]; then
        echo "[*] Удаление джейлбрейка"
        if [ ! "$fs" = "disk1s1" ] || [ ! "$fs" = "disk0s1s1" ]; then
            remote_cmd "/sbin/apfs_deletefs $fs > /dev/null || true"
        fi
        remote_cmd "rm -f /mnt6/$active/System/Library/Caches/com.apple.kernelcaches/kcache.raw /mnt6/$active/System/Library/Caches/com.apple.kernelcaches/kcache.patched /mnt6/$active/System/Library/Caches/com.apple.kernelcaches/kcache.im4p /mnt6/$active/System/Library/Caches/com.apple.kernelcaches/kernelcachd"
        remote_cmd "mv /mnt6/$active/System/Library/Caches/com.apple.kernelcaches/kernelcache.bak /mnt6/$active/System/Library/Caches/com.apple.kernelcaches/kernelcache || true"
        remote_cmd "/bin/sync"
        remote_cmd "/usr/sbin/nvram auto-boot=true"
        rm -f BuildManifest.plist
        echo "[*] Готово! Перезагрузка вашего устройства (если оно не перезагружается, вы можете принудительно перезагрузить))"
        remote_cmd "/sbin/reboot"
        exit;
    fi

    echo "[*] Сброс аптикета"
    sleep 1
    remote_cp root@localhost:/mnt6/$active/System/Library/Caches/apticket.der blobs/"$deviceid"-"$version".der
    #remote_cmd "cat /dev/rdisk1" | dd of=dump.raw bs=256 count=$((0x4000)) 
    #"$dir"/img4tool --convert -s blobs/"$deviceid"-"$version".shsh2 dump.raw
    #rm dump.raw

    if [ "$semi_tethered" = "1" ]; then
        if [ -z "$skip_fakefs" ]; then
            echo "[*] Создание fakefs, это может занять некоторое время (до 10 минут)"
            remote_cmd "/sbin/newfs_apfs -A -D -o role=r -v Xystem /dev/disk0s1" && {
            sleep 2
            remote_cmd "/sbin/mount_apfs /dev/$fs /mnt8"
            sleep 1
            remote_cmd "cp -a /mnt1/. /mnt8/"
            sleep 1
            echo "[*] fakefs создан, продолжаем..."
            } || echo "[*] Используя старый fakefs, запустите restorerootfs, если вам нужно его почистить" 
        fi
    fi

    #remote_cmd "/usr/sbin/nvram allow-root-hash-mismatch=1"
    #remote_cmd "/usr/sbin/nvram root-live-fs=1"
    if [ "$tweaks" = "1" ]; then
        if [ "$semi_tethered" = "1" ]; then
            remote_cmd "/usr/sbin/nvram auto-boot=true"
        else
            remote_cmd "/usr/sbin/nvram auto-boot=false"
        fi
    else
        remote_cmd "/usr/sbin/nvram auto-boot=true"
    fi

    # lets actually patch the kernel
    echo "[*] Исправление kernel"
    remote_cmd "rm -f /mnt6/$active/kpf"
    if [[ "$version" == *"16"* ]]; then
        remote_cp binaries/Kernel16Patcher.ios root@localhost:/mnt6/$active/kpf
    else
        remote_cp binaries/Kernel15Patcher.ios root@localhost:/mnt6/$active/kpf
    fi
    remote_cmd "/usr/sbin/chown 0 /mnt6/$active/kpf"
    remote_cmd "/bin/chmod 755 /mnt6/$active/kpf"

    remote_cmd "rm -f /mnt6/$active/System/Library/Caches/com.apple.kernelcaches/kcache.raw /mnt6/$active/System/Library/Caches/com.apple.kernelcaches/kcache.patched /mnt6/$active/System/Library/Caches/com.apple.kernelcaches/kcache.im4p /mnt6/$active/System/Library/Caches/com.apple.kernelcaches/kernelcachd"
    if [ "$tweaks" = "1" ]; then
        if [ "$semi_tethered" = "1" ]; then
            remote_cmd "cp /mnt6/$active/System/Library/Caches/com.apple.kernelcaches/kernelcache /mnt6/$active/System/Library/Caches/com.apple.kernelcaches/kernelcache.bak"
        else
            remote_cmd "mv /mnt6/$active/System/Library/Caches/com.apple.kernelcaches/kernelcache /mnt6/$active/System/Library/Caches/com.apple.kernelcaches/kernelcache.bak || true"
        fi
    fi
    sleep 1

    # Checking network connection before downloads
    _check_network_connection

    # download the kernel
    echo "[*] Скачивание BuildManifest"
    "$dir"/pzb -g BuildManifest.plist "$ipswurl"

    echo "[*] Загрузка kernelcache"
    "$dir"/pzb -g "$(awk "/""$model""/{x=1}x&&/kernelcache.release/{print;exit}" BuildManifest.plist | grep '<string>' | cut -d\> -f2 | cut -d\< -f1)" "$ipswurl"
    
    echo "[*] Исправление kernelcache"
    mv kernelcache.release.* work/kernelcache
    if [[ "$deviceid" == "iPhone8"* ]] || [[ "$deviceid" == "iPad6"* ]] || [[ "$deviceid" == *'iPad5'* ]]; then
        python3 -m pyimg4 im4p extract -i work/kernelcache -o work/kcache.raw --extra work/kpp.bin
    else
        python3 -m pyimg4 im4p extract -i work/kernelcache -o work/kcache.raw
    fi
    sleep 1
    remote_cp work/kcache.raw root@localhost:/mnt6/$active/System/Library/Caches/com.apple.kernelcaches/
    remote_cmd "/mnt6/$active/kpf /mnt6/$active/System/Library/Caches/com.apple.kernelcaches/kcache.raw /mnt6/$active/System/Library/Caches/com.apple.kernelcaches/kcache.patched"
    remote_cp root@localhost:/mnt6/$active/System/Library/Caches/com.apple.kernelcaches/kcache.patched work/
    if [ "$tweaks" = "1" ]; then
        if [[ "$version" == *"16"* ]]; then
            "$dir"/Kernel64Patcher work/kcache.patched work/kcache.patched2 -e -o -u -l -t -h -d
        else
            "$dir"/Kernel64Patcher work/kcache.patched work/kcache.patched2 -e -l
        fi
    else
        "$dir"/Kernel64Patcher work/kcache.patched work/kcache.patched2 -a
    fi
    
    sleep 1
    if [[ "$deviceid" == *'iPhone8'* ]] || [[ "$deviceid" == *'iPad6'* ]] || [[ "$deviceid" == *'iPad5'* ]]; then
        python3 -m pyimg4 im4p create -i work/kcache.patched2 -o work/kcache.im4p -f krnl --extra work/kpp.bin --lzss
    else
        python3 -m pyimg4 im4p create -i work/kcache.patched2 -o work/kcache.im4p -f krnl --lzss
    fi
    sleep 1
    remote_cp work/kcache.im4p root@localhost:/mnt6/$active/System/Library/Caches/com.apple.kernelcaches/
    remote_cmd "img4 -i /mnt6/$active/System/Library/Caches/com.apple.kernelcaches/kcache.im4p -o /mnt6/$active/System/Library/Caches/com.apple.kernelcaches/kernelcachd -M /mnt6/$active/System/Library/Caches/apticket.der"
    remote_cmd "rm -f /mnt6/$active/System/Library/Caches/com.apple.kernelcaches/kcache.raw /mnt6/$active/System/Library/Caches/com.apple.kernelcaches/kcache.patched /mnt6/$active/System/Library/Caches/com.apple.kernelcaches/kcache.im4p"

    sleep 1
    has_kernelcachd=$(remote_cmd "ls /mnt6/$active/System/Library/Caches/com.apple.kernelcaches/kernelcachd" 2> /dev/null)
    if [ "$has_kernelcachd" = "/mnt6/$active/System/Library/Caches/com.apple.kernelcaches/kernelcachd" ]; then
        echo "[*] Пользовательский kernelcache теперь существует!"
    else
        echo "[!] Пользовательского kernelcache не существует..? Пожалуйста, отправьте лог и сообщите об этой ошибке..."
    fi

    if [ "$tweaks" = "1" ]; then
        sleep 1
        if [ "$semi_tethered" = "1" ]; then
            remote_cmd "/sbin/mount_apfs /dev/$fs /mnt8 || true"
            di=8
        else
            disk=1
            di=1
        fi

        if [[ "$version" == *"16"* ]]; then
            remote_cmd "rm -rf /mnt$di/System/Library/Caches/com.apple.dyld"
            remote_cmd "ln -s /System/Cryptexes/OS/System/Library/Caches/com.apple.dyld /mnt$di/System/Library/Caches/"
        fi

        # iOS 16 stuff
        # if [[ "$version" == *"16"* ]]; then
        #     if [ -z "$semi_tethered" ]; then
        #         echo "[*] Performing iOS 16 fixes"
        #         sleep 1
        #         os_disk=$(remote_cmd "/usr/sbin/hdik /mnt6/cryptex1/current/os.dmg | head -3 | tail -1 | sed 's/ .*//'")
        #         sleep 1
        #         app_disk=$(remote_cmd "/usr/sbin/hdik /mnt6/cryptex1/current/app.dmg | head -3 | tail -1 | sed 's/ .*//'")
        #         sleep 1
        #         remote_cmd "/sbin/mount_apfs -o ro $os_disk /mnt2"
        #         sleep 1
        #         remote_cmd "/sbin/mount_apfs -o ro $app_disk /mnt9"
        #         sleep 1

        #         remote_cmd "rm -rf /mnt1/System/Cryptexes/App /mnt1/System/Cryptexes/OS"
        #         sleep 1
        #         remote_cmd "mkdir /mnt1/System/Cryptexes/App /mnt1/System/Cryptexes/OS"
        #         sleep 1
        #         remote_cmd "cp -a /mnt9/. /mnt1/System/Cryptexes/App"
        #         sleep 1
        #         remote_cmd "cp -a /mnt2/. /mnt1/System/Cryptexes/OS"
        #         sleep 1
        #         remote_cmd "rm -rf /mnt1/System/Cryptexes/OS/System/Library/Caches/com.apple.dyld"
        #         sleep 1
        #         remote_cmd "cp -a /mnt2/System/Library/Caches/com.apple.dyld /mnt1/System/Library/Caches/"
        #     fi
        # fi

        echo "[*] Копирование файлов в rootfs"
        remote_cmd "rm -rf /mnt$di/jbin /mnt$di/.installed_palera1n"
        sleep 1
        remote_cmd "mkdir -p /mnt$di/jbin/binpack /mnt$di/jbin/loader.app"
        sleep 1

        # Checking network connection before downloads
        _check_network_connection

        # download loader
        cd other/rootfs/jbin
        rm -rf loader.app
        echo "[*] Загрузка загрузчика"
        curl -LO https://static.palera.in/artifacts/loader/rootful/palera1n.ipa
        unzip palera1n.ipa -d .
        mv Payload/palera1nLoader.app loader.app
        rm -rf palera1n.zip loader.zip palera1n.ipa Payload
        
        # download jbinit files
        rm -f jb.dylib jbinit jbloader launchd
        echo "[*] Загрузка файлов jbinit"
        curl -L https://static.palera.in/deps/rootfs.zip -o rfs.zip
        unzip rfs.zip -d .
        unzip rootfs.zip -d .
        rm rfs.zip rootfs.zip
        cd ../../..

        # download binpack
        mkdir -p other/rootfs/jbin/binpack
        echo "[*] Загрузка binpack"
        curl -L https://static.palera.in/binpack.tar -o other/rootfs/jbin/binpack/binpack.tar

        sleep 1
        remote_cp -r other/rootfs/* root@localhost:/mnt$di
        {
            echo "{"
            echo "    \"version\": \"${version} (${commit}_${branch})\","
            echo "    \"args\": \"$@\","
            echo "    \"pc\": \"$(uname) $(uname -r)\""
            echo "}"
        } > work/.installed_palera1n
        sleep 1
        remote_cp work/.installed_palera1n root@localhost:/mnt$di

        remote_cmd "ldid -s /mnt$di/jbin/launchd /mnt$di/jbin/jbloader /mnt$di/jbin/jb.dylib"
        remote_cmd "chmod +rwx /mnt$di/jbin/launchd /mnt$di/jbin/jbloader /mnt$di/jbin/post.sh"
        remote_cmd "tar -xvf /mnt$di/jbin/binpack/binpack.tar -C /mnt$di/jbin/binpack/"
        sleep 1
        remote_cmd "rm /mnt$di/jbin/binpack/binpack.tar"
    fi

    rm -rf work BuildManifest.plist
    mkdir work
    rm .rd_in_progress

    sleep 2
    echo "[*] Фаза 1 завершена! Перезагрузка вашего устройства (если оно не перезагружается, вы можете принудительно перезагрузить)"
    remote_cmd "/sbin/reboot"
    sleep 1
    _kill_if_running iproxy

    if [ "$semi_tethered" = "1" ]; then
        _wait normal
        sleep 5

        echo "[*] Переключение устройства в режим восстановления..."
        "$dir"/ideviceenterrecovery $(_info normal UniqueDeviceID)
    elif [ -z "$tweaks" ]; then
        _wait normal
        sleep 5

        echo "[*] Переключение устройства в режим восстановления..."
        "$dir"/ideviceenterrecovery $(_info normal UniqueDeviceID)
    fi
    _wait recovery
    _dfuhelper "$cpid" || {
        echo "[-] Не удалось войти в режим DFU, повторите попытку."
        sleep 3
        _wait_for_device
    }
    sleep 2
fi

# ============
# Boot create
# ============

# Actually create the boot files
disk=$(cat .fs-"$deviceid")
if [[ "$version" == *"16"* ]]; then
    fs=disk1s$disk
else
    fs=disk0s1s$disk
fi

boot_args=""
if [ "$serial" = "1" ]; then
    boot_args="serial=3"
else
    boot_args="-v"
fi

if [[ "$deviceid" == iPhone9,[1-4] ]] || [[ "$deviceid" == "iPhone10,"* ]]; then
    if [ ! -f boot-"$deviceid"/.payload ]; then
        rm -rf boot-"$deviceid"
    fi
else
    if [ ! -f boot-"$deviceid"/.local ]; then
        rm -rf boot-"$deviceid"
    fi
fi

if [ ! -f boot-"$deviceid"/ibot.img4 ]; then
    # Downloading files, and decrypting iBSS/iBEC
    rm -rf boot-"$deviceid"
    mkdir boot-"$deviceid"

    #echo "[*] Converting blob"
    #"$dir"/img4tool -e -s $(pwd)/blobs/"$deviceid"-"$version".shsh2 -m work/IM4M
    cd work

    # Checking network connection before downloads
    _check_network_connection

    # Do payload if on iPhone 7-X
    if [[ "$deviceid" == iPhone9,[1-4] ]] || [[ "$deviceid" == "iPhone10,"* ]]; then
        if [[ "$version" == "16.0"* ]] || [[ "$version" == "15"* ]]; then
            newipswurl="$ipswurl"
        else
            buildid=$(curl -sL https://api.ipsw.me/v4/ipsw/16.0.3 | "$dir"/jq '[.[] | select(.identifier | startswith("'iPhone'")) | .buildid][0]' --raw-output)
            newipswurl=$(curl -sL https://api.appledb.dev/ios/iOS\;$buildid.json | "$dir"/jq -r .devices\[\"$deviceid\"\].ipsw)
        fi

        echo "[*] Скачивание BuildManifest"
        "$dir"/pzb -g BuildManifest.plist "$newipswurl"

        echo "[*] Загрузка и расшифровка iBoot"
        "$dir"/pzb -g "$(awk "/""$model""/{x=1}x&&/iBoot[.]/{print;exit}" BuildManifest.plist | grep '<string>' | cut -d\> -f2 | cut -d\< -f1)" "$newipswurl"
        "$dir"/gaster decrypt "$(awk "/""$model""/{x=1}x&&/iBoot[.]/{print;exit}" BuildManifest.plist | grep '<string>' | cut -d\> -f2 | cut -d\< -f1 | sed 's/Firmware[/]all_flash[/]//')" ibot.dec

        echo "[*] Исправление и подпись iBoot"
        "$dir"/iBoot64Patcher ibot.dec ibot.patched

        if [[ "$deviceid" == iPhone9,[1-4] ]]; then
            "$dir"/iBootpatch2 --t8010 ibot.patched ibot.patched2
        else
            "$dir"/iBootpatch2 --t8015 ibot.patched ibot.patched2
        fi

        if [ "$os" = 'Linux' ]; then
            sed -i 's/\/\kernelcache/\/\kernelcachd/g' ibot.patched2
        else
            LC_ALL=C sed -i.bak -e 's/s\/\kernelcache/s\/\kernelcachd/g' ibot.patched2
            rm *.bak
        fi

        cd ..
        "$dir"/img4 -i work/ibot.patched2 -o boot-"$deviceid"/ibot.img4 -M blobs/"$deviceid"-"$version".der -A -T ibss

        touch boot-"$deviceid"/.payload
    else
        echo "[*] Скачивание BuildManifest"
        "$dir"/pzb -g BuildManifest.plist "$ipswurl"

        echo "[*] Загрузка и расшифровка iBSS"
        "$dir"/pzb -g "$(awk "/""$model""/{x=1}x&&/iBSS[.]/{print;exit}" BuildManifest.plist | grep '<string>' | cut -d\> -f2 | cut -d\< -f1)" "$ipswurl"
        "$dir"/gaster decrypt "$(awk "/""$model""/{x=1}x&&/iBSS[.]/{print;exit}" BuildManifest.plist | grep '<string>' | cut -d\> -f2 | cut -d\< -f1 | sed 's/Firmware[/]dfu[/]//')" iBSS.dec
        
        echo "[*] Загрузка и расшифровка iBoot"
        "$dir"/pzb -g "$(awk "/""$model""/{x=1}x&&/iBoot[.]/{print;exit}" BuildManifest.plist | grep '<string>' | cut -d\> -f2 | cut -d\< -f1)" "$ipswurl"
        "$dir"/gaster decrypt "$(awk "/""$model""/{x=1}x&&/iBoot[.]/{print;exit}" BuildManifest.plist | grep '<string>' | cut -d\> -f2 | cut -d\< -f1 | sed 's/Firmware[/]all_flash[/]//')" ibot.dec

        echo "[*] Исправление и подпись iBSS/iBoot"
        "$dir"/iBoot64Patcher iBSS.dec iBSS.patched
        if [ "$semi_tethered" = "1" ]; then
            if [ "$serial" = "1" ]; then
                "$dir"/iBoot64Patcher ibot.dec ibot.patched -b "serial=3 rd=$fs" -l
            else
                "$dir"/iBoot64Patcher ibot.dec ibot.patched -b "-v rd=$fs" -l
            fi
        else
            if [ "$serial" = "1" ]; then
                "$dir"/iBoot64Patcher ibot.dec ibot.patched -b "serial=3" -f
            else
                "$dir"/iBoot64Patcher ibot.dec ibot.patched -b "-v" -f
            fi
        fi

        if [ "$os" = 'Linux' ]; then
            sed -i 's/\/\kernelcache/\/\kernelcachd/g' ibot.patched
        else
            LC_ALL=C sed -i.bak -e 's/s\/\kernelcache/s\/\kernelcachd/g' ibot.patched
            rm *.bak
        fi
        cd ..
        "$dir"/img4 -i work/iBSS.patched -o boot-"$deviceid"/iBSS.img4 -M blobs/"$deviceid"-"$version".der -A -T ibss
        "$dir"/img4 -i work/ibot.patched -o boot-"$deviceid"/ibot.img4 -M blobs/"$deviceid"-"$version".der -A -T `if [[ "$cpid" == *"0x801"* ]]; then echo "ibss"; else echo "ibec"; fi`

        touch boot-"$deviceid"/.local
    fi
fi

# ============
# Boot device
# ============

sleep 2
_pwn
_reset
echo "[*] Загрузка устройства"
if [[ "$deviceid" == iPhone9,[1-4] ]] || [[ "$deviceid" == "iPhone10,"* ]]; then
    sleep 1
    "$dir"/irecovery -f boot-"$deviceid"/ibot.img4
    sleep 3
    "$dir"/irecovery -c "dorwx"
    sleep 2
    if [[ "$deviceid" == iPhone9,[1-4] ]]; then
        "$dir"/irecovery -f other/payload/payload_t8010.bin
    else
        "$dir"/irecovery -f other/payload/payload_t8015.bin
    fi
    sleep 3
    "$dir"/irecovery -c "go"
    sleep 1
    "$dir"/irecovery -c "go xargs $boot_args"
    sleep 1
    "$dir"/irecovery -c "go xfb"
    sleep 1
    "$dir"/irecovery -c "go boot $fs"
else
    if [[ "$cpid" == *"0x801"* ]]; then
        sleep 1
        "$dir"/irecovery -f boot-"$deviceid"/ibot.img4
    else
        sleep 1
        "$dir"/irecovery -f boot-"$deviceid"/iBSS.img4
        sleep 4
        "$dir"/irecovery -f boot-"$deviceid"/ibot.img4
    fi

    if [ -z "$semi_tethered" ]; then
       sleep 2
       "$dir"/irecovery -c fsboot
    fi
fi

if [ -d "logs" ]; then
    cd logs
     mv "$log" SUCCESS_${log}
    cd ..
fi

rm -rf work rdwork
echo ""
echo "Готово!"
echo "Теперь устройство должно загрузиться на iOS"
echo "Когда вы разблокируете устройство, оно перезапустится примерно через 30 секунд"
echo "Если вы загрузили джейлбрейк впервые, откройте новое приложение palera1n и нажмите «Установить»"
echo "В противном случае нажмите «Do All» в разделе настроек приложения"
echo "Если у вас есть какие-либо проблемы, сначала проверьте документ common-issues.md на наличие распространенных проблем"
if [ "$china" != "1" ]; then
	echo "Если этот список не решает вашу проблему, присоединяйтесь к серверу Discord и попросите помощи: https://dsc.gg/palera1n"
fi
echo "Наслаждайтесь!"

} 2>&1 | tee logs/${log}

popd &> /dev/null
