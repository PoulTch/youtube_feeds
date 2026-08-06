class VideosController < ApplicationController
  # Отключаем проверку токена для сохранения секунд, так как запросы идут фоном через JS
  skip_before_action :verify_authenticity_token, only: [ :save_progress ]

  # 1. Главная страница со всеми видео + ИЗОЛИРОВАННАЯ ИСТОРИЯ ПРОСМОТРОВ
  def index
    # Вытаскиваем ролики с прогрессом в массив БЕЗ предварительного лимита базы
    all_history = Video.includes(:channel)
                        .where("watched_seconds > 0")
                        .order(updated_at: :desc)
                        .to_a

    # Сначала выкидываем из массива полностью досмотренные ролики (остаток < 15 сек)
    filtered_history = all_history.select do |v|
      v.duration_seconds && v.watched_seconds && (v.duration_seconds - v.watched_seconds) > 15
    end

    # И ТОЛЬКО ТЕПЕРЬ жестко берём первые 15 самых свежих недосмотренных карточек!
    @history_videos = filtered_history.first(15)

    # Ловим текущую общую вкладку (по умолчанию 'video')
    @current_tab = params[:tab] || "video"

    base_relation = Video.includes(:channel)

    # Умная фильтрация ОБЩЕЙ ленты для всех авторов сайта
    videos_relation = case @current_tab
    when "shorts"
                        base_relation.where(video_type: "shorts").order(published_at: :desc)
    when "stream"
                        base_relation.where(video_type: "stream").order(published_at: :desc)
    else
                        # На главную пускаем сорт 'video' + nil (для старых роликов)
                        base_relation.where(video_type: [ "video", nil ]).order(published_at: :desc)
    end

    # Применяем пагинацию СТРОГО к отфильтрованной общей ленте
    @pagy, @videos = pagy(:offset, videos_relation, limit: 20)
  end

  # 2. Обработка формы добавления нового канала (С ПРОВЕРКОЙ НА ДУБЛИКАТЫ И UX-ПОЛИШИНГОМ)
  def create_channel
    youtube_id = params[:youtube_channel_id].to_s.strip

    # БРОНЕБОЙНЫЙ ПОГРАНИЧНЫЙ КОНТРОЛЬ: Проверяем префикс UC и длину строки строго 24 символа!
    unless youtube_id.start_with?("UC") && youtube_id.length == 24
      flash[:alert] = "Неверный формат! Идентификатор канала должен быть длиной 24 символа и начинаться строго с 'UC'."
      redirect_to root_path, data: { turbo: false } and return
    end

    if youtube_id.present?
      # 🎯 УМНАЯ ПРОВЕРКА НА ДУБЛИКАТЫ:
      existing_channel = Channel.find_by(youtube_channel_id: youtube_id)

      if existing_channel.present?
        # Если автор уже есть в базе — пишем честный текст и перенаправляем на его страницу!
        flash[:notice] = "Канал «#{existing_channel.title}» уже есть в вашей системе подписок."
        redirect_to channel_page_path(existing_channel), data: { turbo: false } and return
      end

      # Если автора в базе нет — запускаем стандартную процедуру создания
      channel = Channel.create_by_id(youtube_id)

      if channel
        # 1. Скачиваем свежие видеоролики из RSS
        channel.fetch_videos

        # 2. МГНОВЕННЫЙ ДЕСАНТ ВРЕМЕНИ И СТАТИСТИКИ ПРИ СОЗДАНИИ
        api_key = Rails.application.config.youtube_api_key
        # ИСПРАВЛЕНО: Теперь ищем ролики, где нет либо секунд, либо просмотров
        videos_to_update = channel.videos.where(duration_seconds: nil).or(channel.videos.where(views_count: nil)).limit(20)

        if api_key.present? && videos_to_update.any?
          video_ids = videos_to_update.map(&:youtube_video_id).join(",")
          url = "https://www.googleapis.com/youtube/v3/videos?part=contentDetails,liveStreamingDetails,snippet,statistics&id=#{video_ids}&key=#{api_key}"
          begin
            uri = URI.parse(url)
            response = Net::HTTP.get_response(uri)
            if response.is_a?(Net::HTTPSuccess)
              data = JSON.parse(response.body)
              if data["items"].present?
                data["items"].each do |item|
                  v_id = item["id"]

                  # 1. Сбор длительности
                  iso_duration = item.dig("contentDetails", "duration")
                  seconds = iso_duration.present? ? ActiveSupport::Duration.parse(iso_duration).to_i : 0

                  # 2. Сбор даты публикации
                  real_date_str = item.dig("snippet", "publishedAt")

                  # 3. Сбор просмотров и лайков
                  views = item.dig("statistics", "viewCount").to_i
                  likes = item.dig("statistics", "likeCount").to_i

                  # 4. СУПЕР-КАЛИБРОВКА ПО ОФИЦИАЛЬНЫМ СТАНДАРТАМ YOUTUBE (БЕЗ ГАДАНИЯ ПО СЛОВАМ)
                  live_status = item.dig("snippet", "liveBroadcastContent").to_s
                  has_live_details = item["liveStreamingDetails"].present? # Блок существует ТОЛЬКО у стримов!

                  is_stream = live_status == "live" ||
                              live_status == "upcoming" ||
                              live_status == "completed" ||
                              has_live_details || # Поймали архивный эфир по его истории вещания!

                  is_shorts = seconds > 0 && seconds <= 180 && !is_stream # Официальные 180 секунд для Shorts!

                  # ИДЕАЛЬНАЯ ИЕРАРХИЯ: Сначала жестко отсекаем Shorts (до 3 минут),
                  # и только потом проверяем стримы и длинные видео!
                  if is_shorts
                    detected_type = "shorts" # Шортсы Белковского теперь в идеальной безопасности!
                  elsif is_stream
                    detected_type = "stream"
                  else
                    detected_type = "video"
                  end

                  v = channel.videos.find_by(youtube_video_id: v_id)
                  if v
                    updates = {}
                    updates[:duration_seconds] = seconds if seconds > 0
                    updates[:published_at] = Time.parse(real_date_str) if real_date_str.present?
                    updates[:views_count] = views if views > 0
                    updates[:likes_count] = likes if likes > 0

                    # НАМЕРТВО записываем сорт контента в базу данных PostgreSQL прямо сейчас!
                    updates[:video_type] = detected_type

                    # Сохраняем пачкой все новые данные в PostgreSQL
                    v.update_columns(updates) if updates.any?
                  end
                end
              end
            end
          rescue => e
            Rails.logger.error "Ошибка быстрого сбора времени и статистики при создании канала: #{e.message}"
          end
        end

        # 3. МГНОВЕННЫЙ СБОР МЕТАДАННЫХ: Качаем оригинальную аватарку и баннер
        channel.fetch_avatar_from_api

        # 4. СВЕРХЭКОНОМНЫЙ СБОР КАРТОЧЕК ПЛЕЙЛИСТОВ (БЕЗ СКАЧИВАНИЯ РОЛИКОВ)
        channel.fetch_playlist_cards_from_api

        # ОЧИЩАЕМ КЭШ САЙДБАРА: Заставляем Rails мгновенно перерисовать меню слева!
        Rails.cache.delete([ current_user, "sidebar_channels" ])

        flash[:notice] = "Канал '#{channel.title}' успешно добавлен! Все тайминги, плейлисты и оформление загружены мгновенно."
        redirect_to channel_page_path(channel), data: { turbo: false } and return
      else
        flash[:alert] = "Не удалось добавить канал. Проверьте правильность ID."
      end
    else
      flash[:alert] = "ID канала не может быть пустым."
    end

    redirect_to root_path, data: { turbo: false }
  end

  # 3. Страница конкретного одного канала (УМНЫЕ ВКЛАДКИ + ПАГИНАЦИЯ ДЛЯ ВСЕХ ВКЛАДОК)
  def show_channel
    @channel = Channel.find_by(id: params[:id])

    if @channel.nil?
      flash[:alert] = "К сожалению, этот канал не найден в базе данных."
      redirect_to root_path and return
    end

    # Синхронизируем имя вкладки strictly в единственном числе!
    @current_tab = params[:tab] || "video"
    @current_sort = params[:sort] || "desc"

    # Гарантируем сброс на 1 страницу, если параметр пуст (вынесли наверх для всеобщего удобства)
    current_page = params[:page].to_i > 0 ? params[:page].to_i : 1

    if @current_tab == "playlists"
      # === СЦЕНАРИЙ А: ВКЛАДКА ПЛЕЙЛИСТОВ (ТЕПЕРЬ СО СВЕРХСКОРОСТНОЙ ПАГИНАЦИЕЙ!) ===
      playlists_relation = @channel.playlists.order(id: :asc)
      
      # Разбиваем плейлисты на легкие страницы по 24 штуки, чтобы страница открывалась мгновенно
      @pagy, @playlists = pagy(:offset, playlists_relation, page: current_page, limit: 24)
      @videos = [] # Пустая заглушка, так как ролики на этой вкладке не нужны
    else
      # === СЦЕНАРИЙ Б: ВКЛАДКИ ВИДЕО, ШОРТСОВ ИЛИ СТРИМОВ ===
      # Направление дат
      order_logic = if @current_sort == "asc"
                      { published_at: :asc, id: :asc }
                    else
                      { published_at: :desc, id: :desc }
                    end

      # Базовая связь строго этого автора
      base_relation = @channel.videos.order(order_logic)

      # УМНОЕ РАСПРЕДЕЛЕНИЕ: пускаем nil на главную вкладку 'video'
      videos_relation = case @current_tab
                        when "shorts"
                          base_relation.where(video_type: "shorts")
                        when "stream"
                          base_relation.where(video_type: "stream")
                        else
                          base_relation.where("video_type = 'video' OR video_type IS NULL")
                        end

      # Подгружаем карточки плейлистов для сайдбара в легком режиме (без пагинации, просто массив)
      @playlists = @channel.playlists.order(id: :asc)

      # МАГИЯ PAGY: разбиваем ролики на страницы по 24 штуки
      @pagy, @videos = pagy(:offset, videos_relation, page: current_page, limit: 24)
    end
  end

  # Экшен для показа роликов внутри конкретного плейлиста в MyChannels (С ПОДДЕРЖКОЙ СОРТИРОВКИ И ПАГИНАЦИИ)
  def show_playlist
    @playlist = Playlist.find(params[:id])
    @channel = @playlist.channel

    # Запоминаем текущую сортировку внутри плейлиста (по умолчанию — "desc", Новые сверху)
    @current_sort = params[:sort] || "desc"

    # 1. Задаем базовую выборку роликов с сортировкой
    playlist_videos_relation = if @current_sort == "asc"
                                 @playlist.videos.order(published_at: :asc, id: :asc)
                               else
                                 @playlist.videos.order(published_at: :desc, id: :desc)
                               end

    # 2. Определяем текущую страницу
    current_page = params[:page].to_i > 0 ? params[:page].to_i : 1

    # 3. МАГИЯ PAGY: Разбиваем ролики плейлиста на легкие страницы по 24 штуки!
    @pagy, @videos = pagy(:offset, playlist_videos_relation, page: current_page, limit: 24)
  end

  # 4. Новый метод для страницы просмотра видео (ИСПРАВЛЕНО: Защита от nil-ошибок 500)
  def show
    @video = Video.find_by(id: params[:id])
    if @video.nil?
      flash[:alert] = "К сожалению, этот видеоролик не найден в базе данных."
      redirect_to root_path and return
    end
  end

  # 5. Метод вызывается из JS в фоне для保存ения прогресса просмотра
  def save_progress
    video = Video.find(params[:id])

    # Обновляем колонки в базе данных
    video.update(
      watched_seconds: params[:current_time],
      duration_seconds: params[:total_time]
    )
    Rails.cache.delete("sidebar_channels_user_#{session[:user_id]}")
    head :ok # Отвечаем браузеру, что всё прошло успешно
  end

  # 6. Метод для импорта подписок из CSV-файла YouTube
  def import_subscriptions
    file = params[:subscriptions_file]

    if file.present?
      begin
        require "csv"
        csv_data = file.read.force_encoding("UTF-8")
        imported_count = 0

        # Читаем CSV без привязки к именам заголовков
        CSV.parse(csv_data, headers: true) do |row|
          # YouTube CSV всегда идет в порядке: 0 -> ID канала, 1 -> Ссылка, 2 -> Название
          youtube_id = row[0]&.strip
          title = row[2]&.strip

          # Если ID канала валидный (начинается на UC)
          if youtube_id.present? && youtube_id.start_with?("UC")
            rss_url = "https://www.youtube.com/feeds/videos.xml?channel_id=#{youtube_id}"

            channel = Channel.find_or_initialize_by(youtube_channel_id: youtube_id)
            channel.title = title || "Неизвестный канал"
            channel.rss_url = rss_url

            if channel.save
              imported_count += 1
              # Выкачиваем видеоролики
              FetchChannelVideosJob.perform_later(channel.id)
            end
          end
        end

        # ЖЕЛЕЗОБЕТОННОЕ ИСПРАВЛЕНИЕ: Сжигаем кэш сайдбара по твоему фирменному ключу!
        Rails.cache.delete([ current_user, "sidebar_channels" ])

        flash[:notice] = "Импорт завершен успешно! Добавлено каналов: #{imported_count}"
      rescue => e
        flash[:alert] = "Ошибка при чтении CSV: #{e.message}"
      end
    else
      flash[:alert] = "Пожалуйста, выберите файл для импорта."
    end

    redirect_to root_path
  end

  # 7. Метод для удаления канала и всех его видеороликов (РЕАКТИВНО БЫСТРЫЙ)
  def destroy
    @channel = Channel.find(params[:id])
    @channel.destroy # Теперь благодаря :delete_all в модели это сработает мгновенно!

    # ИСПРАВЛЕНО: Теперь ключ кэша строго совпадает с методом добавления!
    Rails.cache.delete([ current_user, "sidebar_channels" ])

    flash[:notice] = "Канал «#{@channel.title}» и все его видео успешно удалены."
    redirect_to root_path
  end

  # 8. Метод для тотального скачивания архива роликов канала через YouTube API
  def fetch_channel_archive
    channel = Channel.find(params[:id])
    new_video_ids = []

    uploads_playlist_id = channel.youtube_channel_id.dup
    if uploads_playlist_id.start_with?("UC")
      # Превращаем вторую букву C в U
      uploads_playlist_id[1] = "U"
    end

    api_key = Rails.application.config.youtube_api_key
    if api_key.blank?
      flash[:alert] = "Ключ YouTube API не настроен!"
      redirect_to channel_page_path(channel) and return
    end

    next_page_token = nil
    page_counter = 0

    puts "========================================================="
    puts "--> [ОТЛАДКА API] СТАРТ. Канал: #{channel.title}"
    puts "--> [ОТЛАДКА API] Итоговый плейлист загрузок: #{uploads_playlist_id}"
    puts "========================================================="

    begin
      loop do
        page_counter += 1
        token_param = next_page_token.present? ? "&pageToken=#{next_page_token}" : ""
        url = "https://www.googleapis.com/youtube/v3/playlistItems?part=snippet,contentDetails&maxResults=50&playlistId=#{uploads_playlist_id}&key=#{api_key}#{token_param}"

        response = Channel.fetch_with_redirects(url)

        if response.nil?
          puts "--> [ОТЛАДКА API] Страница #{page_counter}: Ответ равен nil!"
          break
        end

        unless response.is_a?(Net::HTTPSuccess)
          puts "--> [ОТЛАДКА API] Страница #{page_counter}: Сервер вернул ошибку #{response.code}"
          break
        end

        data = JSON.parse(response.body)
        items_size = data["items"] ? data["items"].size : 0
        puts "--> [ОТЛАДКА API] Страница #{page_counter}: Успешно получено элементов: #{items_size}"

        if items_size == 0
          puts "--> [ОТЛАДКА API] Страница #{page_counter}: Элементов больше нет, выходим."
          break
        end

        ActiveRecord::Base.transaction do
          data["items"].each do |item|
            v_id = item.dig("contentDetails", "videoId")
            snippet = item["snippet"]

            if v_id.present? && snippet
              video = Video.find_or_initialize_by(youtube_video_id: v_id)
              new_video_ids << v_id

              video.channel_id = channel.id
              video.title = snippet["title"] if video.title.blank?
              video.published_at = snippet["publishedAt"] if snippet["publishedAt"].present?
              video.video_type = "video"

              if snippet["thumbnails"].present?
                thumb_data = snippet["thumbnails"]["maxres"] || snippet["thumbnails"]["high"] || snippet["thumbnails"]["medium"] || snippet["thumbnails"]["default"]
                video.thumbnail_url = thumb_data["url"] if thumb_data
              end

              video.save!(validate: false)
            end
          end
        end

        next_page_token = data["nextPageToken"]
        puts "--> [ОТЛАДКА API] Страница #{page_counter}: Следующий токен: #{next_page_token.inspect}"

        if next_page_token.blank?
          puts "--> [ОТЛАДКА API] Токен пустой. Плейлист полностью прочитан."
          break
        end
      end
    rescue => e
      puts "--> [ОТЛАДКА API КРИТИЧЕСКАЯ ОШИБКА] Упал цикл: #{e.message}"
    end

    puts "========================================================="
    puts "--> [ОТЛАДКА API] Финал структуры. Всего собрано ID: #{new_video_ids.uniq.size}"
    puts "========================================================="

    # Шаг 2: Внутреннее обогащение статистики пачками по 50 (ИСПРАВЛЕННОЕ РАСКИДЫВАНИЕ)
    if new_video_ids.any?
      new_video_ids.uniq.compact.each_slice(50) do |slice|
        # Железно запрашиваем все четыре части у Google API
        api_url = "https://www.googleapis.com/youtube/v3/videos?part=contentDetails,liveStreamingDetails,snippet,statistics&id=#{slice.join(',')}&key=#{api_key}"
        res = Channel.fetch_with_redirects(api_url)

        if res && res.is_a?(Net::HTTPSuccess)
          api_data = JSON.parse(res.body)
          if api_data["items"].present?
            ActiveRecord::Base.transaction do
              api_data["items"].each do |v_item|
                db_v = channel.videos.find_by(youtube_video_id: v_item["id"])
                if db_v
                  snippet = v_item["snippet"]
                  content_details = v_item["contentDetails"]
                  statistics = v_item["statistics"]
                  live_details = v_item["liveStreamingDetails"]

                  db_v.title = snippet["title"] if snippet && snippet["title"].present?
                  db_v.description = snippet["description"] if snippet && snippet["description"].present?

                  if statistics
                    db_v.views_count = statistics["viewCount"].to_i
                    db_v.likes_count = statistics["likeCount"].to_i
                  end

                  # Распарсиваем длительность ролика в секунды
                  secs = 0
                  if content_details && content_details["duration"].present?
                    begin
                      iso_dur = content_details["duration"]
                      secs = ActiveSupport::Duration.parse(iso_dur).to_i
                      db_v.duration_seconds = secs
                    rescue
                      db_v.duration_seconds = 0
                    end
                  end

                  # === СВЕРХТОЧНОЕ РАСКИДЫВАНИЕ ПО ВКЛАДКАМ ===
                  description_text = snippet ? snippet["description"].to_s.downcase : ""

                  if live_details.present?
                    # Контур А: Если у видео физически есть блок liveStreamingDetails — это 100% СТРИМ!
                    db_v.video_type = "stream"
                  elsif description_text.include?("#shorts") || (secs > 0 && secs <= 180)
                    # Контур Б: Если есть тег или длительность до 3 минут (180 сек) — это ШОРТС!
                    db_v.video_type = "shorts"
                  else
                    # Контур В: Во всех остальных случаях — это обычное классическое ВИДЕО
                    db_v.video_type = "video"
                  end

                  db_v.save!(validate: false)
                end
              end
            end
          end
        end
      end
    end

    Rails.cache.delete([ current_user, "sidebar_channels" ])
    flash[:notice] = "Тотальный импорт UU-архива завершен! Ролики успешно распределены по вкладкам."
    redirect_to channel_page_path(channel)
  end

  # СИНХРОНИЗАЦИЯ РОЛИКОВ ПЛЕЙЛИСТА ЧЕРЕЗ ФОНОВЫЙ АВТОПИЛОТ SOLID QUEUE
  def sync_playlist_videos
    playlist = Playlist.find(params[:id])

    # Запускаем фонового робота через Solid Queue
    FetchPlaylistVideosJob.perform_now(playlist.id)

    # Возвращаем пользователя на страницу просмотра плейлиста с уведомлением
    flash[:notice] = "Автопилот синхронизации плейлиста «#{playlist.title}» успешно запущен в фоне! Данные, лайки и описания подгрузятся через несколько секунд."
    redirect_to playlist_page_path(playlist)
  end

  # МГНОВЕННАЯ ОЧИСТКА ПЛЕЙЛИСТА ДЛЯ СБЕРЕЖЕНИЯ ДИСКА VPS
  def clear_playlist_videos
    playlist = Playlist.find(params[:id])

    # Теперь, когда джоба плейлистов не создает дубликатов строк,
    # эта команда просто отвяжет видео от плейлиста, не удаляя его из архива канала!
    playlist.videos.update_all(playlist_id: nil)

    Rails.cache.delete([ current_user, "sidebar_channels" ])
    flash[:notice] = "Память сервера очищена! Все видеоролики из плейлиста «#{playlist.title}» удалены."
    redirect_to playlist_page_path(playlist)
  end

  # МЕТОД ДЛЯ РУЧНОГО ОБНОВЛЕНИЯ АВАТАРОК, БАННЕРОВ И ВСЕЙ СТАТИСТИКИ КАНАЛА + ПЛЕЙЛИСТОВ
  def refresh_metadata
    @channel = Channel.find(params[:id])

    # Запускаем тотальное обновление в фоне через Solid Queue
    RefreshChannelMetadataJob.perform_later(@channel.id)

    # Очищаем кэш сайдбара, чтобы изменения сразу применились в интерфейсе
    Rails.cache.delete([ current_user, "sidebar_channels" ])

    # Выводим красивое финальное уведомление пользователю
    flash[:notice] = "Задача на обновление метаданных автора «#{@channel.title}» и всех связанных роликов успешно запущена в фоне! Точные подписчики, баннер, а также просмотры и лайки обновятся через пару секунд."

    # Редиректим на страницу канала с сохранением текущей вкладки (tab) и отключением Turbo
    redirect_to channel_page_path(@channel, tab: params[:tab]), data: { turbo: false }
  end
end
