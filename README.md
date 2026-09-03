# Daily Assistant — tester releases

Этот приватный репозиторий содержит только launcher. Готовые Windows x64
сборки находятся в GitHub Releases и устанавливаются автоматически.

## Клиент

1. Установите Git for Windows и клонируйте этот приватный репозиторий.
2. Запускайте `start.bat` двойным кликом.

```powershell
git clone https://github.com/grouzdev/daily-assistant-releases.git
```

Launcher проверяет latest stable release, проверяет SHA-256, обновляет приложение
и открывает `http://127.0.0.1:5722`. При отсутствии сети запускается последняя
установленная версия. Node.js, npm, Docker, исходники и `node_modules` не нужны.

Codex опционален. Без установленного и авторизованного `codex.exe` работает всё,
кроме панели ассистента.

Локальные данные сохраняются независимо от версий приложения:

```text
%LOCALAPPDATA%\DailyAssistant
```

## Опциональный sync-server

На одном назначенном тестовом компьютере запустите `start-sync-server.bat`.
Server хранит данные в `%LOCALAPPDATA%\DailyAssistant\server`, слушает TCP 45679
и показывает owner setup code. Остальные клиенты подключаются к LAN-адресу этого
компьютера через настройки приложения.

Для LAN-доступа один раз выполните PowerShell от администратора:

```powershell
New-NetFirewallRule -DisplayName 'Daily Assistant Sync' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 45679 -Profile Private
```

Не открывайте порт в публичных сетях. Launcher не изменяет firewall автоматически.

## Диагностика

Установленные версии находятся в `.runtime`; хранятся две последние версии
каждого компонента. Логи с ротацией находятся в `%LOCALAPPDATA%\DailyAssistant\logs`
и `%LOCALAPPDATA%\DailyAssistant\server\logs`. Перед обновлением клиент создаёт
JSON backup, а server — закрытую копию SQLite. GitHub credential берётся у Git
Credential Manager только на время запроса и не записывается в файлы или логи.
