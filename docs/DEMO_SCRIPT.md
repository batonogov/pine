# Pine Demo Script

Сценарий записи 30-60 секундного демо-видео для README и маркетинговых материалов.

## Формат

- **Длительность:** 30-60 секунд
- **Разрешение:** 1920x1080 или 2560x1440 (Retina)
- **GIF:** 960px ширина, 15 FPS, до 10 MB
- **MP4:** для YouTube/соцсетей, полное качество

## Подготовка

1. Чистая установка Pine (без открытых проектов)
2. Демо-проект с файлами на Swift, Python, JavaScript
3. Git-репозиторий с двумя ветками для демонстрации branch switching
4. Тёмная тема macOS (лучше контраст для демо)
5. Скрыть Desktop, Dock на auto-hide, убрать лишние приложения

## Сцены

### Scene 1: Launch and Open Project (5 sec)

- Запуск Pine — показать быстрый cold start
- Welcome window с Recent Projects
- Открытие проекта через Cmd+Shift+O
- **Акцент:** скорость запуска, Liquid Glass UI

### Scene 2: File Tree Navigation (5 sec)

- Раскрыть папку `src/` в sidebar
- Кликнуть по нескольким файлам
- Показать переключение между табами
- **Акцент:** отзывчивость, плавные переходы

### Scene 3: Syntax Highlighting (10 sec)

- Открыть `App.swift` — Swift highlighting
- Quick Open (Cmd+P) → `server.py` — Python highlighting
- Quick Open (Cmd+P) → `index.js` — JavaScript highlighting
- **Акцент:** точная подсветка, разные языки, быстрый Quick Open

### Scene 4: Integrated Terminal (5 sec)

- Toggle terminal (Cmd+`)
- Запустить команду: `echo 'Hello from Pine Terminal!'`
- Показать split view (editor + terminal)
- **Акцент:** полноценный терминал, не нужно переключаться

### Scene 5: Symbol Navigation (5 sec)

- Вернуться к `App.swift`
- Показать symbol navigation для быстрого перехода к функциям/классам
- **Акцент:** навигация по коду без скролла

### Scene 6: Git Integration (5 sec)

- Branch switching (Cmd+Shift+B)
- Поиск ветки `feature/demo`
- Переключение — показать изменение статуса
- **Акцент:** git прямо в редакторе

### Scene 7: Navigation Features (5 sec)

- Go to Line (Cmd+L) → строка 10
- Find in file (Cmd+F) → поиск `counter`
- Подсветка совпадений
- **Акцент:** быстрая навигация

### Scene 8: Closing Shot (5 sec)

- Общий вид редактора с minimap
- Медленный скролл для показа minimap в действии
- **Акцент:** общее впечатление, polish

## Автоматизация

Скрипт `scripts/record-demo.sh` автоматизирует весь процесс:

```bash
# Полная запись + конвертация
./scripts/record-demo.sh

# Только конвертация существующего видео в GIF
./scripts/record-demo.sh --gif-only

# Указать выходную директорию
./scripts/record-demo.sh --output ./assets
```

### Требования

- `ffmpeg` — запись и конвертация видео
- `cliclick` — автоматизация кликов и ввода
- `gifski` (опционально) — более качественная конвертация в GIF

```bash
brew install ffmpeg cliclick gifski
```

## Ручная запись (альтернатива)

Если автоматизация не работает стабильно:

1. Открыть QuickTime Player → File → New Screen Recording
2. Выбрать область записи (окно Pine)
3. Выполнить сценарий вручную, следуя порядку сцен
4. Остановить запись
5. Конвертировать:

```bash
# Через ffmpeg
ffmpeg -i recording.mov -vf "fps=15,scale=960:-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse" pine-demo.gif

# Через gifski (лучше качество)
ffmpeg -i recording.mov -vf "fps=15,scale=960:-1" /tmp/frames/frame%04d.png
gifski --fps 15 --width 960 -o pine-demo.gif /tmp/frames/frame*.png
```

## Размещение

- GIF: `assets/pine-demo.gif` — встраивается в README
- MP4: GitHub Release или YouTube — ссылка в README
- README embed: `![Pine Demo](assets/pine-demo.gif)`
