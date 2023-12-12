# Запускаем Matlab® внутри Docker-контейнера с поддержкой GUI в ОС GNU/Linux. #

## Введение ##
<anchor>intro</anchor>

Возникла задача запускать графические приложения в полностью изолированной среде: как от Интернета, так и от файловой системы «хозяйской» ОС. В моём случае это был Matlab. Пишут, что в последних версиях он стал шибко «умным»: сам без спроса постоянно лезет в сеть и чем-то там постоянно обменивается со своими серверами. Однако использовать для поставленной задачи виртуальную гостевую машину / аппаратную виртуализацию (наподобие VirtualBox) — это, ИМХО, «too much». Docker подошел бы гораздо лучше, т.к. он использует то же ядро ОС и не требует эмуляции / виртуализации ввода-вывода, что существенно экономит ресурсы. Однако Docker «из коробки» не предназначен для запуска GUI-приложений. Что ж, попробуем это исправить и запустить таки Matlab внутри Docker-контейнера с полной поддержкой «иксов» и GUI.  

*Предупреждение:* далее речь пойдёт только об ОС GNU/Linux. В моём случае это - Ubuntu 20.04 LTS (Focal Fossa) на архитектуре x86_64 (версия ядра: 5.15.0-88-generic) со средой рабочего стола MATE (версии 1.24.0) и оконной системой X  Window System xorg (реализация X11R7.7, xserver-xorg version: 1:7.7+19ubuntu14, xserver-xorg-core version: 2:1.20.13-1ubuntu1~20.04.9).  

Итак, хорошо известно нижеследующее. С одной стороны, Docker прекрасно поддерживает TCP/IP-сети; Docker-контейнеры могут подключаться как полностью изолированным виртуальным Docker-сетям, так и к сетям с выходам во «внешку» (относительно «хозяйской» ОС (host Operating System, т.е. основной Операционной Системы, нативно установленной на компьютер)) — «локалку» и/или Интернет. 
С другой стороны мы помним, что «иксы» (X Window System) — это сервер. Сервер, который предоставляет своим клиентам доступ к обобщенному абстрактному X-дисплею, который представляет собой графическую систему ввода-вывода, включающую, как правило, клавиатуру, мышь и монитор (но не ограничиваясь этим, конечно же). Клиентами этого сервера являются GUI-приложения. Для их авторизации на этом сервере используется куки-файл, который чаще всего хранится в файле `~/.Xauthority`. Адрес X-дисплея, к которому следует подключаться, хранится в переменной окружения `DISPLAY`. В X Window System предусмотрена сетевая прозрачность: графические приложения могут выполняться на другой машине в сети, а их интерфейс при этом будет передаваться по сети и отображаться на локальной машине пользователя. Иными словами, xorg (а именно он будет здесь рассмотрен) поддерживает взаимодействие со своими клиентами через TCP/IP, хотя по умолчанию локальные GUI-приложения взаимодействуют с локальным X-сервером через unix-socket. Из соображений безопасности в большинстве «настольных» дистрибутивов GNU/Linux поддержка TCP/IP X-сервером отключена — и далее будет понятно почему — но только на уровне конфигов, что означает, что её можно легко включить обратно.  

Таким образом, если мы хотим использовать Docker-контейнеры для изоляции GUI-приложений от Интернета и файловой системы основной ОС, нам необходимо:

1.  Создать изолированную (в терминологии Docker — "internal", т.е. «внутреннюю») виртуальную Docker-сеть, т.е. сеть без маршрутизации пакетов во вне: Интернет и «локалку». В эту сеть войдут «хозяйская» машина, на которой исполняется xorg, и Docker-контейнер, где будут запускаться GUI-приложения — клиенты «хозяйского» xorg.
2.  Разрешить подключение к «хозяйскому» xorg по TCP/IP — но только из Docker-сети.
3.  Подготовить Docker-образ со всеми установленными библиотеками для работы с GUI.
4.  Правильно выставить переменную окружения DISPLAY внутри Docker-контейнера (она должна включать IP-адрес хоста).
5.  Так или иначе разрешить GUI-приложениям из Docker-контейнера авторизоваться на «хозяйском» X-сервере (т.е. на X-сервере «хозяйской» ОС).
6.  Подключить контейнер к «изолированной» Docker-сети, отключить от Docker-сети по-умолчанию (сеть `bridge`, которой соответствует виртуальный адаптер `docker0` на стороне «хозяйской» ОС, и которая не является «изолированной»); при этом сохранить возможность подключаться на время к этой не-«изолированной» сети, чтобы иметь возможность устанавливать софт и обновления.
7.  Установить внутри контейнера необходимый нам софт со всеми зависимостями.

----------------------------------------------------------------------------------

## Предварительные сведения ##
<anchor>theory</anchor>

### Немного «теории» о том, как работают «иксы» ###
<anchor>x-theory</anchor>

Для начала рассмотрим некоторые общие принципы работы X-сервера. В этом разделе мы будем исходить из того, что у нас xorg, и что поддержка TCP/IP в настройках X-сервера уже *ВКЛЮЧЕНА*.  

Введем некоторую терминологию. Графическим сеансом будем называть сеанс пользователя, который залогинился в системе посредством Display Manager'а. Самого такого пользователя будем называть пользователем графического сеанса, для простоты — «графическим пользователем». Активным графическим сеансом будем называть тот графический сеанс, который в данный момент взаимодействует с обобщенным X-дисплеем, т.е. окна которого в настоящий момент отображаются на мониторе и взаимодействуют с устройствами ввода (клавиатурой, мышью и т.п.). Соответственно пользователя такого сеанса назовём «активным графическим пользователем».  

Итак, что происходит, когда посредством Display Manager'а логинится самый первый пользователь (пусть это будет `user-1`)? Взглянем на приведенный ниже листинг:
```bash
$ pgrep X | xargs ps -lfwwwp
F S UID          PID    PPID  C PRI  NI ADDR SZ WCHAN  STIME TTY        TIME CMD
4 S root        1479    1464  0  80   0 - 308106 -     фев21 tty7   10:00 /usr/lib/xorg/Xorg -listen inet -listen unix :0 -seat seat0 -auth /var/run/lightdm/root/:0 -listen tcp vt7 -novtswitch
```

Мы видим, что Display Manager (в моем случае LightDM) породил экземпляр процесса Xorg. Для ввода-вывода ему был назначен 7-й виртуальный терминал — `tty7` (на него мы можем попасть, нажав `Ctrl + Alt + F7`, если до этого покинули его перейдя на другой tty). Его номер значится в поле `TTY`, а также в опции `-listen tcp vt7`. `-listen unix :0` — это упрощенный адрес локального юникс-сокета, он же содержится в переменной окружения `DISPLAY` этого пользователя:
```bash
$ echo $DISPLAY
:0
```

