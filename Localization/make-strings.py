#!/usr/bin/env python3
"""Собирает переводы Usin в Usin/Localization/<язык>.lproj и проверяет, что ничего не потеряно.

Одна система на всё приложение: язык — один (Настройки → Основные → Язык), ключ — русский текст,
переводы лежат здесь, по папке на таблицу:
  app/   → App.strings          — холст, заметки, настройки (функция L() в Usin)
  tools/ → Localizable.strings  — инструменты Mac (L() и строки-литералы SwiftUI в UsinTools)
В каждой папке keys.json — ключи, source/<язык>.txt — по строке перевода на ключ, в том же порядке.
Русский — сам ключ, поэтому для него таблицы пустые.

Запуск после правки: python3 Localization/make-strings.py
"""
import json, re, sys, pathlib

here = pathlib.Path(__file__).resolve().parent
out = here.parent / "Usin" / "Localization"
tables = {"app": "App", "tools": "Localizable"}
spec = re.compile(r"%(?:lld|@|%)")
esc = lambda s: s.replace("\\", "\\\\").replace('"', '\\"')

failed = False
languages = None
for folder, table in tables.items():
    root = here / folder
    keys = json.load(open(root / "keys.json", encoding="utf-8"))
    if len(set(keys)) != len(keys):
        print(f"{folder}/keys.json: есть повторяющиеся ключи"); failed = True
    sources = sorted((root / "source").glob("*.txt"))
    names = {src.stem for src in sources}
    if languages is None:
        languages = names
    elif names != languages:
        print(f"{folder}: языки {sorted(names)}, а должны быть {sorted(languages)}"); failed = True
    for src in sources:
        lines = src.read_text(encoding="utf-8").splitlines()
        if len(lines) != len(keys):
            print(f"{folder}/{src.name}: {len(lines)} строк вместо {len(keys)}"); failed = True; continue
        for i, (k, v) in enumerate(zip(keys, lines)):
            if not v.strip():
                print(f"{folder}/{src.name}:{i+1}: пустой перевод для {k!r}"); failed = True
            if sorted(spec.findall(k)) != sorted(spec.findall(v)):
                print(f"{folder}/{src.name}:{i+1}: не совпали подстановки: {k!r} / {v!r}"); failed = True
        d = out / f"{src.stem}.lproj"
        d.mkdir(parents=True, exist_ok=True)
        (d / f"{table}.strings").write_text("".join(f'"{esc(k)}" = "{esc(v)}";\n' for k, v in zip(keys, lines)), encoding="utf-8")
    ru = out / "ru.lproj"
    ru.mkdir(parents=True, exist_ok=True)
    (ru / f"{table}.strings").write_text("", encoding="utf-8")

sys.exit(1 if failed else 0)
