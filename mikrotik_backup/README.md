
# Автоматическое резервное копирование конфигурации оборудования MikroTik  

Скрипт `mikrotik_backup.sh` выполняет резервное копирование конфигурации оборудования MikroTik в текстовом и бинарном форматах. Резервные копии в текстовом формате записываются в локальный Git-репозиторий. Резервные копии в бинарном формате записываются в отдельные директории для каждого устройства, их ротация происходит автоматически. После завершения процедуры резервного копирования скрипт автоматически отправляет отчёт об успешном завершении или ошибках, произошедших в процессе выполнения, на электронную почту. Работоспособность скрипта проверялась для MikroTik RouterOS v7.

В скрипте используются следующие переменные:

- `CONF_FILE` - путь к файлу `mikrotik_dev_list.conf`, содержащего IP-адреса устройств и последовательность Port Knocking. [Структура конфигурационного файла `mikrotik_dev_list.conf`](#структура-конфигурационного-файла-mikrotik_dev_listconf)
- `RSC_BKUP_DIR` - директория для хранения резервных копий в текстовом формате.
- `BINARY_BKUP_DIR` - директория для хранения резервных копий в бинарном формате.
- `BACKUP_USER` - имя пользователя на оборудовании MikroTik.
- `EMAIL_TO` - адрес электронной почты для отправки отчёта.
- `KEEP_DAYS` - указывается период ротации файлов конфигурации в бинарном формате в днях.

<details><summary>Дополнительные технические детали реализации скрипта</summary>

По умолчанию `ssh` считывает данные из стандартного потока ввода (`stdin`). Поскольку цикл `while` перенаправляет файл конфигурации `$CONF_FILE` в stdin всего цикла, первая же вызванная команда `ssh` (или `scp`) забирает из этого потока все оставшиеся строки, пытаясь выполнить их как команды на оборудовании MikroTik. Когда управление возвращается к циклу `while`, поток `stdin` уже пуст и цикл завершается на первом же элементе. Использование выделенного файлового дескриптора `3` гарантирует, что никакие внутренние консольные команды никогда случайно не очистят строки из прочитанного конфигурационного файла.
<pre><code>...
while IFS=';' read <b>-u 3</b> -r ip ssh_port p1_proto p1_port p2_proto p2_port p3_proto p3_port || [[ -n "${ip:-}" ]]; do  
...  

...  
done <b>3</b>&lt; "$CONF_FILE"  
...</code></pre>
</details>

## Настройка сервера резервного копирования

Установка обновлений операционной системы

```bash
sudo apt update && sudo apt upgrade
```

Установка необходимых пакетов для работы скрипта резервного копирования

```bash
sudo apt install git netcat-openbsd msmtp msmtp-mta ca-certificates
```

Создание системного пользователя без возможности интерактивного входа

```bash
sudo useradd -r -m -s /usr/sbin/nologin <ИМЯ_СИСТЕМНОГО_ПОЛЬЗОВАТЕЛЯ>
```

Создание директорий для хранения резервных копий и настройка прав доступа к ним, например, в `/var/backups`

```bash
sudo mkdir -p /var/backups/mikrotik/{rsc,binary}
sudo chown -R <ИМЯ_СИСТЕМНОГО_ПОЛЬЗОВАТЕЛЯ>:<ГРУППА_СИСТЕМНОГО_ПОЛЬЗОВАТЕЛЯ> /var/backups/mikrotik
sudo chmod -R 700 /var/backups/mikrotik
```

Генерация SSH-ключа от имени системного пользователя

```bash
sudo -u <ИМЯ_СИСТЕМНОГО_ПОЛЬЗОВАТЕЛЯ> ssh-keygen -t ed25519
```

Копирование публичного ключа (файл с расширением `.pub`) на маршрутизатор MikroTik

```bash
sudo scp /home/<ИМЯ_СИСТЕМНОГО_ПОЛЬЗОВАТЕЛЯ>/.ssh/id_ed25519.pub admin@<IP_АДРЕС_МАРШРУТИЗАТОРА>:/
```

### Создание systemd-юнитов

Сервис:

```bash
sudo vi /etc/systemd/system/mikrotik_backup.service
```

```text
[Unit]
Description=Script for MikroTik backup and email notification
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=<ИМЯ_СИСТЕМНОГО_ПОЛЬЗОВАТЕЛЯ>
Group=<ГРУППА_СИСТЕМНОГО_ПОЛЬЗОВАТЕЛЯ>
ExecStart=/ПУТЬ/mikrotik_backup.sh

[Install]
WantedBy=multi-user.target
```

Таймер:

```bash
sudo vi /etc/systemd/system/mikrotik_backup.timer
```

```text
[Unit]
Description=Timer for MikroTik backup script

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

Изменение группы и прав доступа конфигурационных файлов

```bash
sudo chown root:<ГРУППА_СИСТЕМНОГО_ПОЛЬЗОВАТЕЛЯ> /etc/msmtprc /ПУТЬ/mikrotik_dev_list.conf
sudo chmod 640 /etc/msmtprc /ПУТЬ/mikrotik_dev_list.conf
```

### Активация и проверка

Перезагрузка демона systemd для того, чтобы менеджер systemd перечитал изменённые или новые unit-файлы

```bash
sudo systemctl daemon-reload
```

Включение и запуск таймера

```bash
sudo systemctl enable --now mikrotik_backup.timer
```

Проверка состояния таймера и времени следующего запуска

```bash
systemctl status mikrotik_backup.timer
```

Запуск сервиса вручную для проверки всех настроек

```bash
sudo systemctl start mikrotik_backup.service
```

Просмотр файлов регистрации

```bash
journalctl -u mikrotik_backup.service
```

Проверка подключения вручную с сервера резервного копирования на оборудование MikroTik (после настройки на обеих сторонах)

```bash
sudo -u <ИМЯ_СИСТЕМНОГО_ПОЛЬЗОВАТЕЛЯ> ssh -i /home/<ИМЯ_СИСТЕМНОГО_ПОЛЬЗОВАТЕЛЯ>/.ssh/id_ed25519 <ИМЯ_ПОЛЬЗОВАТЕЛЯ>@<IP_АДРЕС_МАРШРУТИЗАТОРА>
```

Просмотр истории коммитов

```bash
sudo -u <ИМЯ_СИСТЕМНОГО_ПОЛЬЗОВАТЕЛЯ> git -C <ПУТЬ_К_РЕПОЗИТОРИЮ> log
```

### Структура конфигурационного файла `mikrotik_dev_list.conf`

Для разделения значений в файле используется символ `;`. Каждая строка файла содержит параметры подключения к маршрутизатору и последовательность Port Knocking.

**Порядок полей в строке:**

1. `mikrotik_ip` - IP-адрес устройства MikroTik.
2. `ssh_port` - Целевой порт службы SSH на MikroTik.
3. `proto_1` - Протокол для первого шага Port Knocking (TCP или UDP).
4. `port_1` - Сетевой порт для первого шага Port Knocking.
5. `proto_2` - Протокол для второго шага Port Knocking.
6. `port_2` - Сетевой порт для второго шага Port Knocking.
7. `proto_3` - Протокол для третьего шага Port Knocking.
8. `port_3` - Сетевой порт для третьего шага Port Knocking.

**Пример корректной строки:**  

```text
198.51.100.1;22;TCP;10001;UDP;20002;TCP;30003
```

## Настройка оборудования MikroTik

### Настройка прав доступа на MikroTik (Безопасность)

> [!WARNING]
> Для работы скрипта **категорически не рекомендуется** использовать учетную запись `admin` или группу `full`. В целях безопасности на каждом маршрутизаторе необходимо создать изолированную группу пользователей с минимально достаточными правами.

Скрипт выполняет два типа резервного копирования, поэтому группе требуются строго определенные политики (Policies):

- Для экспорта конфигурации в текстовом формате (`/export`) требуются: `ssh`, `read`, `sensitive` (чтобы выгружались пароли и ключи).
- Для скачивания файла конфигурации в бинарном формате (`.backup`) по протоколу SCP/SFTP требуется: `ftp`.
- Политика `write` **должна быть отключена** - это гарантирует, что даже при компрометации сервера резервного копирования злоумышленник не сможет изменить конфигурацию оборудования MikroTik.

**1. Создание безопасной группы**

```routeros
/user group
add name=<НАЗВАНИЕ_ГРУППЫ> policy=ssh,read,ftp,sensitive,!local,!write,!telnet,!reboot,!policy,!test,!winbox,!password,!web,!sniff,!api,!romon,!rest-api
```

**2. Создание пользователя и привязка SSH-ключа**

2.1. Создание пользователя и привязка его к новой группе

```routeros
/user add name=<ИМЯ_ПОЛЬЗОВАТЕЛЯ> group=<НАЗВАНИЕ_ГРУППЫ> password=<НАДЁЖНЫЙ_ПАРОЛЬ> comment="User for automated backups"
```

2.2. Привязка SSH-ключа к созданному пользователю

```routeros
/user ssh-keys import user=<ИМЯ_ПОЛЬЗОВАТЕЛЯ> public-key-file=id_ed25519.pub
```

**3. Пример настройки правил межсетевого экрана MikroTik для реализации Port knocking**

```routeros
/ip firewall filter
add action=accept chain=input comment="INPUT Accept established,related" connection-state=established,related
add action=drop chain=input comment="INPUT Drop invalid" connection-state=invalid
...
add action=add-src-to-address-list address-list=Knock_1 address-list-timeout=1m chain=input comment="INPUT Port Knocking: Step 1" dst-port=1001 protocol=tcp
add action=add-src-to-address-list address-list=Knock_2 address-list-timeout=1m chain=input comment="INPUT Port Knocking: Step 2" dst-port=2002 protocol=udp src-address-list=Knock_1
add action=add-src-to-address-list address-list=SSH_Allowed address-list-timeout=15m chain=input comment="INPUT Port Knocking: Step 3 - Open SSH" dst-port=3003 protocol=tcp src-address-list=Knock_2
add action=accept chain=input comment="INPUT Accept SSH for Knocked Users" dst-port=22 protocol=tcp src-address-list=SSH_Allowed
...
add action=drop chain=input comment="INPUT Drop everything else"
...
```

### Автоматизация создания бинарного файла резервной копии конфигурации (System Scheduler)

Так как у созданной группы отключены права на запись (`!write`) и управление системой (`!policy`), пользователь не может самостоятельно выполнить команду `/system/backup/save`. Чтобы бинарный файл создавался, на самом оборудовании MikroTik настраивается планировщик, который будет, например, раз в сутки создавать новый файл под фиксированным именем. Старый файл будет автоматически перезаписываться, не переполняя память устройства.

> [!TIP]
>Убедитесь, что время запуска процесса создания бинарного файла резервной копии на MikroTik опережает запуск systemd-таймера на сервере резервного копирования.

```routeros
/system scheduler
add name="auto_make_binary_backup" interval=1d start-time=02:00:00 on-event="/system/backup/save name=binary_backup password=<НАДЁЖНЫЙ_ПАРОЛЬ> encryption=aes-sha256"
```

Проект лицензирован под GNU General Public License v3.0. Подробности — в файле `LICENSE`.