Полный адрес у него такой: `/tmp/.X11-unix/X0`
```bash
$ stat /tmp/.X11-unix/X0 
  Файл: /tmp/.X11-unix/X0
  Размер: 0             Блоков: 0          Блок В/В: 4096   сокет
Устройство: 10302h/66306d       Инода: 3021621     Ссылки: 1
Доступ: (0777/srwxrwxrwx)  Uid: (    0/    root)   Gid: (    0/    root)
... ... ...
```
Этому юникс-сокету соответствует открытый на прослушку TCP порт 6000 (если xorg'у была передана опция `-listen inet`).  

Далее, рассмотрим опцию `-auth /var/run/lightdm/root/:0` Она указывает на файл:
```bash
$ sudo stat /var/run/lightdm/root/:0
  Файл: /var/run/lightdm/root/:0
  Размер: 61            Блоков: 8          Блок В/В: 4096   обычный файл
Устройство: 19h/25d     Инода: 1694        Ссылки: 1
Доступ: (0600/-rw-------)  Uid: (    0/    root)   Gid: (    0/    root)
... ... ...
```
Это — обычный файл, доступ к которому имеет только root (Процесс Xorg выполняется от имени root'а!). При инициализации процесса `Xorg` Display Manager'ом генерируется уникальная (псевдо-)случайная последовательность 16-ричных цифр, называемая `MIT-MAGIC-COOKIE-1`. Копия этой же самой `MIT-MAGIC-COOKIE-1` выдается «графическому пользователю»: она помещается в его файл `~/.Xauthority`. Если `MIT-MAGIC-COOKIE-1` из `~/.Xauthority` и файла, на который указывает опция `-auth` процесса `Xorg`, совпадают — то авторизация x-клиента на x-сервере считается успешной, и установка соединения позволяется. Убедимся, что в нашем случае это так, и содержимое этих файлов идентичное. (Сами по себе эти файлы бинарные, в чём можно убедиться, посмотрев вывод `cat ~/.Xauthority`, но просмотреть их содержимое в текстовом виде можно командой `xauth list`.)
```bash
user-1@ThinkPad:~$ xauth -v
Using authority file /home/user-1/.Xauthority  # указывает, какой файл будет использован, если не передана опция -f </path/to/file>

user-1@ThinkPad:~$ xauth list
ThinkPad/unix:0  MIT-MAGIC-COOKIE-1  e996a1ef44c240520b877abfc7adadd9

user-1@ThinkPad:~$ sudo xauth -f /var/run/lightdm/root/:0 list
ThinkPad/unix:0  MIT-MAGIC-COOKIE-1  e996a1ef44c240520b877abfc7adadd9
```

*Замечание:*
Пользовательский `~/.Xauthority` может содержать более одной `MIT-MAGIC-COOKIE-1`. Например, так:
```bash
user-1@ThinkPad:~$ xauth 
Using authority file /home/user-1/.Xauthority
xauth> list
ThinkPad/unix:0  MIT-MAGIC-COOKIE-1  e996a1ef44c240520b877abfc7adadd9
ThinkPad/unix:5  MIT-MAGIC-COOKIE-1  da5cf526102461bda51754df47dc3005
xauth> quit
```
Т.е. предусмотрена возможность быть одновременно авторизованным на нескольких x-серверах. В этом случае переменная окружения `DISPLAY` определяет к какому именно x-серверу будет произведено подключение. Кроме того, файл `~/.Xauthority` (частично) персистирует между перезагрузками ОС. `MIT-MAGIC-COOKIE-1` перезаписывается только явно и только по указанному номеру юникс-сокета (очевидно, перезапись инициализируется Display Manager'ом при очередном логине пользователя в систему), остальные `MIT-MAGIC-COOKIE-1` остаются на месте в неизменном виде между перезагрузками.  

Итак, первому залогинившемуся «графическому пользователю» назначаются: виртуальный терминал `tty7`, для подключения к x-серверу — юникс-сокет `/tmp/.X11-unix/X0` (которому соответствует `DISPLAY = :0`) и TCP-порт 6000, а для авторизации используется копия `MIT-MAGIC-COOKIE-1` из файла `/var/run/lightdm/root/:0`.  

Посмотрим, что теперь будет, если мы залогинимся вторым (еще одним) «графическим пользователем» через LightDM, НЕ разлогиниваясь при этом первым («Заблокировать экран» → «Переключить пользователя»). Назовём его `user-2`.

```bash
$ pgrep X | xargs ps -lfwwwp
F S UID          PID    PPID  C PRI  NI ADDR SZ WCHAN  STIME TTY        TIME CMD
4 S root        1479    1464  0  80   0 - 308106 -     фев21 tty7   10:00 /usr/lib/xorg/Xorg -listen inet -listen unix :0 -seat seat0 -auth /var/run/lightdm/root/:0 -listen tcp vt7 -novtswitch
4 S root       14156    1464  0  80   0 - 193093 -     фев21 tty8    0:44 /usr/lib/xorg/Xorg -listen inet -listen unix :1 -seat seat0 -auth /var/run/lightdm/root/:1 -listen tcp vt8 -novtswitch
```

Как видно, для `user-2` был порожден еще один экземпляр процесса `Xorg`, которому был назначен отдельный юникс-сокет — `:1` (был создан специальный сокет-файл `/tmp/.X11-unix/X1`), а вместе с ним открыт еще один TCP-порт: 6001 — для подключения по сети именно к x-дисплею «графического пользователя» `user-2`. Переменная окружения `DISPLAY` у `user-2` также имеет значение `:1`. Также для `user-2` была сгенерирована своя уникальная `MIT-MAGIC-COOKIE-1`, серверная версия которой была помещена в файл `/var/run/lightdm/root/:1`.
Также видим, что под «Рабочий стол» для `user-2` был назначен 8-й виртуальный терминал — `tty8`, при этом `tty7` остался закреплённым за `user-1`. Т.е. «Рабочие столы» двух «графических пользователей» запущены на двух разных виртуальных терминалах. И действительно, находясь внутри графического сеанса пользователя `user-1`, нажимаем `Ctrl + Alt + F8` и видим GUI-экран приветствия входа в систему как `user-2`. После этого нажимаем `Ctrl + Alt + F7` — и мы снова оказываемся внутри графического сеанса пользователя `user-1`.  

`MIT-MAGIC-COOKIE-1` и значения переменной окружения `DISPLAY` у `user-2` и `user-1` разные:
```bash
# User #2
user-2@ThinkPad:~$ xauth list
ThinkPad/unix:1  MIT-MAGIC-COOKIE-1  6f4197b3a0b21a0dde474035ee877b9b
user-2@ThinkPad:~$ echo $DISPLAY
:1
------------------------------------
# User #1
user-1@ThinkPad:~$ xauth list
ThinkPad/unix:0  MIT-MAGIC-COOKIE-1  e996a1ef44c240520b877abfc7adadd9
user-1@ThinkPad:~$ echo $DISPLAY
:0
```

Вывод `nmap -p6001 127.0.0.1` после того, как залогинился `user-2` показывает, что этот порт открылся:
```bash
$ sudo nmap -p6001 127.0.0.1
... ... ...
PORT     STATE  SERVICE
6001/tcp closed X11:1    # <--------- ДО

$ sudo nmap -p6001 127.0.0.1
... ... ...
PORT     STATE SERVICE
6001/tcp open  X11    # <--------- ПОСЛЕ
```

Листинг с открытым для `user-2` юникс-сокетом:
```bash
$ sudo ls -la /tmp/.X11-unix/
drwxrwxrwt  2 root root 4096 фев 21 23:50 .
drwxrwxrwt 24 root root 4096 мар 22 20:47 ..
srwxrwxrwx  1 root root    0 фев 21 01:05 X0  # <-- user-1, ср. с /var/run/lightdm/root/:0 , DISPLAY=:0 , TCP port 6000
srwxrwxrwx  1 root root    0 фев 21 22:15 X1  # <-- user-2, ср. с /var/run/lightdm/root/:1 , DISPLAY=:1 , TCP port 6001

$ stat /tmp/.X11-unix/X1
  Файл: /tmp/.X11-unix/X1
  Размер: 0             Блоков: 0          Блок В/В: 4096   сокет
Устройство: 10302h/66306d       Инода: 3021855     Ссылки: 1
Доступ: (0777/srwxrwxrwx)  Uid: (    0/    root)   Gid: (    0/    root)
... ... ...
```

Важно отметить о взаимно однозначном соответствии и адресе юникс-сокета и номере TCP-порта. Сокету `:0` соответствует порт 6000, сокету `:1` — порт 6001 и т.д. Переменная окружения `DISPLAY` устроена следующим образом. Ее значение `DISPLAY=:0` указывает на локальный юникс-сокет, значение же `DISPLAY=10.255.25.1:0` указывает на TCP-порт 6000 на хосте с IP-адресом 10.255.25.1. Как видим, в случае с сетевым подключением номер порта не указывается — он разрешается автоматически исходя из адреса сокета `:0`.  

Итак, общая схема назначения графических окружений пользователям выглядит так. Каждый раз, когда очередной «графический пользователь» логинится в ОС через Display Manager, 
*   для него порождается новый экземпляр процесса `Xorg`, 
*   которому под «Рабочий стол» назначается отдельный виртуальный терминал начиная с `tty7`; 
*   создается отдельный юникс-сокет (краткий адрес которого помещается в переменную окружения `DISPLAY` этого нового пользователя) начиная с `:0` и открывается соответствующий TCP-порт начиная с 6000; 
*   для авторизации генерируется уникальная `MIT-MAGIC-COOKIE-1`, серверная версия которой помещается в отдельный файл, имя которого соответствует краткому адресу юникс-сокета, созданного для этого пользователя (это — как правило — всё зависит от особенностей Display Manager'а).

С каждым новым залогинившимся «графическим пользователем» «номера» во всех перечисленных параметрах увеличиваются на единицу.  



### О системе безопасности / авторизации пользователей на X-сервере ###
<anchor>x-security-basics</anchor>

Как, наверное, уже стало понятно из сказанного ранее, X-сервер не позволяет кому попало просто так подключаться к абстрактному X-дисплею. Любой, имеющий доступ к X-дисплею, может считывать и изменять картинку на мониторе, перехватывать ввод с клавиатуры и действия мыши. В типичном случае, как это было описано в предыдущем разделе, авторизация клиентов происходит посредством «волшебной» куки — например, `MIT-MAGIC-COOKIE-1` — которая передается X-серверу посредством опции `-auth`. Только клиенты, имеющие у себя «правильную» версию этой куки в своём `~/.Xauthority` файле (либо другом — в том, на который указывает переменная окружения `XAUTHORITY`), могут устанавливать соединения с сервером. 
Однако в том случае, если X-сервер был запущен с поддержкой TCP/IP (опция `-listen inet`), клиент может «расшарить» свой X-дисплей по сети при помощи утилиты `xhost`. Она (`xhost`) позволяет управлять Списком Контроля Доступа (ACL — Access Control List) к X-дисплею уже авторизованного на X-сервере клиента:
```bash
$ xhost +<Host Name or IP address> # для добавления доверенного хоста в ACL
$ xhost -<Host Name or IP address> # для удаления указанного хоста из ACL
```

Хостам, добавленным в этот ACL, для подключения к X-дисплею «волшебная» куки **НЕ ТРЕБУЕТСЯ ВООБЩЕ**: они могут просто подключаться, проводится лишь проверка IP-адреса (Имя хоста преобразуется в IP автоматически при вызове `xhost` во время добавления в ACL.). Единственное ограничение безопасности для `xhost` заключается в том, что с её помощью редактировать ACL может лишь клиент, авторизовавшийся на сервере при помощи «волшебной» куки. Иными словами, удалённые X-клиенты из списка `xhost` сами *НЕ МОГУТ* менять настройки и ACL'ы `xhost`. Можно сказать, что локальный пользователь — владелец куки — это «хозяин», а хосты из ACL'а `xhost` — его «гости». Менять ACL'ы и другие настройки `xhost` может только «хозяин».
Ещё одной особенностью подключения по TCP является то, что удалённый X-клиент может подключиться *ТОЛЬКО* в том случае, если его IP-адрес или имя
хоста есть в списке (ACL'е) `xhost` (или если проверка `xhost` полностью отключена — см. ниже). Если же удалённый клиент не внесён в ACL, подключение будет невозможно, даже при наличии у него «правильной» копии куки (и правильно выставленной переменной окружения `XAUTHORITY`).  

Таким образом, для авторизации на X-сервере применяются два различных механизма, в зависимости от того, является ли пользователь локальным или удалённым:
*   Локальные пользователи подключаются к X-серверу через unix-socket, для авторизации используют «волшебную» куки, могут управлять ACL'ами `xhost`.
*   Удалённые пользователи подключаются к X-серверу через TCP, для авторизации им необходимо и достаточно быть внесёнными в `xhost` ACL, сами управлять настройками `xhost` они не могут.

Ещё при помощи `xhost` можно вообще полностью отключить контроль доступа к своему X-дисплею:
```bash
$ xhost + # полностью отключает контроль доступа
$ xhost - # включает его назад.
```

Если это сделать, то доступ к X-дисплею будет предоставлен вообще всем: как со всех IP-адресов в сети, так и всем локальным пользователям. Так, если обратиться к примеру из [предыдущего раздела](#x-theory), где мы рассматривали двух локальных пользователей, то картина будет такой. Пусть для `user-1` назначен `DISPLAY=:0`, а для `user-2` — `DISPLAY=:1`. Теперь, если `user-2` отключит контроль доступа `xhost`:
```bash
user-2@ThinkPad:~$ xhost +
access control disabled, clients can connect from any host
```
то `user-1` сможет «отправить» ему на Рабочий стол своё окошко, например, так:
```bash
user-1@ThinkPad:~$ DISPLAY=:1 xterm
```
И действительно, жмём `Ctrl + Alt + F8` (для переключения на Рабочий стол пользователя `user-2` — помним, что ему под Рабочий стол отведён `tty8`) — и видим окошко программы xterm, в котором приглашение командной строки выглядит так: `user-1@ThinkPad:~$ `, а в заголовок окна добавлено в конец " (от user-1)".  

Важной особенностью поддержки TCP/IP подключений X-сервером является то, что xorg нельзя заставить слушать только ограниченный набор сетевых интерфейсов из заданного списка. При включенной поддержке TCP/IP xorg начинает слушать сразу все доступные сетевые интерфейсы. Своя же собственная система безопасности TCP-подключений у xorg по современным меркам, мягко говоря, ужасно слаба. Она ограничивается лишь проверкой наличия удаленного хоста в Списке Контроля Доступа (ACL), и то при условии, что контроль доступа не отключен. Очевидно, что и IP-адрес и тем более имя хоста довольно легко подделать в современных условиях, тем более что количество попыток удалённого подключения самим xorg-сервером никак не ограничено. Никакого тебе логина с паролем, ни даже секретного ключа / куки, — да и всё это было бы бесполезно, т.к. сетевой протокол «иксов» не предусматривает никакого шифрования. Поэтому перехватить все эти «секреты» не составило бы большого труда.  

Итак, мы видим, что в связи с включением поддержки TCP/IP «хозяйским» xorg-сервером возникает серьёзная проблема с безопасностью, решить которую можно только «внешними» по отношению к X-серверу средствами. Единственный способ решить эту проблему — использование файервола. Мы будем использовать `iptables`, а подгружать его правила при загрузке «хозяйской» ОС будем при помощи команд в файле `/etc/rc.local`.

----------------------------------------------------------------------------------------------------

## «Практическая часть» ##
<anchor>prac</anchor>

### Создание изолированной Docker-сети ###
<anchor>internal-docker-network</anchor>

Создаем «внутреннюю» виртуальную Docker-сеть. Выбираем для нее такой диапазон IP-адресов: 10.255.25.0/24.
Ключ `--internal` означает, что сеть будет изолированной (от Интернета и «локалки»). Последний аргумент `dcr_itl_25` — это *ИМЯ* сети с точки зрения Docker. 
```bash
$ docker network create --internal --subnet 10.255.25.0/24 dcr_itl_25
aeb9dcd262b96db83953b1665d017c98eaa9dabb7cb392988ad8f0b2955c2bbf 
```

Вывод команды — 64-символьная строка — это уникальный ID вновь созданной Docker-сети внутри подсистемы Docker; первые 12 символов (`aeb9dcd262b9`) будут использованы в названии вновь созданного сетевого интерфейса в «хозяйской» системе: `br-aeb9dcd262b9`. Да-да, к сожалению интерфейс получит такое не очень «складное» название, а не `dcr_itl_25`, как хотелось бы. `dcr_itl_25` можно использовать только как псевдоним 64-символьного ID в вызовах типа `docker network <command> <...>` и `docker inspect <...>` и т.п..  

Проверяем:
```bash
$ ifconfig 
... ... ...
br-aeb9dcd262b9: flags=4099<UP,BROADCAST,MULTICAST>  mtu 1500
        inet 10.255.25.1  netmask 255.255.255.0  broadcast 10.255.25.255
        ether 02:42:c6:0c:97:fe  txqueuelen 0  (Ethernet)
        RX packets 0  bytes 0 (0.0 B)
        RX errors 0  dropped 0  overruns 0  frame 0
        TX packets 0  bytes 0 (0.0 B)
        TX errors 0  dropped 0 overruns 0  carrier 0  collisions 0

... ... ...
```

*Замечание:*
`dcr_itl_25` — это название нашей вновь созданной сети во внутренней базе Docker'а, к ней подключен сетевой интерфейс `br-aeb9dcd262b9` «хозяйской» ОС. Аналогично интерфейс `docker0` «хозяйской» ОС соответствует (подключен к) Docker-сети `bridge`. Именно это имя надо использовать при обращении к нему командами типа `docker network <command> <...>`, а не `docker0`.
```bash
$ docker network list
NETWORK ID     NAME         DRIVER    SCOPE
f997ac3adf33   bridge       bridge    local  # <--- interface docker0
aeb9dcd262b9   dcr_itl_25   bridge    local  # <--- interface br-aeb9dcd262b9
a39def0f1bd0   host         host      local
9f8789a408d6   none         null      local
```


### Включение поддержки `/etc/rc.local` в systemd ###
<anchor>rc-local-systemd</anchor>

Да-да, старый добрый и любимый линуксойдами-олдфагами `/etc/rc.local` потихоньку уходит в прошлое. Однако в systemd предусмотрена «заглушка» для его запуска.  

В первую очередь необходимо создать сам файл `/etc/rc.local` и сделать его исполняемым (права доступа `root:root 755`). Первой и последней строками в нем должны быть:
```bash
#!/bin/bash
exit 0
```
Всё «осмысленное» содержимое должно помещаться между этими строками.  

Однако этого может оказаться недостаточно, и при попытке запуска соответствующего `rc-local.service` мы получим такого типа ошибку:
```bash
$ sudo systemctl enable rc-local.service
The unit files have no installation config (WantedBy=, RequiredBy=, Also=,
Alias= settings in the [Install] section, and DefaultInstance= for template
units). This means they are not meant to be enabled using systemctl.
 ... ... ...
```

В этом случае необходимо создать еще один файл: `/etc/systemd/system/rc-local.service` с правами доступа `root:root 644` и нижеследующим содержимым:
```ini
#  SPDX-License-Identifier: LGPL-2.1+
#
#  This file is part of systemd.
#
#  systemd is free software; you can redistribute it and/or modify it
#  under the terms of the GNU Lesser General Public License as published by
#  the Free Software Foundation; either version 2.1 of the License, or
#  (at your option) any later version.
 
# This unit gets pulled automatically into multi-user.target by
# systemd-rc-local-generator if /etc/rc.local is executable.
[Unit]
Description=/etc/rc.local Compatibility
Documentation=man:systemd-rc-local-generator(8)
ConditionFileIsExecutable=/etc/rc.local
After=network.target
 
[Service]
Type=forking
ExecStart=/etc/rc.local start
TimeoutSec=0
RemainAfterExit=yes
GuessMainPID=no
 
[Install]
WantedBy=multi-user.target
```

Теперь включение и запуск rc-local.service проходят без ошибок:
```bash
$ sudo systemctl enable rc-local.service
$ sudo systemctl restart rc-local.service

$ sudo systemctl status rc-local.service
● rc-local.service - /etc/rc.local Compatibility
     Loaded: loaded (/etc/systemd/system/rc-local.service; enabled; vendor preset: enabled)
    Drop-In: /usr/lib/systemd/system/rc-local.service.d
             └─debian.conf
     Active: active (exited) since ... ... ...
       Docs: man:systemd-rc-local-generator(8)
    Process: 1720 ExecStart=/etc/rc.local start (code=exited, status=0/SUCCESS)
```

*Замечание:* 
В репозиториях Ubuntu есть пакет `netfilter-persistent`, который позволяет сохранять и восстанавливать после перезагрузки текущую конфигурацию `iptables`:
```bash
Description-en: boot-time loader for netfilter configuration
 This package provides a loader for netfilter configuration using a
 plugin-based architecture. It can load, flush and save a running
 configuration. Extending netfilter-persistent with plugins is trivial and can
 be done in any language.
```
Тем не менее, я предпочел метод с `/etc/rc.local` так как он позволяет подгружать и применять любые другие настройки и твики, не ограничиваясь одним только `iptables`. В былые времена у меня посредством команд в `/etc/rc.local` применялось большое количество настроек оптимизации производительности системы и не только.  


### Настройка файервола `iptables` ###
<anchor>iptables</anchor>

Поскольку мы планируем использовать `iptables`, убеждаемся, что другой популярный файервол — `ufw` — не активен. Если активен, то отключаем его:
```bash
$ sudo ufw status 
Состояние: неактивен
$ sudo ufw disable # если активен
```
Это же касается всех других файерволов: файервол должен остаться только один! `;-)`  

Что касается настроек `iptables`, то будем вносить изменения в таблицу `filter` цепочки `INPUT`. Напомню, что директива `-j ACCEPT` означает немедленное покидание пакетом означенной таблицы цепочки, и все последующие правила в данной таблице данной цепочки к нему не применяются. Поэтому важен порядок правил. В приведенной ниже настройке мы желаем:
1.  В качестве примера — и поэтому соответствующие директивы закомментированы — разрешить запросы на входящие TCP соединения на порты 22, 80 и 443 (ssh, http и https, соответственно) на всех сетевых интерфейсах. Т.е. предполагается, что у нас на хосте запущены и ждут входящих подключений `sshd` и `httpd`. Если вы действительно хотите поднять у себя эти службы и открыть на прослушивание соответствующие порты, и если вы не хотите, чтобы вас при этом хакнули, вам необходимо воспользоваться утилитой вроде `fail2ban` (см. ссылки в конце). Назначение для ssh «экзотического» порта (типа 2222) мало полезно, ибо вредоносные боты сканируют все порты.
2.  Разрешить запросы на все входящие соединения с `loopback` интерфейса, а также со всех виртуальных сетевых интерфейсов, созданных Docker'ом, баня при этом все «фэйковые» запросы — т.е. запросы, которые указывают IP-адрес из подсети данного интерфейса, но при этом приходят с другого интерфейса.
3.  Разрешить запросы на пинги откуда угодно.
4.  Разрешить трафик в уже установленных (`ESTABLISHED`) (и связанных с ними (`RELATED`) соединениях.
5.  Забанить всё, что не попало под хотя бы один из выше перечисленных критериев.

Очевидно, что выше приведенная схема запрещает все попытки инициализации всех входящих соединений из «внешки» (локалки и Интернета), за исключением явно оговоренных в п. 1. Т.е. при таких настройках открытые TCP/IP-порты xorg заведомо недоступны для подключения извне.  

В итоге соответствующая вставка в `/etc/rc.local` выглядит так:
```bash
# -------------------------------------------------------------------------------------------------
# iptables settings
# -----------------
iptables --policy INPUT ACCEPT 

# EXAMPLE: allow incoming ssh connections to port 22, http and https connections to ports 80 and 443
#iptables -A INPUT -p tcp --dport 22 -m state --state NEW -j ACCEPT
#iptables -A INPUT -p tcp --dport 80 -m state --state NEW -j ACCEPT
#iptables -A INPUT -p tcp --dport 443 -m state --state NEW -j ACCEPT
# ------------------------------------------------------------------

# allow all input traffic from loopback iface, 
# and drop fake connections having src IP out of 127.0.0.0/8 but NOT going from the lo iface
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT ! -i lo -s 127.0.0.0/8 -j DROP

# allow all input traffic from docker0 iface, and drop fake connections (the same way as for the lo)
iptables -A INPUT -i docker0 -j ACCEPT
iptables -A INPUT ! -i docker0 -s 172.17.0.0/16 -j DROP

# allow all input traffic from br-aeb9dcd262b9 iface, and drop fake connetions (the same way as for the lo)
iptables -A INPUT -i br-aeb9dcd262b9 -j ACCEPT
iptables -A INPUT ! -i br-aeb9dcd262b9 -s 10.255.25.0/24 -j DROP

# allow pings from outside
iptables -A INPUT -p icmp -m state --state NEW --icmp-type 8 -j ACCEPT

# allow input traffic from already established connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# drop all the other incoming packets
iptables -A INPUT -j DROP
# -------------------------------------------------------------------------------------------------
```

Перезагружаемся и убеждаемся, что все настройки `iptables` применились:
```bash
$ sudo iptables -t filter --list --line-numbers   
 
Chain INPUT (policy ACCEPT)
num  target     prot opt source               destination         
1    ACCEPT     tcp  --  anywhere             anywhere             tcp dpt:ssh state NEW
2    ACCEPT     all  --  anywhere             anywhere            
3    DROP       all  --  localhost/8          anywhere            
4    ACCEPT     all  --  anywhere             anywhere            
5    DROP       all  --  172.17.0.0/16        anywhere            
6    ACCEPT     all  --  anywhere             anywhere            
7    DROP       all  --  10.255.25.0/24       anywhere            
8    ACCEPT     icmp --  anywhere             anywhere             state NEW icmp echo-request
9    ACCEPT     all  --  anywhere             anywhere             state RELATED,ESTABLISHED
10   DROP       all  --  anywhere             anywhere            

Chain FORWARD (policy DROP)
num  target     prot opt source               destination
 ... ... ...
 # Другие цепочки: FORWARD, OUTPUT, DOCKER, DOCKER-ISOLATION-STAGE-1, 
 # DOCKER-ISOLATION-STAGE-2, DOCKER-USER и др., - должны остаться без изменений, 
 # т.к. в этих цепочках таблицы filter мы ничего не меняли.
```

Аналогично без изменений должны остаться и другие таблицы. Проверяем так:
```bash
$ sudo iptables -t nat --list --line-numbers
$ sudo iptables -t raw --list --line-numbers
$ sudo iptables -t mangle --list --line-numbers
$ sudo iptables -t security --list --line-numbers
```

Возможно, вывод команды `iptables -t <TABLE-NAME> --list --line-numbers` не самый репрезентативный. Возможно, следует подобрать другие опции командной строки. Можно также воспользоваться такой командой, чтобы проверить, вступили ли изменения в силу:
```bash
$ sudo iptables -S
-P INPUT ACCEPT
-P FORWARD DROP
-P OUTPUT ACCEPT
-N DOCKER
-N DOCKER-ISOLATION-STAGE-1
-N DOCKER-ISOLATION-STAGE-2
-N DOCKER-USER
-A INPUT -p tcp -m tcp --dport 22 -m state --state NEW -j ACCEPT
-A INPUT -i lo -j ACCEPT
-A INPUT -s 127.0.0.0/8 ! -i lo -j DROP
-A INPUT -i docker0 -j ACCEPT
-A INPUT -s 172.17.0.0/16 ! -i docker0 -j DROP
-A INPUT -i br-aeb9dcd262b9 -j ACCEPT
-A INPUT -s 10.255.25.0/24 ! -i br-aeb9dcd262b9 -j DROP
-A INPUT -p icmp -m state --state NEW -m icmp --icmp-type 8 -j ACCEPT
-A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
-A INPUT -j DROP
-A FORWARD -j DOCKER-USER
-A FORWARD -j DOCKER-ISOLATION-STAGE-1
-A FORWARD -o docker0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A FORWARD -o docker0 -j DOCKER
-A FORWARD -i docker0 ! -o docker0 -j ACCEPT
-A FORWARD -i docker0 -o docker0 -j ACCEPT
-A FORWARD -i br-aeb9dcd262b9 -o br-aeb9dcd262b9 -j ACCEPT
-A DOCKER-ISOLATION-STAGE-1 -i docker0 ! -o docker0 -j DOCKER-ISOLATION-STAGE-2
-A DOCKER-ISOLATION-STAGE-1 ! -s 10.255.25.0/24 -o br-aeb9dcd262b9 -j DROP
-A DOCKER-ISOLATION-STAGE-1 ! -d 10.255.25.0/24 -i br-aeb9dcd262b9 -j DROP
-A DOCKER-ISOLATION-STAGE-1 -j RETURN
-A DOCKER-ISOLATION-STAGE-2 -o docker0 -j DROP
-A DOCKER-ISOLATION-STAGE-2 -j RETURN
-A DOCKER-USER -j RETURN
```

*Замечание № 1* 
Напоминаю, что:
*   `docker0: 172.17.0.1/16` — виртуальный сетевой интерфейс Docker; был создан автоматически при установке Docker'а со всеми параметрами по умолчанию, подключен к Docker-сети, которая не является «внутренней» (`"Internal": false` в терминологии Docker), т.е. из этой сети есть «выход» (маршрутизация пакетов) в локалку и Интернет.
*   `br-aeb9dcd262b9: 10.255.25.1/24` — виртуальный сетевой интерфейс Docker, созданный мной в процессе настройки ([см. выше](#internal-docker-network)). Имя сгенерировано Docker'ом автоматически. Является интерфейсом «внутренней» сети (`"Internal": true`), т.е. из его сети нет «выхода» (маршрутизации пакетов) в «локалку» и Интернет.

*Замечание № 2* 
У меня всего две виртуальных Docker-сети. При создании дополнительных Docker-сетей для них необходимо прописывать явно правила `iptables` по шаблону:
```bash
# allow all input traffic from <NEW-DOCKER-INTERFACE> iface, and drop fake connetions (the same way as for the lo)
iptables -A INPUT -i <NEW-DOCKER-INTERFACE> -j ACCEPT
iptables -A INPUT ! -i <NEW-DOCKER-INTERFACE> -s <IT\'S-NET-IP/MASK-BIT-NUM> -j DROP
```
и помещать эти команды ДО финальной
```bash
# drop all the other incoming packets
iptables -A INPUT -j DROP
```
Лучше — в конец «списка» команд для ранее существовавших Docker-сетей.  



### Включение поддержки TCP/IP «хозяйским» xorg-сервером ### 
<anchor>xorg-tcp</anchor>

Итак, по умолчанию xorg слушает только unix-socket; только для локальных подключений. Необходимо поменять настройки запуска «иксов» так, чтобы он стартовал с поддержкой TCP-подключений. В большинстве настольных дистрибутивов X-сервер запускается не самостоятельно и не напрямую, а посредством Display Manager'а. Именно в настройках Display Manager'а необходимо подправить настройки запуска «иксов». В моем случае — это LightDM ([инструкции для других Display Manager'ов тут](https://lanforge.wordpress.com/2018/03/30/enabling-remote-x-connections/); см. также [Ссылки](#refs), которые приведены в самом конце статьи.), и именно настройки LightDM мы и будем менять. Для того, чтобы LightDM стал запускать «иксы» с поддержкой TCP, необходимо отредактировать следующие файлы:
*   `/usr/share/lightdm/lightdm.conf.d/50-xserver-command.conf`
*   `/etc/lightdm/lightdm.conf`

Для первого файла следует создать «диверт», чтобы при очередном обновлении менеджер пакетов не перезаписал его версией из пакета:
```bash
$ sudo dpkg-divert --divert /usr/share/lightdm/lightdm.conf.d/50-xserver-command.conf.orig --rename /usr/share/lightdm/lightdm.conf.d/50-xserver-command.conf
$ sudo cp -aT /usr/share/lightdm/lightdm.conf.d/50-xserver-command.conf.orig /usr/share/lightdm/lightdm.conf.d/50-xserver-command.conf
```

Приводим содержимое `/usr/share/lightdm/lightdm.conf.d/50-xserver-command.conf` к виду:
```ini
[Seat:*]
# Dump core
#xserver-command=X -core
xserver-command=X -core -listen inet -listen unix
```

В файл `/etc/lightdm/lightdm.conf` дописываем в конец:
```ini
# this is to allow TCP connections
xserver-allow-tcp=true
xserver-command=X -core -listen inet -listen unix
```

Я также пробовал изменять файл `/etc/X11/xinit/xserverrc` предварительно сделав диверт: 
```bash
$ sudo dpkg-divert --divert /etc/X11/xinit/xserverrc.orig --rename /etc/X11/xinit/xserverrc 
$ sudo cp -aT /etc/X11/xinit/xserverrc.orig /etc/X11/xinit/xserverrc
```
и внёс в него такое изменение:
```sh
#exec /usr/bin/X -nolisten tcp "$@"
exec /usr/bin/X -listen inet -listen unix "$@"
```

Однако одних только изменений в файле `/etc/X11/xinit/xserverrc` недостаточно. LightDM при запуске «иксов» игнорирует эти настройки. Судя по всему, настройки в этом файле применяются только при запуске «иксов» через `startx` и `xinit`.

Теперь после всех этих изменений необходимо перезагрузиться. После перезагрузки убеждаемся, что теперь наш xorg слушает подключения по TCP в дополнение к unix-socket. Убеждаемся в этом при помощи `pgrep`:

```bash
$ pgrep X | xargs ps -lfwwwp
F S UID          PID    PPID  C PRI  NI ADDR SZ WCHAN  STIME TTY          TIME CMD
4 S root        1768    1739  4  80   0 - 217636 -     16:13 tty7     00:00:06 /usr/lib/xorg/Xorg -core -listen inet -listen unix :0 -seat seat0 -auth /var/run/lightdm/root/:0 -listen tcp vt7 -novtswitch
```

и `nmap` (ожидаем открытый порт 6000):

```bash
$ sudo nmap -p6000 127.0.0.1
Nmap scan report for localhost (127.0.0.1)
Host is up (0.000096s latency).
PORT     STATE SERVICE
6000/tcp open  X11        # <--------------------------- open !!!
Nmap done: 1 IP address (1 host up) scanned in 0.14 seconds


$ sudo nmap -p6000 10.255.25.1
Nmap scan report for 10.255.25.1 # br-aeb9dcd262b9 "Internal" Docker interface
Host is up (0.000076s latency).
PORT     STATE SERVICE
6000/tcp open  X11        # <--------------------------- open !!!
Nmap done: 1 IP address (1 host up) scanned in 0.12 seconds


$ sudo nmap -p6000 172.17.0.1
Nmap scan report for 172.17.0.1 # docker0 default non-"Internal" Docker interface
Host is up (0.000073s latency).
PORT     STATE SERVICE
6000/tcp open  X11        # <--------------------------- open !!!
Nmap done: 1 IP address (1 host up) scanned in 0.17 seconds
```

Заодно убеждаемся, что файервол работает. Для этого запускаем `nmap` с соседнего компа в своей локальной сети, указав в качестве параметра IP своего компа в этой «локалке»:
```bash
# nmap -p6000 172.25.25.230
Nmap scan report for 172.25.25.230
Host is up (0.067s latency).
PORT     STATE    SERVICE
6000/tcp filtered X11        # <--------------------------- filtered !!!
Nmap done: 1 IP address (1 host up) scanned in 0.94 seconds
```
(*Замечание:* нет смысла проверять свой внешний сетевой интерфейс «изнутри», т.е. со своей же машины. `nmap` покажет `open`, видимо потому, что свой собственный IP в «локалке» либо не попадает под критерий `INPUT` для `iptables`, либо сразу же редиректится на `loopback`.)



### Подготовка Docker-образа: Dockerfile ###
<anchor>dockerfile</anchor>

Сначала приведу здесь содержимое своего Dockerfile'а, а затем прокомментирую его содержимое.

```Dockerfile
FROM ubuntu:20.04

# Define DISPLAY as ARG; set up DISPLAY for root user
ARG DISPLAY=10.255.25.1:0
ENV DISPLAY=${DISPLAY}

# Define non-root user, it's UID, gecos string and password
ARG user=bob
ARG uid=1000
ARG password=${user}

# Prepare "internal" Docker volume for /opt/matlab
VOLUME /opt/matlab

# Copy configs' tarball to /configs.tar.bz2
COPY configs.tar.bz2 /

# + Install most important packages
# + Install basic fonts
# + Install additional fonts
# + Install libraries -- dependences of MatLab
# + Unpack configs; remove configs' tarball
# + Set up root password
# + Add non-root user
RUN <<EOT bash
  apt-get update -y -qq
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sudo bash-completion net-tools vim iputils-ping nmap htop mc ssh xauth xterm mesa-utils
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ttf-mscorefonts-installer ttf-dejavu ttf-xfree86-nonfree fonts-dejavu-core fonts-freefont-ttf fonts-opensymbol fonts-urw-base35 fonts-symbola ttf-bitstream-vera 
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ttf-unifont xfonts-unifont fonts-prociono ttf-ubuntu-font-family fonts-georgewilliams fonts-hack fonts-yanone-kaffeesatz ttf-aenigma ttf-anonymous-pro ttf-engadget ttf-sjfonts ttf-staypuft ttf-summersby 
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libgtk2.0-0 libnss3 libatk-bridge2.0-0 libgbm1 
  tar xf /configs.tar.bz2 --overwrite --directory=/ && rm -f /configs.tar.bz2 
  echo "root:${password}" | chpasswd
EOT
# ----- \begin{non-root-user-section} --------------------------
RUN <<EOT bash
  adduser --quiet --home /home/${user} --shell /bin/bash --uid ${uid} --disabled-password --gecos "${gecos}" --add_extra_groups ${user}
  echo "${user}:${password}" | chpasswd
  echo -e "\necho \"Your password is: ${password}\" \n" >> /home/${user}/.bashrc
EOT


# Set up USER and WORKDIR; set up DISPLAY for that USER
USER ${user}
WORKDIR /home/${user}
ENV DISPLAY=${DISPLAY}
# ----- \end{non-root-user-section} ----------------------------

# Run bash on the container's start
CMD bash
```

За основу нашего образа возьмём ОС Ubuntu 20.04 Focal Fossa. Просто потому, что на момент написания этого обзора это — моя основная рабочая ОС, и я её неплохо знаю. В принципе любой актуальный Debian-подобный дистрибутив должен подойти без особых изменений (или вообще без изменений) во всей оставшейся части Dockerfile'а.  

Напомню, что директивы `ARG` используются Docker'ом в процессе сборки образа, а директивы `ENV` задают переменные окружения внутри контейнера при его запуске.  

`10.255.25.1` — это IP-адрес интерфейса `br-aeb9dcd262b9` в «хозяйской» ОС, подключенного к «изолированной» Docker-сети `dcr_itl_25`; этот IP-адрес назначен ему на (условно) постоянной основе: он первый из списка адресов своей подсети и всегда достается «хозяйской» ОС, т.к. она загружается — а, следовательно, и появляется в этой подсети — первой. Далее контейнерам по мере их запуска адреса из этой подсети назначаются динамически, по мере их подключения к этой Docker-сети, начиная с `10.255.25.2`.  
`DISPLAY=10.255.25.1:0` означает, что из контейнера мы будем «стучаться» на порт 6000, которому соответствует `DISPLAY=:0` локального пользователя. Т.е. мы будем запускать наш Docker-контейнер, будучи залогинившимися первым (и, как правило, единственным ;-)) «графическим пользователем». Как мы помним, именно ему назначается `DISPLAY=:0`. Далее по тексту мы будем считать, что это будет `user-1`, как это было в первом разделе «теоретической» части.  
Думаю, уже понятно, что для авторизации GUI-приложений, запускаемых внутри нашего контейнера, на «хозяйском» xorg мы будем использовать метод ACL'ов `xhost`. Именно поэтому в нашем Dockerfile нет ничего про переменную окружения `XAUTHORITY`, как и не предусмотрено никакой передачи «волшебной» куки внутрь контейнера.  

При установке Ubuntu на компьютер всем интерактивным (не-системным) учетным записям назначаются `UID`'ы начиная с 1000. Поэтому первый, созданный при установке этой ОС, пользователь получит `UID=1000`. Этот юзер чаще всего остается не только первым созданным, но и вообще единственным интерактивным пользователем. В нашем примере — это `user-1` «хозяйской» ОС. Чтобы избежать проблем с правами доступа при «расшаривании» папок «хозяйской» ОС внутрь нашего Docker-контейнера, назначим нашему не-«рутовому» юзеру внутри контейнера тот же `UID`, т.е. равный 1000. Отсюда идёт директива `ARG uid=1000`. А назовём мы этого юзера `bob`, просто `bob`, для краткости. Так же и его пароль, как и пароль root'а тоже, — будут `bob`.  

Важно отметить, что мы будем запускать наш Docker-контейнер в т.н. "root-mode". В таком режиме `UID`'ы юзеров внутри контейнера напрямую соответствуют `UID`'ам юзеров «хозяйской» ОС. Есть еще вариант настроить Docker для работы в "rootless-mode". Это намного более безопасный режим работы с контейнерами. В этом режиме нужно специально настраивать и явно прописывать mapping юзеров внутри контейнера на юзеров «хозяйской» ОС. В этом случае будет уже не важно, какой там `UID` получит не-«рутовый» юзер внутри контейнера: всё будет определяться настройками mapping'а. Однако разбор и настройка "rootless-mode" выходят за пределы данного обзора.  

Назначим отдельный виртуальный Docker-том (`VOLUME`), который будет примонтирован к ФС нашего контейнера как `/opt/matlab`. Именно в эту папку мы и будем ставить Matlab. Назначение отдельного виртуального Docker-тома позволит сразу «убить двух зайцев». Во-первых, этот самый том с точки зрения «хозяйской» ОС — просто подпапка «в недрах» `/var/lib/docker`, или другой папки, которая является `docker-data-root` в вашей установке (опция `data-root` в файле `/etc/docker/daemon.json` ; по умолчанию — как раз `/var/lib/docker`). Благодаря этому мы сможем «поковыряться во внутренностях» Matlab'овских Toolbox'ов, не только не запуская контейнер, но и даже ничего никуда не монтируя. Во-вторых, тома можно подключать сразу к нескольким контейнерам и передавать от одного контейнера к другому. Это (возможно! Я надеюсь — но тут всё зависит от правил активации лицензии Matlab...) позволит при пересоздании контейнера просто передать ему том с установленным Matlab'ом, избежав его, Matlab'а, переустановки.  

Файл `configs.tar.bz2` — это архив с конфигами, которые касаются настроек интерактивных сеансов `bash`, кое-каких изменений в `/etc/inputrc` (поиск по истории введённых ранее команд клавишами `PgUp` и `PgDn`), настроек для `adduser` (изменения в `/etc/skel/`), назначения `aliases` для `bash` и т.п. Одним словом — это красивости и удобства, без которых лично мне будет «грустно».  

Поскольку в процессе сборки образа из Dockerfile'а не предусмотрено никакого взаимодействия с юзером-«оператором», все вызовы `apt-get` должны быть полностью не-интерактивными. Любые запросы на подтверждение продолжения установки, диалоги послеустановочной настройки (как при установке `mc`, например) или диалоги принятия лицензионного соглашения (как в случае `ttf-mscorefonts-installer`) приведут к тому, что попытка сборки образа неминуемо завершится ошибкой. Отсюда такой синтаксис вызовов `apt-get`.  

Все пакеты я разбил на 4 группы, каждая из которых устанавливается своим отдельным вызовом `apt-get install`. 

1.  Наиболее важные с моей точки зрения пакеты. Это базовые средства системного администрирования, а также `xterm` — чтобы подтянуть все основные зависимости для запуска GUI-приложений, плюс `mesa-utils` — это средства для тестирования «иксов», такие как `glxheads`, `glxgears` и т.д., и плюс `xauth` — на случай, если мы захотим поэкспериментировать в контейнере с «волшебными» куки и `XAUTHORITY`.
2.  Основные шрифты для GUI-приложений, без которых почти невозможно комфортно работать.
3.  Дополнительные шрифты для GUI-приложений, без которых в принципе можно и обойтись.
4.  Библиотеки-зависимости, без которых не работает Matlab.

Такое разбиение на группы сделано для того, чтобы мой Dockerfile было проще модифицировать, если возникнет необходимость исключить ненужные пакеты из финального образа.  

Наконец, при запуске контейнера я хочу, чтобы:
1.  я был залогинин юзером `bob` (директива `USER`), 
2.  моей текущей рабочей директорией была домашняя папка `bob`'а (`WORKDIR`),
3. в качестве интерпретатора оболочки был запущен `bash` (`CMD`). 

Я также предусмотрел возможность лёгкой модификации моего Dockerfile'а на случай, если кто-то захочет образ, в котором есть только root и нет bob'а или другого не-«рутового» пользователя. Для этого достаточно закомментировать (или удалить) строки от `# ----- \begin{non-root-user-section}` до `# ----- \end{non-root-user-section}`. Кстати, именно поэтому директива `ENV DISPLAY=${DISPLAY}` в моем Dockerfile встречается дважды.  



### Создание Docker-контейнера и его первый запуск ###
<anchor>docker-create</anchor>

Допустим, что мы разместили приведённый выше Dockerfile (со всеми зависимостями) в папке: 
`~/GIT/focal-gui-xclient/`
Создаем образ из Dockerfile'а:
```bash
$ docker build ~/GIT/focal-gui-xclient/ -t focal-gui-xclient
```
Создание образа займёт некоторое время. Будет много текстового вывода. Убеждаемся, что последняя строка такая:
```bash
 => => naming to docker.io/library/focal-gui-xclient
```
А код возврата — ноль:
```bash
$ echo $?
0
```

Опция `-t focal-gui-xclient` позволяет задать "tag", т.е. имя образа, по которому мы можем его идентифицировать в дальнейшем.
```bash
$ docker images
REPOSITORY          TAG       IMAGE ID       CREATED         SIZE
focal-gui-xclient   latest    bbd4caed2232   5 minutes ago   738MB  # <----- Вот он.
focal_gui_02        latest    d8e84032f5ae   6 months ago    546MB
focal_gui_01        latest    d75b3ba00feb   8 months ago    299MB
ubuntu              20.04     f32fe8df6a4c   9 months ago    72.8MB
```


Теперь, используя собранный образ, мы можем создавать сколько угодно контейнеров — например, для установки и запуска разных версий Matlab.  
Создадим первый такой контейнер:
```bash
$ docker create --name ml_r2022b -ti -h ml_r2022b -v /home/user-1/DOCKER_SHARE/MatLab:/data -v /etc/localtime:/etc/localtime focal-gui-xclient
2aea7ff34db0196cc0c9f40f5baa17cff9f1a0f0677567b69589b377b91fe4cd
```
В отличие от образа контейнер создаётся почти мгновенно. Вывод команды — это уникальный ID вновь созданного контейнера в локальной базе Docker'а.  
Опция `-v` означает "volume", она нужна чтобы подмонтировать в режиме "bind" папку `/home/user-1/DOCKER_SHARE/MatLab` из «хозяйской» ОС в папку `/data` внутри Docker-контейнера. Такое монтирование необходимо, чтобы наладить обмен файлами между «хозяйской» ОС и контейнером; мы помним, что ФС контейнера полностью изолирована от «хозяйской» ФС. Опции `-t` и `-i` — "tty" и "interactive" соответственно — нужны, чтобы сделать взаимодействие с контейнером интерактивным. Опция `-h ml_r2022b` задает имя хоста контейнера (hostname), оно, в частности, отображается в приглашении командной строки в формате `user@hostname`. `--name ml_r2022b` — это удобочитаемое имя контейнера, по которому его можно будет найти в списке контейнеров. Я сознательно сделал значения этих двух опций одинаковыми для удобства идентификации. 
```bash
$ docker ps -a
CONTAINER ID   IMAGE               COMMAND             CREATED          STATUS                         PORTS     NAMES
2aea7ff34db0   focal-gui-xclient   "/bin/sh -c bash"   29 minutes ago   Created                                  ml_r2022b  # <--- Вот он, наш контейнер.
132ee3c699ce   focal_gui_02        "/bin/sh -c bash"   6 months ago     Exited (0) About an hour ago             focal_02
5cd450dc1260   f32fe8df6a4c        "/bin/bash"         8 months ago     Exited (0) 5 hours ago                   focal_01
```

Запустим вновь созданный контейнер:
```bash
user-1@ThinkPad:~$ docker start -ai ml_r2022b
To run a command as administrator (user "root"), use "sudo <command>".
See "man sudo_root" for details.

Your password is: bob
bob@ml_r2022b:~$ 
```
Здесь опция `-a` означает "attach", т.е. подключить контейнер к `STDOUT`/`STDERR` «хозяйской» ОС, а опция `-i`, т.е. "interactive" подключить `STDIN` контейнера к «хозяину».  

Видим, что наш контейнер появился в выводе `docker ps`:
```bash
$ docker ps
CONTAINER ID   IMAGE               COMMAND             CREATED             STATUS          PORTS     NAMES
2aea7ff34db0   focal-gui-xclient   "/bin/sh -c bash"   About an hour ago   Up 41 seconds             ml_r2022b
```

По умолчанию контейнер оказывается подключенным только к Docker-сети `bridge` которой соответствует интерфейс `docker0` «хозяйской» ОС (`IP 172.17.0.1/16`) и которая имеет маршрутизацию во вне.
```bash
bob@ml_r2022b:~$ ifconfig 
eth0: flags=4163<UP,BROADCAST,RUNNING,MULTICAST>  mtu 1500
        inet 172.17.0.2  netmask 255.255.0.0  broadcast 172.17.255.255  # <---- ср. с 172.17.0.1/16 интерфейса docker0
        ether 02:42:ac:11:00:02  txqueuelen 0  (Ethernet)
        RX packets 14  bytes 2204 (2.2 KB)
        RX errors 0  dropped 0  overruns 0  frame 0
        TX packets 0  bytes 0 (0.0 B)
        TX errors 0  dropped 0 overruns 0  carrier 0  collisions 0

lo: flags=73<UP,LOOPBACK,RUNNING>  mtu 65536
        inet 127.0.0.1  netmask 255.0.0.0
        loop  txqueuelen 1000  (Local Loopback)
        RX packets 0  bytes 0 (0.0 B)
        RX errors 0  dropped 0  overruns 0  frame 0
        TX packets 0  bytes 0 (0.0 B)
        TX errors 0  dropped 0 overruns 0  carrier 0  collisions 0

bob@ml_r2022b:~$ ping 8.8.8.8
PING 8.8.8.8 (8.8.8.8) 56(84) bytes of data.
64 bytes from 8.8.8.8: icmp_seq=1 ttl=110 time=50.0 ms
64 bytes from 8.8.8.8: icmp_seq=2 ttl=110 time=36.7 ms
64 bytes from 8.8.8.8: icmp_seq=3 ttl=110 time=55.6 ms
^C
--- 8.8.8.8 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2004ms
rtt min/avg/max/mdev = 36.681/47.435/55.607/7.939 ms

bob@ml_r2022b:~$ ping www.google.com
PING www.google.com (142.250.201.196) 56(84) bytes of data.
64 bytes from bud02s35-in-f4.1e100.net (142.250.201.196): icmp_seq=1 ttl=110 time=44.6 ms
64 bytes from bud02s35-in-f4.1e100.net (142.250.201.196): icmp_seq=2 ttl=110 time=62.3 ms
64 bytes from bud02s35-in-f4.1e100.net (142.250.201.196): icmp_seq=3 ttl=110 time=61.8 ms
^C
--- www.google.com ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2003ms
rtt min/avg/max/mdev = 44.620/56.250/62.338/8.227 ms
```

В текущей конфигурации запустить какое-либо GUI-приложение не получится:
```bash
bob@ml_r2022b:~$ xterm 
No protocol specified
xterm: Xt error: Can\'t open display: 10.255.25.1:0

bob@ml_r2022b:~$ echo $DISPLAY
10.255.25.1:0
```
(10.255.25.1 — это IP-адрес интерфейса `br-aeb9dcd262b9` в «хозяйской» ОС, он соответствует Docker-сети `dcr_itl_25`)  

Помимо этого, в «хозяйской» системе доступ к «иксам» ограничен:
```bash
user-1@ThinkPad:~$ xhost 
access control enabled, only authorized clients can connect
SI:localuser:user-1
```

Исправим это. Сперва подключим наш контейнер к Docker-сети `dcr_itl_25` (`IP 10.255.25.0/24`):
```bash
user-1@ThinkPad:~$ docker network connect dcr_itl_25 ml_r2022b
```

Видим, что внутри контейнера появился ещё один сетевой интерфейс, и есть доступ к IP, где «лежит» x-дисплей:
```bash
bob@ml_r2022b:~$ ifconfig 
eth0: flags=4163<UP,BROADCAST,RUNNING,MULTICAST>  mtu 1500
        inet 172.17.0.2  netmask 255.255.0.0  broadcast 172.17.255.255
        ether 02:42:ac:11:00:02  txqueuelen 0  (Ethernet)
        RX packets 85  bytes 14888 (14.8 KB)
        RX errors 0  dropped 0  overruns 0  frame 0
        TX packets 21  bytes 1553 (1.5 KB)
        TX errors 0  dropped 0 overruns 0  carrier 0  collisions 0

eth1: flags=4163<UP,BROADCAST,RUNNING,MULTICAST>  mtu 1500
        inet 10.255.25.2  netmask 255.255.255.0  broadcast 10.255.25.255  # <------- Вот он.
        ether 02:42:0a:ff:19:02  txqueuelen 0  (Ethernet)
        RX packets 11  bytes 1310 (1.3 KB)
        RX errors 0  dropped 0  overruns 0  frame 0
        TX packets 9  bytes 566 (566.0 B)
        TX errors 0  dropped 0 overruns 0  carrier 0  collisions 0

lo: flags=73<UP,LOOPBACK,RUNNING>  mtu 65536
        inet 127.0.0.1  netmask 255.0.0.0
        loop  txqueuelen 1000  (Local Loopback)
        RX packets 0  bytes 0 (0.0 B)
        RX errors 0  dropped 0  overruns 0  frame 0
        TX packets 0  bytes 0 (0.0 B)
        TX errors 0  dropped 0 overruns 0  carrier 0  collisions 0

bob@ml_r2022b:~$ ping 10.255.25.1
PING 10.255.25.1 (10.255.25.1) 56(84) bytes of data.
64 bytes from 10.255.25.1: icmp_seq=1 ttl=64 time=0.088 ms
64 bytes from 10.255.25.1: icmp_seq=2 ttl=64 time=0.111 ms
64 bytes from 10.255.25.1: icmp_seq=3 ttl=64 time=0.097 ms
^C
--- 10.255.25.1 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2054ms
rtt min/avg/max/mdev = 0.088/0.098/0.111/0.009 ms
```

Однако этого всё ещё недостаточно для запуска какого-либо GUI-приложения, в чем легко убедиться, попытавшись запустить `xterm`. Необходимо открыть доступ к «иксам» на стороне «хозяйской» ОС. Для этого необходимо либо добавить IP-адрес нашего контейнера в Список Контроля Доступа `xhost`:
```bash
user-1@ThinkPad:~$ xhost +10.255.25.2
10.255.25.2 being added to access control list

user-1@ThinkPad:~$ xhost 
access control enabled, only authorized clients can connect
INET:10.255.25.2
SI:localuser:user-1
```
либо (на время) отключить Контроль Доступа `xhost`:
```bash
user-1@ThinkPad:~$ xhost +
access control disabled, clients can connect from any host
```
(что крайне *НЕ РЕКОМЕНДУЕТСЯ!* Хотя в нашем случае это относительно безопасно: от всех внешних сетей мы прикрыты файерволом. Опасаться можно разве что «пассажиров» из других Docker-контейнеров, если они вообще запущены, а также «гостей» из других графических сеансов, если в данный момент залогинино более одного «графического пользователя».)  

Теперь `xterm`, как и любое другое GUI-приложение, запустить получится.  

Однако в текущей конфигурации у нас всё ещё есть доступ из контейнера во вне, в чём легко убедиться при помощи утилиты `ping`. Чтобы изолировать контейнер, необходимо отключить его от Docker-сети `bridge`:
```bash
user-1@ThinkPad:~$ docker network disconnect bridge ml_r2022b
```
Теперь доступа в Интернет изнутри контейнера нет:
```bash
bob@ml_r2022b:~$ ifconfig 
eth1: flags=4163<UP,BROADCAST,RUNNING,MULTICAST>  mtu 1500
        inet 10.255.25.2  netmask 255.255.255.0  broadcast 10.255.25.255  # <--- сеть dcr_itl_25
        ether 02:42:0a:ff:19:02  txqueuelen 0  (Ethernet)
        RX packets 1687  bytes 464087 (464.0 KB)
        RX errors 0  dropped 0  overruns 0  frame 0
        TX packets 1553  bytes 182498 (182.4 KB)
        TX errors 0  dropped 0 overruns 0  carrier 0  collisions 0

lo: flags=73<UP,LOOPBACK,RUNNING>  mtu 65536
        inet 127.0.0.1  netmask 255.0.0.0
        loop  txqueuelen 1000  (Local Loopback)
        RX packets 6  bytes 465 (465.0 B)
        RX errors 0  dropped 0  overruns 0  frame 0
        TX packets 6  bytes 465 (465.0 B)
        TX errors 0  dropped 0 overruns 0  carrier 0  collisions 0

bob@ml_r2022b:~$ ping www.google.com
ping: www.google.com: Temporary failure in name resolution

bob@ml_r2022b:~$ ping 8.8.8.8
PING 8.8.8.8 (8.8.8.8) 56(84) bytes of data.
^C
--- 8.8.8.8 ping statistics ---
571 packets transmitted, 0 received, 100% packet loss, time 583666ms
```

Необходимо отметить, что сетевая конфигурация контейнера сохраняется между его перезапусками. Т.е. если на данном этапе остановить наш контейнер — так, чтобы он не отображался в выводе `docker ps` — а потом снова запустить, то он окажется подключенным только к одной Docker-сети — `dcr_itl_25`, как это и было до того, как мы его «заглушили».  

Еще один весьма важный момент относительно настройки нашего контейнера — это установка правильной тайм-зоны, чтобы часы внутри контейнера показывали то же время, что и часы в «хозяйской» ОС. Изначально при сборке контейнера часы выставляются так, чтобы показывать время UTC. Чтобы поменять это, надо изменить цель, на которую указывает симлинк `/etc/localtime`. Изначально он указывает на `/usr/share/zoneinfo/Etc/UTC`. Надо посмотреть, куда указывает `/etc/localtime` в «хозяйской» ОС и перенаправить его в контейнере на тот же файл (относительно ФС контейнера). Пусть в «хозяйской» ОС он указывает на `/usr/share/zoneinfo/Europe/Podgorica`, тогда внутри контейнера надо сделать так: 
```bash
bob@ml_r2022b:~$ sudo rm -f /etc/localtime
bob@ml_r2022b:~$ sudo ln -s /usr/share/zoneinfo/Europe/Podgorica /etc/localtime
```
Всё, теперь в «хозяине» и в контейнере время и часовой пояс одинаковые.  

*Замечание №1:* Альтернативное — и более правильное — решение проблемы с тайм-зоной внутри контейнера такое. Передать опцию `-v /etc/localtime:/etc/localtime` на этапе `docker create`.  
*Замечание №2:* Внёс соответствующее изменение в инструкцию в [соответствующем разделе](#docker-create).  


### Работа с контейнером ###
<anchor>using-container</anchor>

Для запуска контейнера используем команду в терминале:
```bash
user-1@ThinkPad:~$ docker start -ai ml_r2022b
To run a command as administrator (user "root"), use "sudo <command>".
See "man sudo_root" for details.

Your password is: bob
bob@ml_r2022b:~$ 
```
А для остановки достаточно просто ввести `exit` в последней из интерактивных сессий нашего контейнера:
```bash
bob@ml_r2022b:~$ exit
exit
user-1@ThinkPad:~$
```
При этом мы вернемся в командную строку «хозяйской» ОС.  

Для того, чтобы получить возможность запускать в контейнере GUI-приложения, необходимо добавить IP-адрес нашего контейнера в `xЫhost` ACL:
```bash
user-1@ThinkPad:~$ xhost +10.255.25.2
10.255.25.2 being added to access control list
```
А после остановки контейнера его желательно удалить из ACL:
```bash
user-1@ThinkPad:~$ xhost -10.255.25.2
10.255.25.2 being removed from access control list
```

Узнать IP-адрес контейнера можно, например, при помощи команды `ifconfig` внутри контейнера.  
Такая «возня» с ACL'ами `xhost` весьма неудобна. Помимо этого, `xhost +<Host Name or IP address>` не позволяет добавить сразу диапазон IP-адресов или шаблон имени хостов: хосты можно вносить/удалять только индивидуально и только по одному за один вызов. Поэтому я автоматизировал этот процесс, написав для этого такой скрипт (я назвал его `xhosts4dockernet_keeper.sh`):
```bash
#/bin/bash
# xhosts4dockernet_keeper.sh [DockerNetworkName | INET:]

# docker-network to be inspected, if no input passed:
NetworkName="dcr_itl_25"
#NetworkName="INET:"
# ---------------------------------------------------
# "default" net mask size, if unsupported value was met;
# supported values are: 8, 16 and 24 [bits] only.
defNetMaskSz=24
# ---------------------------------------------------

if [[ $1 ]] ; then
  NetworkName="$1"
fi

# Force enable xhost's ACL support
xhost -

# If special "INET:" DockerNetworkName is met, remove all 
# the records of "inet" family from the ACL and exit.
if [[ "${NetworkName}" = "INET:" ]] ; then
  xhostIPs=$(xhost | sed -n 's/INET://p')
  for xip in $xhostIPs ; do
    xhost -${xip}
  done
  exit $?
fi

# Obtain address and mask size of the given docker-network.
dn=$(docker network inspect -f '{{json .IPAM.Config}}' ${NetworkName} | sed 's/\[//' | sed 's/\]//' | jq '.Subnet' | sed 's/"//g')
netMaskSz=${dn#*/}
netAddr=${dn%/*}

# Check whether the net mask size is supported. If not --
# fall back to its "default" value and print Warning message.
if [[ -z "$(echo '8 16 24' | grep ${netMaskSz})" ]] ; then
  echo "Warning!"
  echo "Unsupported net mask size: ${netMaskSz} bits"
  echo "Supported values are: 8, 16 and 24 bits only."
  echo "Will treat your xhost's ACL as if the mask size was ${defNetMaskSz} bits."
  echo "This could lead to some unexpected results!"
  netMaskSz=${defNetMaskSz}
fi

# Set up the IP address filter from the address and mask size. 
case "${netMaskSz}" in
  8)
    recFltr=INET:$(echo ${netAddr} | awk 'BEGIN { FS = "."; OFS="." } ; { print $1 }').
    ;;
  16)
    recFltr=INET:$(echo ${netAddr} | awk 'BEGIN { FS = "."; OFS="." } ; { print $1,$2 }').
    ;;
  24)
    recFltr=INET:$(echo ${netAddr} | awk 'BEGIN { FS = "."; OFS="." } ; { print $1,$2,$3 }').
    ;;
esac


# It's time to treat xhost's ACL:
# -------------------------------
# 1. Add to xhost's ACL all the found IPs of all running 
# containers - members of the given docker-network.
# xhost is smart enough to not add the already added IP.

dockerIPs=$(docker network inspect -f '{{json .Containers}}' ${NetworkName} | jq '.. | if type=="object" and has("Name") then .IPv4Address else empty end' | sed  's/"//g' | sed 's/\/[0-9]*//')

for ip in $dockerIPs ; do
  xhost +${ip}
done

# 2. Clear xhost ACL records that do not correspond to any running container
# of the given docker-network.
xhostIPs=$(xhost | grep ${recFltr} | sed 's/INET://')
for xip in $xhostIPs ; do
  if [[ -z "$(echo $dockerIPs | grep ${xip})" ]] ; then
    xhost -${xip}
  fi
done
```

`xhosts4dockernet_keeper.sh` принимает в качестве аргумента имя Docker-сети (такое как `dcr_itl_25`), которую необходимо обслужить. Этот скрипт делает запрос о том, какие именно контейнеры в данной Docker-сети в данный момент работают и какие у них IP-адреса. Потом добавляет все эти IP-адреса в `xhost` ACL. Затем удаляет из ACL IP-адреса, которые относятся к данной Docker-сети, но при этом не принадлежат ни одному из работающих контейнеров. Все другие IP-адреса — *НЕ принадлежащие данной Docker-сети* — остаются нетронутыми.  Если вместо имени Docker-сети передать специальное слово `INET:`, то этот скрипт удалит из `xhost` ACL вообще все записи относящиеся к сетевым клиентам (только IPv4. IPv6 не поддерживается, и записи соответствующие IPv6 игнорируются!).  

Теперь каждый раз после запуска или остановки какого либо очередного Docker-контейнера, подключенного, допустим, к Docker-сети `dcr_itl_25` для обновления `xhost` ACL достаточно выполнить в терминале «хозяйской» ОС команду:
```bash
user-1@ThinkPad:~$ xhosts4dockernet_keeper.sh dcr_itl_25
```
(при условии, что этот скрипт лежит одной из папок, прописанных в переменной окружения `PATH`. Например, его можно поместить в `~/bin/`).  

Подключать контейнер к изолированной Docker-сети — например, `dcr_itl_25` — и отключать от не-изолированной — например, `bridge` — каждый раз при старте контейнера не требуется. Как мы помним, контейнер «запоминает» свои сетевые подключения между перезапусками. Однако в некоторых случаях нам всё же может потребоваться на время подключить наш контейнер к не-изолированной Docker-сети, например, чтобы произвести обновление установленных пакетов или что-либо доустановить. В этом случае сперва запускаем `htop` от имени root'а внутри контейнера:
```bash
bob@ml_r2022b:~$ sudo htop
```
(или любой другой менеджер задач) и убеждаемся, что процессы, которым нельзя в Интернет, не запущены. Если запущены — глушим из прямо из интерфейса `htop`'а. Только после этого можно подключаться к не-изолированной Docker-сети:
```bash
user-1@ThinkPad:~$ docker network connect bridge ml_r2022b
```
После выполнения всех, связанных с Интернетом, работ внутри контейнера не забываем отключить наш контейнер от не-изолированной сети:
```bash
user-1@ThinkPad:~$ docker network disconnect bridge ml_r2022b
```

И в заключение этого раздела отмечу еще один момент. Если командностроковой интерфейс Docker-контейнера занят выполнением какой-либо программы, то имеется возможность «параллельного» интерактивного подключения к этому контейнеру: 
```bash
user-1@ThinkPad:~$ docker exec -ti ml_r2022b /bin/bash
Your password is: bob
bob@ml_r2022b:~$
```
И у нас снова есть свободная командная строка.  



### Установка Matlab ###
<anchor>matlab</anchor>

Будем ставить Matlab из iso-образа. Поместим `MatlabLin64.iso` (вместе с другими файлами, необходимыми для установки Matlab) в папку `/home/user-1/DOCKER_SHARE/MatLab/_install` на стороне «хозяйской» ОС, которая на стороне контейнера отобразится как `/data/_install`. Примонтировать iso-образ изнутри Docker-контейнера не получится. При попытке это сделать выскочит такая ошибка:
```bash
root@ml_r2022b:/home/bob# mount -o loop /data/_install/MatlabLin64.iso /mnt
mount: /mnt: mount failed: Operation not permitted.
```

Дело в том, что по умолчанию операции монтирования внутри контейнера запрещены. Они разрешены только для контейнеров, которые были созданы с опцией `--privileged`. Т.е. эта опция должна была быть передана команде `docker create` ещё на этапе создания контейнера. Пересоздавать контейнер мы не будем. В первую очередь потому, что опция `--privileged` весьма опасна: помимо операций монтирования она позволяет делать много чего еще. А наша цель — создать как можно более ограниченный в правах контейнер.  

Поэтому мы поступим так. Остановим контейнер. Затем на стороне «хозяйской» ОС создадим подпапку `mnt/` в папке `/home/user-1/DOCKER_SHARE/MatLab/_install` и примонтируем в неё наш iso-образ:
```bash
user-1@ThinkPad:~$ cd ~/DOCKER_SHARE/MatLab/_install
user-1@ThinkPad:~/DOCKER_SHARE/MatLab/_install$ sudo mount -o loop MatlabLin64.iso mnt
```

Теперь можно снова запустить наш контейнер. Если выполнить монтирование iso-образа при работающем контейнере, то изнутри контейнера папка `/data/_install/mnt/` так и останется пустой: контейнер просто проигнорирует событие монтирования.  

В итоге со стороны контейнера iso-образ окажется примонтированным в папку `/data/_install/mnt/` . Изучим её содержимое. Среди прочего там есть файл `installer_input.txt`. Он предназначен для полностью автоматизированной не-интерактивной установки Matlab. На мой взгляд это очень удобно, т.к. позволяет сохранить все настройки и опции моей установки, и не вспоминать при последующих переустановках Matlab, как там оно было у меня в прошлый раз. Поэтому скопируем этот файл куда-нибудь за пределы примонтированного образа и отредактируем его под себя. Для дальнейшего изложения будем считать, что мы скопировали его в `/data/_install/installer_input.txt`.  

Я не буду приводить здесь содержимое своего `installer_input.txt`, отмечу лишь некоторые параметры внутри этого файла, на которые следует обратить внимание. Если их не прописать явно, то автоматическая установка не пройдёт. Их следует раскомментировать и вписать в них желаемые / требуемые значения.
```sh
destinationFolder=/opt/matlab/RXXXX    # куда будем ставить
fileInstallationKey=xxxxx-xxxxx-xxxxx-xxxxx..... 
agreeToLicense=yes
outputFile=/data/_install/install.log  # пригодится, если что-то пойдёт не так
enableLNU=no       # здесь только no, мы же изолируемся от сети
improveMATLAB=no   # и здесь тоже по той же причине
licensePath=/path/to/license.file
```
В конце идет список Тулбоксов. Раскомментируем те из них, которые желаем установить (и на использование которых у нас есть лицензия!).  

Теперь можно приступать к установке. Однако здесь нас может ожидать еще один «сюрприз» — не удовлетворенные зависимости для Matlab, когда не хватает некоторых библиотек. Чтобы выяснить так это или нет, будем действовать следующим образом. Сначала попробуем запустить установщик Matlab в интерактивном режиме:
```bash
bob@ml_r2022b:~$ su
root@ml_r2022b:/home/bob# cd /data/_install/mnt/
root@ml_r2022b:/data/_install/mnt# ./install
```
Если все зависимости удовлетворены, то вскоре появится GUI-окошко «MathWorks Product Installer» с текстом лицензионного соглашения и предложением принять его. В этом случае можно смело жать «Cancel» и переходить к автоматической установке (ну, или продолжить интерактивную установку, если очень хочется). Если же чего-то не хватает, то вместо GUI-окошка мы получим в терминале примерно такое сообщение об ошибке:
```bash
terminate called after throwing an instance of 'std::runtime_error'
  what():  Failed to launch web window with error: Unable to launch the MATLABWindow application. The exit code was: 127
Aborted (core dumped)
```

Чтобы выяснить чего именно не хватает, будем запускать эту самую `MATLABWindow`, которая расположена по пути `./bin/glnxa64/MATLABWindow` относительно точки монтирования iso-образа:
```bash
root@ml_r2022b:/data/_install/mnt# ./bin/glnxa64/MATLABWindow
./bin/glnxa64/MATLABWindow: error while loading shared libraries: libgtk-x11-2.0.so.0: cannot open shared object file: No such file or directory
```
Видим, что не хватает файла `libgtk-x11-2.0.so.0`. Ищем, к какому пакету он относится. Для этого можно воспользоваться [поиском пакетов Ubuntu](https://packages.ubuntu.com/) ([аналогичный сервис для Debian](https://www.debian.org/distrib/packages)) или даже просто попробовать поискать в Google, вбив в строку поиска это имя файла. Находим: в нашем случае это файл из пакета `libgtk2.0-0`. Подключаем наш контейнер к Docker-сети `bridge` (которая имеет маршрутизацию в Интернет) и устанавливаем этот пакет:
```bash
root@ml_r2022b:/data/_install/mnt# apt-get install libgtk2.0-0
```
Теперь отключаем наш контейнер от сети `bridge` и пробуем снова запустить `MATLABWindow`. Так повторяем до тех пор, пока вместо сообщения в терминале об ошибке об очередном недостающем файле не откроется GUI-окошко этой самой MATLABWindow. Не стоит пугаться сообщению об ошибке в этом окошке:
```
==========================================
    Unable to open the requested feature.
==========================================
 Check your internet connection and proxy
 settings in MATLAB Web preferences and 
 then try starting the feature again.
==========================================
 Detailed information:

Error code: -105
Error message: ERR_NAME_NOT_RESOLVED
==========================================
```
`MATLABWindow` всего лишь «ругается», что не может «достучаться» на сервера MathWorks. Ведь это именно то, ради чего всё это и было затеяно! А вот если коннект прошел — значит мы забыли отключить наш контейнер от Docker-сети `bridge`. В этом случае как раз стоит напрячься.  

Еще раз убеждаемся, что всё ОК, еще раз запустив установщик Matlab в интерактивном режиме. Если действительно всё ОК — переходим к автоматической установке. Для этого запускаем `install` с параметром `-inputFile`, который указывает на путь к файлу `installer_input.txt` (который мы заранее подготовили):
```bash
root@ml_r2022b:/data/_install/mnt# ./install -inputFile /data/_install/installer_input.txt
```
Процесс установки займет некоторое время.  

Согласно настройкам в `installer_input.txt` мы поместили лог установки в файл `/data/_install/install.log`. Если установка прошла успешно, последние две строчки этого лога должны выглядеть примерно так:
```log
(Oct 26, 2023 14:55:30) Exiting with status 0
(Oct 26, 2023 14:55:30) End - Successful
```

Остался последний штрих — выполнить активацию нашего Matlab. Это — «высокое колдунство» 80-го уровня ;-) Здесь всё зависит от того, как именно и какую именно лицензию вы приобрели. Поэтому описывать здесь эту процедуру я не вижу смысла. Просто напоминаю об этом последнем шаге.  

Наконец, пробуем запустить наш свежеустановленный Matlab:
```bash
bob@ml_r2022b:/data/_install/mnt$ /opt/matlab/RXXXX/bin/matlab
```

Обратите внимание: мы устанавливали Matlab от имени `root`'а, а запускать и пользоваться будем от имени `bob`'а.  

Для упрощения запуска Matlab можно сделать симлинк с именем `matlab` в папке `/home/bob/bin`:
```bash
bob@ml_r2022b:~$ mkdir bin
bob@ml_r2022b:~$ ln -s /opt/matlab/RXXXXx/bin/matlab ~/bin/matlab
```

Поскольку папки `/home/bob/bin` (скорее всего) не было, то команда `matlab` в терминале заработает только после повторного логина `bob`'а в систему или после перезапуска контейнера.  

Наконец, не забываем отмонтировать iso-образ в «хозяйской» ОС, предварительно остановив наш контейнер:
```bash
user-1@ThinkPad:~/DOCKER_SHARE/MatLab/_install$ sudo umount mnt
```

Вот как выглядит Matlab запущенный из Docker-контейнера на фоне окон «хозяйской» ОС. Обратите внимание на заголовки окон. Если оконное приложение запущено из контейнера, то в конце заголовка его окна в скобках это указано — вместе с именем контейнера. На мой взгляд это очень удобно.
![Matlab запущенный из Docker-контейнера](https://habrastorage.org/webt/t6/ev/-f/t6ev-fyarlgsaot1-oexwqqfsly.png)

На этом всё. Спасибо за внимание!

----------------------------------------------------------------------------------

## P.S. или Дополнения ##
<anchor>anneces</anchor>

### Дополнение 1: Xwayland и `socat` ###
<anchor>annex-xwayland-socat</anchor>

Если вы счастливый обладатель систем на основе Xwayland...  

... то описанный в этой статье способ «расшарить» X-дисплей «не про вас». Xwayland не умеет слушать подключения по TCP/IP. Однако, на просторах Интернета мною был найден [способ](https://askubuntu.com/questions/34657/how-to-make-x-org-listen-to-remote-connections-on-port-6000) обхода этого ограничения при помощи утилиты socat, которая позволяет «поднять» двунаправленный туннель между любым свободным TCP портом и юникс-сокетом. Этот способ можно использовать и в случае xorg. Более того, он позволит добиться желаемого результата без внесения изменений в файлы конфигурации «иксов» и Display Manager'а и перезагрузки. Кроме того, этот способ позволяет явно задать, на каком именно сетевом интерфейсе будет открыт TCP/IP порт, что потенциально позволяет избежать возни с настройкой iptables (хотя настроить iptables в любом случае будет полезно). И это — преимущества данного способа.  

Недостатком же является то, что X-сервер «понятия не имеет» о том, что к нему открыт доступ по TCP/IP. Даже если клиент подключается по TCP, его TCP-подключение передается на юникс-сокет «иксов». Поэтому каждый подключающийся к X-серверу клиент выглядит с точки зрения сервера как локальный.  
Вследствие этого:
1. ACL'ы `xhost` больше не работают;
2. Удалённым TCP-клиентам для установки соединения требуется такая же «волшебная» куки, как и локальным, и правильно выставленная переменная окружения `XAUTHORITY`. 

Кстати, — если верить информации по ссылкам далее — просто скопировать свой `~/.Xauthority` и передать его «удаленному» клиенту (в нашем случае — внутрь Docker-контейнера) *не получится*. Для удаленного клиента / Docker-контейнера «хозяйскую» куки надо подправить, как это описано [тут](https://github.com/mviereck/x11docker/wiki/How-to-access-X-over-TCP-IP-network). Или вообще выписать отдельную, более безопасную, "untrusted cookie", как это описано [тут](https://github.com/mviereck/x11docker/wiki/X-authentication-with-cookies-and-xhost-(%22No-protocol-specified%22-error)).  

Да, «волшебные» куки бывают двух видов: «доверенные» ("trusted cookie") и «недоверенные» ("untrusted cookie"). Первые предоставляют GUI-приложениям удалённого клиента те же полномочия, что и GUI-приложениям хозяина. Они содержат копию уникальной (псевдо-)случайной последовательности 16-ричных цифр из «хозяйской» куки и отличаются лишь полями `DISPLAY` и `hostname`. Недостатком таких куки является их небезопасность. Они не обеспечивают изоляцию приложений из Docker-контейнера / удаленного хоста, что позволяет:  
> For example, keylogging with `xev` or `xinput` is possible, and remote control of host applications with `xdotool`. [[см. тут](https://stackoverflow.com/questions/16296753/can-you-run-gui-applications-in-a-linux-docker-container/39681017#39681017)]  

«Недоверенные» ("untrusted cookie") содержат свою уникальную хэш-последовательность 16-ричных цифр и обеспечивают бОльшую изоляцию приложений из Docker-контейнера / удаленного хоста от локальных GUI-приложений:
> The X server will deny some security sensitive features to applications that use this cookie. [[см. тут](https://github.com/mviereck/x11docker/wiki/X-authentication-with-cookies-and-xhost-(%22No-protocol-specified%22-error))]  


Итак, чтоб «расшарить» юникс-сокет «иксов» при помощи `socat`, необходимо на стороне «хозяйской» ОС выполнить в терминале:
```bash
$ sudo su
# socat -d -d TCP-LISTEN:$((6000+111)),fork,bind=10.255.25.1 UNIX-CONNECT:/tmp/.X11-unix/X0 &
```
Это откроет порт 6111 на сетевом интерфейсе 10.255.25.1 (т.е. `br-aeb9dcd262b9`, который, как мы помним, подключен к изолированной Docker-сети `dcr_itl_25`) как двунаправленный канал обмена данными с юникс-сокетом `/tmp/.X11-unix/X0` X-сервера. Если вместо 10.255.25.1 указать 0.0.0.0 , то юникс-сокет будет «расшарен»
на всех сетевых интерфейсах «хозяйской» ОС. ` -d -d ` — это не опечатка. Согласно [документации](http://www.dest-unreach.org/socat/doc/socat.html#OPTIONS):
> -d -d  
>       Prints fatal, error, warning, and notice messages.

Этот `socat`-канал будет работать до тех пор, пока мы не закроем терминал, в котором мы его запустили. Это означает, что — как минимум — каждый раз после перезагрузки «хозяйской» ОС `socat` надо будет перезапускать вручную, что может быть не очень удобно. Если необходимо автоматизировать процесс его запуска, `socat` можно «деймонизировать», создав `systemd`-сервис по [этой инструкции](https://medium.com/@benmorel/creating-a-linux-service-with-systemd-611b5c8b91d6).

Теперь чтобы подключаться к «хозяйскому» X-серверу, внутри Docker-контейнера надо выставить переменную окружения `DISPLAY`:
```bash
$ export DISPLAY=127.0.0.1:111 
```
Единоразово попробовать запустить какое-нибудь GUI-приложение, не изменяя глобально значение `DISPLAY`, можно так:
```bash
$ DISPLAY=127.0.0.1:111 xterm
```
В любом случае, как мы помним, в контейнере должна быть актуальная версия «волшебной» куки и правильно выставленная переменная окружения `XAUTHORITY`.  

Сам `socat` есть в репозиториях Ubuntu 20.04, его можно установить командой:
```bash
$ sudo apt install socat
```

Да, лично я описанный в этом Дополнении способ *не тестил* — пусть это будет «домашним заданием» читателя.  


### Дополнение 2: Метод без использования TCP/IP-сети ###
<anchor>annex-unix-socket-to-docker-volume</anchor>

Да, есть и такой. Он предполагает монтирование в режиме "bind" файлов XAUTHORITY-куки и юникс-сокета «хозяйской» ОС внутрь Docker-контейнера путем передачи опции `-v` (`--volume `) на этапе создания контейнера:
```bash
docker create -ti \
              --env XAUTHORITY=/cookie \
              --volume ~/cookie4container:/cookie \
              --env DISPLAY=$DISPLAY \
              --volume /tmp/.X11-unix/X0:/tmp/.X11-unix/X0 \
              --ipc=host \
              [--<other-options> ...] \
              <docker-image-name>
```
Здесь `~/cookie4container` — файл, содержащий специально подготовленную «волшебную» куки — "trusted" или "untrusted" — как это было упомянуто в [предыдущем разделе](#annex-xwayland-socat). Поскольку «хозяйский» юникс-сокет напрямую отображается в таковой внутри Docker-контейнера, то и значение переменной окружения `DISPLAY` в «хозяйской» ОС и в контейнере должны быть одинаковыми.

Отдельно про опцию `--ipc=host`. Дело в том, что «иксы» используют shared memory для ускорения своей работы, которая по умолчанию недоступна изнутри Docker-контейнера. В то же время при такой конфигурации Docker-контейнера для GUI-приложений внутри этого контейнера всё выглядит так, как будто они запущены локально в «хозяйской» ОС. В итоге это приводит к ошибкам при попытке запуска в контейнере приложений, активно использующих shared memory. Опция `--ipc=host` как раз позволяет сделать доступной внутри контейнера «хозяйскую» shared memory. Это, конечно же не очень хорошо с точки зрения безопасности, поскольку снижает уровень изоляции контейнера.  
Поддержка shared memory в «иксах» называется `MIT-SHM` extension. Если оно включено — значит shared memory используется, вернее — GUI-приложения могут её использовать и будут пытаться это делать. Узнать, включена ли поддержка `MIT-SHM` можно так:
```bash
xdpyinfo | grep MIT-SHM
    MIT-SHM  # <--------- значит включено
```

Есть несколько вариантов решить эту проблему, т.е. избежать использования опции `--ipc=host`.  
Первый способ — это отключить поддержку `MIT-SHM` X-сервером «хозяйской» ОС. Для этого нужно создать файл `/etc/X11/xorg.conf.d/disable-MIT-SHM.conf` с таким содержимым:
```ini
Section "Extensions"
    Option "MIT-SHM" "Disable"
EndSection
```
Однако это замедлит работу «иксов», вернее некоторых GUI-приложений в «хозяйской» ОС.  

Другой вариант — генерировать для Docker-контейнера "untrusted cookies". [Пишут](https://github.com/mviereck/x11docker/wiki/X-authentication-with-cookies-and-xhost-(%22No-protocol-specified%22-error)), что X-клиентам с "untrusted cookies" запрещено использовать `MIT-SHM`. Т.е. в этом случае GUI-приложения внутри контейнера не будут пытаться использовать shared memory. Правда есть один минус: некоторые GUI-приложения отказываются работать с "untrusted cookies".  

Наконец, третий вариант заключается в следующем. Предлагается написать и скомпилировать «патч», который подменяет стандартные библиотечные функции проверки наличия включенного `MIT-SHM` extension таким образом, что всегда выдает, что это расширение отключено. Далее использовать механизм `LD_PRELOAD` при запуске GUI-программы:
```bash
env LD_PRELOAD=/path/to/XlibNoSHM.so <GUI-APP-COMMAND>
```
Или сделать так, чтобы автоматически «патчить» все запускаемые программы:
```bash
export LD_PRELOAD=/path/to/XlibNoSHM.so

```
Здесь `XlibNoSHM.so` — тот самый скомпилированный «патч». Компилировать его надо внутри контейнера. Исходный код «патча» доступен [здесь](https://github.com/mviereck/dockerfile-x11docker-xserver/blob/main/XlibNoSHM.c). Сама проблема с `MIT-SHM` в контексте запуска GUI-приложений внутри Docker-контейнеров обсуждается [здесь](https://github.com/jessfraz/dockerfiles/issues/359).  

Интересно, что, по-видимому, «исторически первая» (по крайней мере из найденных мной) попытка *систематически* «подружить» GUI-приложения с Docker'ом в ОС GNU/Linux как раз основана на методе запуска X-клиентов внутри Docker-контейнеров,  описанном в этом Дополнении. Я нашел описание такого способа в [посте](https://blog.jessfraz.com/post/docker-containers-on-the-desktop/) некой Jess Frazelle от 21 февраля 2015 года. Вот цитата оттуда:  
> The images work by mounting the X11 socket into the container! Yippeeeee!  

В этом посте её докер-контейнеры создаются с такими опциями:
```
-v /tmp/.X11-unix:/tmp/.X11-unix \ # mount the X11 socket
-e DISPLAY=unix$DISPLAY \ # pass the display
``` 
Т.е. она использует этот же метод «расшаривания» unix-socket'а через опцию `-v` при создании Docker-контейнера.  

Она развернула «кипучую деятельность» по контейнеризации различных GUI-приложений (Matlab'а среди них нет). С её Dockerfile'ами можно ознакомиться на её страничке на гитхабе: [github.com/jessfraz/dockerfiles](https://github.com/jessfraz/dockerfiles), а собранные Docker-образы  доступны на докер-хабе: [hub.docker.com/u/jess](https://hub.docker.com/u/jess/)  

Также интересно, что именно пользователи её докер-образов как раз первыми и обнаружили эту самую проблему с MIT-SHM. Т.к. обсуждение этого бага расположено на её страничке на гитхабе: MIT-SHM error solutions — [**github.com/jessfraz/dockerfiles**/issues/359](https://github.com/jessfraz/dockerfiles/issues/359).  


### Дополнение 3: x11docker ###
<anchor>annex-x11docker</anchor>

В процессе подготовки окончательной версии этой статьи я наткнулся на проект [`x11docker`](https://github.com/mviereck/x11docker). Внимательный читатель заметит, что часть ссылок на источники как раз ведет на странички на [wiki](https://github.com/mviereck/x11docker/wiki) этого замечательного проекта. `x11docker` решает ту же задачу запуска GUI-приложений – X-клиентов внутри Docker-контейнеров, что и я в этой статье, но только с гораздо большим «размахом». Так, среди его «фишечек»:  

- Повышенное внимание к безопасности и изоляции. Предусмотрена возможность запуска промежуточного «вложенного» (nested) X-сервера. (Некоторые реализации «иксов» позволяют «вложение»: когда один X-сервер является X-клиентом другого X-сервера.) Более того, предусмотрена даже возможность собирать и запускать отдельный [Docker-контейнер](https://github.com/mviereck/dockerfile-x11docker-xserver/tree/main) с промежуточным «вложенным» X-сервером для еще большей изоляции. Кстати, подобное «вложение» само по себе позволяет автоматически решить проблему с `MIT_SHM`.
- Есть возможность выбора одной из нескольких реализаций X-серверов.
- Огромное количество других опций и настроек. 
- Запуск контейнера с пользовательским GUI-приложением с минимально необходимыми привилегиями.
- Возможность «расшаривать» внутрь контейнера звуковые устройства, принтеры, веб-камеры и т.д.

И это — далеко неполный список.  

Единственный «недостаток» этого проекта заключается в том, что сам `x11docker` — это здоровенный bash-скрипт размером 11640 (sic!) строк, и он по сути единственный файл в проекте (есть еще Dockerfile для образа с «вложенным» X-сервером). Так что если «что-то пойдёт не так» — отлаживать-ремонтировать будет очень нудно и грустно.  

В то же время, моё решение — быстрое и простое. Несмотря на то, что оно не обеспечивает такой гибкости и такой изоляции, как `x11docker` — оно с поставленными задачами справляется. В конце концов, Matlab — не настолько «агрессивный зловред», чтобы его требовалось дополнительно изолировать от окошек моих GUI-приложений на моей «хозяйской» ОС (я надеюсь...).  


### Дополнение 4: запуск Matlab через systemd-run ###
<anchor>annex-systemd-run-matlab</anchor>

Справедливости ради необходимо отметить, что существует и более простой способ изолировать Matlab от Интернета без использования Docker — при помощи `systemd`. Для этого его запускать надо вот так:
```bash
systemd-run --scope -p IPAddressDeny=any -p IPAddressAllow=localhost <matlabFolder>/bin/matlab
```
Здесь `<matlabFolder>` — папка, куда был установлен Matlab. Это может быть что-то типа `~/Matlab/RXXXXx`, если это установка для одного локального не-root'ового пользователя, или `/opt/matlab/RXXXXx` в случае system-wide установки.  

Такой способ, однако, не изолирует Matlab от ФС «хозяйской» ОС, как хотелось бы мне.  

И тем не менее `systemd` позволяет создавать «песочницы» для изоляции приложений и их процессов в виртуальном окружении, поскольку использует механизм [namespaces](https://en.wikipedia.org/wiki/Linux_namespaces), белые и чёрные списки [capabilities](https://man7.org/linux/man-pages/man7/capabilities.7.html), а также [control groups (aka cgroups)](https://wiki.archlinux.org/title/Control_groups) для контейнеризации процессов при помощи настраиваемых окружений. Таким образом, `systemd` в принципе может реализовать почти весь тот же функционал, что и Docker. Однако в случае с `systemd` придётся изрядно повозиться. Добавление к существующему «юниту» `systemd` функциональности «песочницы» обычно происходит методом проб и ошибок вкупе с использованием различных инструментов логгирования, таких как `strace`, `stderr` и `journalctl`. Однако это — уже совсем другая история.  

В любом случае, те, кому достаточно изоляции Matlab'а только от Интернета и локальных сетей, могут использовать метод, описанный в этом Дополнении, а контейнеризацию Matlab в Docker, которую я описал в этой статье, могут рассматривать как своего рода proof-of-concept.  


## P.P.S. xhost TCP/IP и MIT-SHM ## 
<anchor>pps-xhost-MIT-SHM</anchor>

Я был абсолютно уверен, что предложенный мною метод взаимодействия GUI-приложений из Docker-контейнера с «хозяйским» X-сервером через TCP/IP гарантирует отсутствие проблемы с `MIT-SHM`, которая описана в [Дополнении 2](#annex-unix-socket-to-docker-volume). Действительно, о какой shared memory может идти речь, когда предполагается, что различные клиенты (GUI-приложения) — как и X-сервер — выполняются (могут выполняться) на физически разных машинах? А вот поди ж ты!  
Запускаю свой контейнер, проверяю:
```bash
bob@ml_r2022b:~$ xdpyinfo | grep MIT-SHM
    MIT-SHM
bob@ml_r2022b:~$
```
Ну и дела! Значит, в следующем релизе своего Dockerfile'а я добавлю установку «патча» `XlibNoSHM.so`.  
Почему я сразу этого не заметил? Потому, что работе Matlab отсутствие этого «патча» не мешает. По крайней мере я не наблюдал связанных с `MIT-SHM` ошибок. Видимо, Matlab не использует это расширение «иксов».  


Вот теперь — точно всё. Ещё раз Спасибо За Внимание всем, кто «асилил»! `;-)`

----------------------------------------------------------------------------------

## ССЫЛКИ ##
<anchor>refs</anchor>

Проект на гит-хабе с моими файлами: [dm-MariK/focal-gui-xclient](https://github.com/dm-MariK/focal-gui-xclient)  

----------------------------------------------------------------------------------

**Как работает аутентификация в «иксах»**  

[**Remote X Apps mini-HOWTO**](https://tldp.org/HOWTO/Remote-X-Apps.html)  
*Особенно заслуживают внимания эти разделы:*  
[7\. X Applications from Another User-id](https://tldp.org/HOWTO/Remote-X-Apps-7.html)  
[6\. Telling the Server](https://tldp.org/HOWTO/Remote-X-Apps-6.html)  

*Наиболее подробное и внятное разъяснение роли xhost я нашел здесь:*  
[X authentication with cookies and xhost](https://github.com/mviereck/x11docker/wiki/X-authentication-with-cookies-and-xhost-(%22No-protocol-specified%22-error))  

----------------------------------------------------------------------------------

**Изолированная Docker-сеть**  
[Restrict Internet Access - Docker Container](https://stackoverflow.com/questions/39913757/restrict-internet-access-docker-container)  

*Еще про Docker-сети можно почитать в официальной документации проекта Docker:*  
<https://docs.docker.com/network/>  
<https://docs.docker.com/desktop/networking/>  
<https://docs.docker.com/network/network-tutorial-standalone/>  
<https://docs.docker.com/engine/tutorials/networkingcontainers/>  

[**Как узнать IP-адрес Docker контейнера**](https://itsecforu.ru/2021/04/02/%F0%9F%90%B3-%D0%BA%D0%B0%D0%BA-%D1%83%D0%B7%D0%BD%D0%B0%D1%82%D1%8C-ip-%D0%B0%D0%B4%D1%80%D0%B5%D1%81-docker-%D0%BA%D0%BE%D0%BD%D1%82%D0%B5%D0%B9%D0%BD%D0%B5%D1%80%D0%B0/)  
(материал отсюда я использовал при написании скрипта `xhosts4dockernet_keeper.sh`)  

**Включение поддержки `/etc/rc.local` в systemd**  
[Ubuntu 20.04 – start program after boot](https://synaptica.info/2020/06/26/ubuntu-20-04-rc-local-start-a-process-after-boot/)  

**Настройка `iptables`**  
[Iptables — Материал из Викиучебника](https://ru.wikibooks.org/wiki/Iptables)
[Использование утилиты iptables на Linux](https://1cloud.ru/help/security/ispolzovanie-iptables-na-linux)  

**fail2ban**  
Сам пакет ставится из репозитория Ubuntu. Много полезной информации можно получить из «встроенной» документации:  
`man 5 jail.conf`  
`fail2ban-client -h`  
*Информация в Интернете:*  
<https://www.digitalocean.com/community/tutorials/how-to-protect-ssh-with-fail2ban-on-ubuntu-20-04>  
<https://www.rosehosting.com/blog/how-to-install-and-configure-fail2ban-on-ubuntu-20-04/>  
<https://linuxize.com/post/install-configure-fail2ban-on-ubuntu-20-04/>  

**Включение TCP в «иксах»**  
*Настройка разных Display Manager'ов:*  
[Enabling Remote X Connections (updated)](https://lanforge.wordpress.com/2018/03/30/enabling-remote-x-connections/)  

*Гид по настройкам LightDM:*  
<https://wiki.ubuntu.com/LightDM>  
<https://wiki.debian.org/LightDM>  

**Документация по синтаксису Dockerfile:**  
[Dockerfile reference](https://docs.docker.com/engine/reference/builder/)  

**[Докер-тома](https://docs.docker.com/storage/volumes/)**  

**Docker root-mode и rootless-mode**  
[Run the Docker daemon as a non-root user (Rootless mode)](https://docs.docker.com/engine/security/rootless/)  
[Isolate containers with a user namespace](https://docs.docker.com/engine/security/userns-remap/)  

**[Как установить или изменить часовой пояс в Linux](https://routerus.com/how-to-set-or-change-timezone-in-linux/)**  

**Поиск пакетов**  
[Поиск пакетов Ubuntu](https://packages.ubuntu.com/)   
[Поиск пакетов Debian](https://www.debian.org/distrib/packages)  

----------------------------------------------------------------------------------

**`socat` и Xwayland**  
[How to make X.org listen to remote connections on port 6000?](https://askubuntu.com/questions/34657/how-to-make-x-org-listen-to-remote-connections-on-port-6000) — про «связку» `socat` с юникс-сокетом «иксов»  
[How to access X over TCP IP network](https://github.com/mviereck/x11docker/wiki/How-to-access-X-over-TCP-IP-network) — здесь про `xhost` и `socat`, и здесь же инструкция по созданию "trusted cookie" для использования внутри Docker-контейнера.  

[Сайт](http://www.dest-unreach.org/socat/) проекта `socat`
и [документация](http://www.dest-unreach.org/socat/doc/) по его использованию.  

*Как «деймонизировать» `socat` (и не только его):*  
[creating-a-linux-service-with-systemd](https://medium.com/@benmorel/creating-a-linux-service-with-systemd-611b5c8b91d6)  

Инструкцию по созданию "untrusted cookie" можно найти на [этой странице](https://github.com/mviereck/x11docker/wiki/X-authentication-with-cookies-and-xhost-(%22No-protocol-specified%22-error))  
*Ещё про "trusted" и "untrusted cookie" можно почитать в «мане»:*  
`man 1 xauth`  

----------------------------------------------------------------------------------

**Проблема с `MIT-SHM`**  
[MIT-SHM error solutions](https://github.com/jessfraz/dockerfiles/issues/359).  
[Исходный код «патча» `XlibNoSHM.so`](https://github.com/mviereck/dockerfile-x11docker-xserver/blob/main/XlibNoSHM.c)  
Еще про опцию `--ipc` можно почитать тут: [Sharing Memory across Docker containers](https://stackoverflow.com/questions/56878405/sharing-memory-across-docker-containers-ipc-host-vs-ipc-shareable)

**Проекты Jess Frazelle**  
Тот самый пост от 21 февраля 2015: [Docker Containers on the Desktop](https://blog.jessfraz.com/post/docker-containers-on-the-desktop/)  
[github.com/jessfraz/dockerfiles](https://github.com/jessfraz/dockerfiles)  
[hub.docker.com/u/jess](https://hub.docker.com/u/jess/)  

----------------------------------------------------------------------------------

[**x11docker**](https://github.com/mviereck/x11docker)  
[Dockerfile: X servers in container for use with x11docker](https://github.com/mviereck/dockerfile-x11docker-xserver/tree/main)  
[x11docker — wiki](https://github.com/mviereck/x11docker/wiki)  

[**Can you run GUI applications in a Linux Docker container?**](https://stackoverflow.com/questions/16296753/can-you-run-gui-applications-in-a-linux-docker-container/39681017)  
Это — еще один целый большой разбор по запуску GUI-приложенийв Docker-контейнерах в ОС GNU/Linux **и не только!**  
Среди прочих вариантов тут предложен [скрипт  `Xephyrdocker`](https://stackoverflow.com/questions/16296753/can-you-run-gui-applications-in-a-linux-docker-container/39681017#39681017). Именно с этого скрипта судя по всему и начался проект `x11docker`.  

----------------------------------------------------------------------------------

**systemd**  
*Про опции `systemd-run` можно прочитать в этих «манях»:*  
`man 1 systemd-run`  
`man 1 systemctl раздел set-property`  
`man 5 systemd.resource-control`  

*Введение в основы systemd:* [systemd — archlinux.org](https://wiki.archlinux.org/title/Systemd_(%D0%A0%D1%83%D1%81%D1%81%D0%BA%D0%B8%D0%B9))  

*Контейнеризация процессов при помощи настраиваемых окружений:*  
`man 5 systemd.exec`  
`man 7 capabilities`  
[Capabilities](https://man7.org/linux/man-pages/man7/capabilities.7.html)  
[Linux namespaces](https://en.wikipedia.org/wiki/Linux_namespaces)  
[Cgroups](https://wiki.archlinux.org/title/Control_groups)  

