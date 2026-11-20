# ByeKnow MCP

Даёт ИИ-ассистентам (Claude Desktop, Claude Code и другим MCP-клиентам) доступ к заметкам ByeKnow — так же, как к Obsidian подключают папку с Markdown.

Как это устроено:

1. **ByeKnow (Mac)** держит в выбранной папке зеркало заметок: по файлу `.md` на заметку, подпапки — темы, стрелки между заметками — `[[ссылки]]` в шапке файла. Файлы обновляются через секунду после каждой правки.
2. **`byeknow-mcp`** — маленький MCP-сервер (stdio, без зависимостей), который читает эту папку.
3. Новые заметки от ИИ сервер кладёт в подпапку `inbox/`; открытое приложение ByeKnow за пару секунд превращает их в заметки на холсте и удаляет файл.

ИИ не может менять или удалять существующие заметки — только читать их и создавать новые.

## 1. Включить экспорт в ByeKnow

Настройки → **ИИ-ассистенты** → «Заметки в папке Markdown» → выбрать папку (например `~/ByeKnow Notes`).

Файлы в папке перезаписываются из приложения — править их руками бессмысленно (правки пропадут). Чтобы добавить заметку из файла, положи `.md` в `inbox/`.

## 2. Собрать сервер

```bash
cd mcp-server
swift build -c release
```

Готовая программа: `mcp-server/.build/release/byeknow-mcp`. Её можно скопировать куда удобно, например в `~/.local/bin/`.

Папка с заметками передаётся аргументом `--folder <путь>` (или переменной окружения `BYEKNOW_NOTES_DIR`).

## 3. Подключить к ИИ

### Claude Desktop

Открой `~/Library/Application Support/Claude/claude_desktop_config.json` (Claude → Settings → Developer → Edit Config) и добавь сервер в `mcpServers` — пример в [`claude_desktop_config.example.json`](claude_desktop_config.example.json):

```json
{
  "mcpServers": {
    "byeknow": {
      "command": "/Users/ИМЯ/Documents/ByeKnow/mcp-server/.build/release/byeknow-mcp",
      "args": ["--folder", "/Users/ИМЯ/ByeKnow Notes"]
    }
  }
}
```

Пути — полные, без `~`. Перезапусти Claude Desktop.

### Claude Code

```bash
claude mcp add byeknow --scope user -- "$PWD/.build/release/byeknow-mcp" --folder "$HOME/ByeKnow Notes"
```

## Инструменты

| Инструмент | Что делает |
| --- | --- |
| `list_themes` | Темы и сколько в каждой заметок |
| `list_notes` | Список заметок (новые сверху), фильтр по теме |
| `search_notes` | Поиск по названию и тексту, с отрывками |
| `read_note` | Полный текст заметки по пути, названию, `[[ссылке]]` или id |
| `create_note` | Новая заметка: название, текст в Markdown, тема, цвет, стрелки к другим заметкам |

## Формат файла

```markdown
---
id: 6F1C…
title: "План запуска"
theme: "Работа"
color: blue
shape: card
created: 2026-11-18T10:00:00Z
links_to: ["[[Идеи]]"]
linked_from: ["[[Встреча с Аней]]"]
---

# План запуска

## Этапы

- [x] Сделать холст
- [ ] Подключить MCP

[Лендинг](https://example.com)
```

Блоки заметки: текст — абзац, заголовок — `##`, чек-лист — `- [ ]` / `- [x]`, разделитель — `---`, ссылка — `[текст](url)`, картинка — файл в `attachments/`.

Файл для `inbox/` пишется так же; обязательно только название (`title:` в шапке, первая строка `# …` или имя файла). Цвета: `default red orange yellow green teal blue purple pink`. `links_to` — названия существующих заметок.

## Проверка

```bash
npx @modelcontextprotocol/inspector .build/release/byeknow-mcp --folder "$HOME/ByeKnow Notes"
```

Или без Node — одной командой:

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_themes","arguments":{}}}' | .build/release/byeknow-mcp --folder "$HOME/ByeKnow Notes"
```
