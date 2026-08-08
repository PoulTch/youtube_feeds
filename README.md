# MyChannels — Personal YouTube Aggregator / Персональный YouTube-Агрегатор

<p align="center">
  <a href="#-english-version">🇬🇧 English Version</a> • 
  <a href="#-русская-версия">🇷🇺 Русская Версия</a>
</p>

---

## 🇬🇧 English Version

A lightweight, ultra-fast Self-Hosted Ruby on Rails 8 application designed to aggregate your favorite YouTube channels via the official API without ads, tracking, or algorithmic recommendations.

### 🚀 Key Features
- **Billion-Proof Deep Sync:** Imports full video archives of any depth using the official Google YouTube Data API v3.
- **Smart Tabs:** Automatically separates videos, shorts (under 180s), and live streams based on `liveStreamingDetails`.
- **Advanced Playlist UX:** Deep syncs playlists using `nextPageToken` with sequential numbers and dynamic status loader.
- **Two-Speed Quota Strategy:** Runs hourly updates for hot new videos while updating older archives safely once a day.
- **No-F5 Interactive UI:** Features a blurred full-screen synchronization overlay during CSV imports with native browser cache busting.
- **Blazing Fast:** High-performance `Pagy` pagination for all content grids with custom YouTube-styled `series_nav`.

### 🛠️ System Stack & Dependencies
- **Ruby:** 3.3+
- **Framework:** Rails 8.0+
- **Database:** PostgreSQL
- **Background Worker:** Solid Queue (built-in Rails 8 database-backed queue)
- **Scheduler:** Solid Queue Recurring Tasks (`config/recurring.yml`)

### 🔐 Environment Variables (`.env`)
To run this application safely, create a `.env` or `config/credentials.yml.enc` file and declare the following variables:
```env
# Official Google YouTube Data API v3 Key
YOUTUBE_API_KEY=your_actual_google_api_key_here

# Rails production secret key base for session encryption
SECRET_KEY_BASE=your_rails_secret_key_base_here

# Database credentials (if using non-default PostgreSQL setup)
DATABASE_URL=postgres://user:password@localhost/youtube_feeds_production
```

### 📦 VPS Deployment Checklist
To deploy the latest changes to your production server, execute these commands on your VPS terminal:
```bash
git pull origin main
bin/rails db:migrate RAILS_ENV=production
bin/rails assets:precompile RAILS_ENV=production
sudo systemctl restart rails-app.service
sudo systemctl restart rails-worker.service
```

---

## 🇷🇺 Русская Версия

Легковесный, мега-быстрый Self-Hosted медиа-комбайн на Rails 8 для комфортного отслеживания любимых YouTube-авторов без рекламы, алгоритмических рекомендаций и трекеров.

### 🚀 Ключевые возможности
- **Бронебойный импорт архивов:** Потоковая синхронизация каналов любой глубины через официальный Google YouTube API v3.
- **Умное раскидывание по вкладкам:** Четкое разделение на Видео, Shorts (до 3 минут) и Трансляции на основе метаданных `liveStreamingDetails`.
- **Интерактивные плейлисты:** Выкачивание списков воспроизведения на всю глубину (через `nextPageToken`) с нумерацией и статусом прогресса загрузки.
- **Оптимизация квот (Стратегия двух скоростей):** Ежечасное обновление горячих новинок и бережное фоновое обновление старого архива порциями раз в сутки.
- **Элитный UX (Без ручного F5):** Полноэкранная завеса загрузки (блур + спиннер) при импорте подписок из CSV с автоматическим пробитием кэша браузера.
- **Космическая скорость:** Сверхбыстрая пагинация `Pagy` (с кастомным YouTube-дизайном кнопок `series_nav`) для всех типов контента.

### 🛠️ Технологический стек
- **Ruby:** 3.3+
- **Framework:** Rails 8.0+
- **База данных:** PostgreSQL
- **Фоновые задачи:** Solid Queue (встроенный в Rails 8 бэкенд воркеров)
- **Планировщик:** Solid Queue Recurring Tasks (`config/recurring.yml`)

### 🔐 Обязательные ENV-переменные
Для безопасной работы приложения создайте файл `.env` в корне проекта (или используйте credentials) и пропишите параметры (без реальных ключей в Git!):
```env
# Официальный API ключ Google YouTube Data v3
YOUTUBE_API_KEY=ваш_реальный_ключ_api_сюда

# Ключ шифрования сессий Rails для продакшена
SECRET_KEY_BASE=ваш_секретный_ключ_rails_сюда

# Параметры подключения к PostgreSQL (при необходимости)
DATABASE_URL=postgres://user:password@localhost/youtube_feeds_production
```

### 📦 Шпаргалка по деплою на боевой VPS
Для обновления приложения на сервере выполните в терминале VPS последовательно:
```bash
git pull origin main
bin/rails db:migrate RAILS_ENV=production
bin/rails assets:precompile RAILS_ENV=production
sudo systemctl restart rails-app.service
sudo systemctl restart rails-worker.service
```
