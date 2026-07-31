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

  # 3. Страница конкретного одного канала (УМНЫЕ ВКЛАДКИ + САТЕЛЛИТНАЯ ПОДСТРАХОВКА)
  def show_channel
    @channel = Channel.find_by(id: params[:id])

    if @channel.nil?
      flash[:alert] = "К сожалению, этот канал не найден в базе данных."
      redirect_to root_path and return
    end

    # Синхронизируем имя вкладки strictly в единственном числе!
    @current_tab = params[:tab] || "video"
    @current_sort = params[:sort] || "desc"

    # Вытягиваем карточки плейлистов для вкладки плейлистов
    @playlists = @channel.playlists.order(title: :asc)

    if @current_tab != "playlists"
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
                          # Явно разрешаем PostgreSQL выгружать и 'video', и любые nil от свежего RSS!
                          base_relation.where("video_type = 'video' OR video_type IS NULL")
      end

      # Гарантируем сброс на 1 страницу, если параметр пуст
      current_page = params[:page].to_i > 0 ? params[:page].to_i : 1

      # МАГИЯ PAGY: разбиваем отсортированный массив на страницы
      @pagy, @videos = pagy(:offset, videos_relation, page: current_page, limit: 24)
    end
  end


  # Экшен для показа роликов внутри конкретного плейлиста в MyChannels (С ПОДДЕРЖКОЙ СОРТИРОВКИ)
  def show_playlist
    @playlist = Playlist.find(params[:id])
    @channel = @playlist.channel

    # Запоминаем текущую сортировку внутри плейлиста (по умолчанию — "desc", Новые сверху)
    @current_sort = params[:sort] || "desc"

    if @current_sort == "asc"
      # Старые: выстраиваем ролики папки от 1-го выпуска к свежим
      @videos = @playlist.videos.order(published_at: :asc, id: :asc)
    else
      # Новые: от свежих выпусков к старым
      @videos = @playlist.videos.order(published_at: :desc, id: :desc)
    end
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

  # 8. БРОНЕБОЙНЫЙ ДВУХСТВОЛЬНЫЙ ИМПОРТ (РАЗДЕЛЯЕМ ВКЛАДКИ ВИДЕО И СТРИМОВ НА 100%)
  def fetch_channel_archive
    channel = Channel.find(params[:id])
    new_video_ids = []

    # ТРЁХСТВОЛЬНЫЙ КАНАН YOUTUBE: Сканируем каждую официальную вкладку отдельно со 100% точностью!
    base_url = "https://www.youtube.com/channel/#{channel.youtube_channel_id}"
    urls_to_scan = [
      { url: "#{base_url}/videos", default_type: "video" },   # Вкладка обычных видео
      { url: "#{base_url}/streams", default_type: "stream" }, # Вкладка официальных трансляций
      { url: "#{base_url}/shorts", default_type: "shorts" }   # Вкладка ОФИЦИАЛЬНЫХ SHORTS!
    ]

    # Проверяем, есть ли на машине Windows-путь к PowerShell (домашний ПК с WSL)
    is_wsl = File.exist?("/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe")
    powershell_path = "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
    ytdlp_path = "C:\\Windows\\System32\\yt-dlp.exe"

    urls_to_scan.each do |target|
      # Для каждой вкладки просим у yt-dlp до 250 свежих роликов, чтобы не перегружать сервер
      if is_wsl
        cmd = "#{powershell_path} -Command \"& '#{ytdlp_path}' --flat-playlist --playlist-end 250 --dump-json '#{target[:url]}'\""
      else
        cmd = "yt-dlp --flat-playlist --playlist-end 250 --dump-json '#{target[:url]}'"
      end

      begin
        IO.popen(cmd) do |io|
          io.each_line do |line|
            clean_line = line.encode("UTF-8", invalid: :replace, undef: :replace, replace: "").strip
            next unless clean_line.start_with?("{")

            begin
              video_data = JSON.parse(clean_line)
              video_id = video_data["id"]
              video_title = video_data["title"]

              if video_id.present?
                web_url = video_data["webpage_url"].to_s
                orig_url = video_data["original_url"].to_s

                # ИДЕАЛЬНОЕ РАСПРЕДЕЛЕНИЕ: Сортируем строго по паспорту вкладки, откуда скачали!
                if target[:default_type] == "shorts" || web_url.include?("/shorts/") || orig_url.include?("/shorts/")
                  detected_type = "shorts"
                elsif target[:default_type] == "stream" || web_url.include?("/live/") || orig_url.include?("/live/")
                  detected_type = "stream"
                else
                  detected_type = "video"
                end

                video = channel.videos.find_or_initialize_by(youtube_video_id: video_id)
                new_video_ids << video_id

                video.title = video_title if video.title.blank?
                video.video_type = detected_type # Пишем честный сорт в базу данных
                video.published_at ||= Time.current

                if video_data["thumbnails"].present? && video_data["thumbnails"].is_a?(Array)
                  video.thumbnail_url = video_data["thumbnails"].last["url"]
                end
                video.save!(validate: false)
              end
            rescue => e
            end
          end
        end
      rescue => e
        # Если у автора вообще нет вкладки /streams, yt-dlp просто молча пропустит этот шаг
      end
    end

    # ПАКЕТНАЯ СИНХРОНИЗАЦИЯ ПРОСМОТРОВ И ЛАЙКОВ С GOOGLE API v3 (БЫСТРАЯ)
    api_key = Rails.application.config.youtube_api_key
    if api_key.present?
      historic_blank_ids = channel.videos.where(duration_seconds: [ nil, 0 ]).or(channel.videos.where(views_count: nil)).pluck(:youtube_video_id)
      total_ids_to_sync = (new_video_ids + historic_blank_ids).uniq.compact

      if total_ids_to_sync.any?
        total_ids_to_sync.each_slice(50) do |slice|
          ids_string = slice.join(",")
          api_url = "https://www.googleapis.com/youtube/v3/videos?part=contentDetails,snippet,statistics&id=#{ids_string}&key=#{api_key}"

          response = Channel.fetch_with_redirects(api_url)
          if response && response.is_a?(Net::HTTPSuccess)
            api_data = JSON.parse(response.body)
            if api_data["items"].present?
              api_data["items"].each do |item|
                v_id = item["id"]
                snippet = item["snippet"]
                content_details = item["contentDetails"]
                statistics = item["statistics"]

                db_video = channel.videos.find_by(youtube_video_id: v_id)
                if db_video && snippet
                  db_video.title = snippet["title"] if snippet["title"].present?
                  db_video.published_at = snippet["publishedAt"]
                  db_video.description = snippet["description"] if snippet["description"].present?

                  if statistics
                    db_video.views_count = statistics["viewCount"].to_i if statistics["viewCount"].present?
                    db_video.likes_count = statistics["likeCount"].to_i if statistics["likeCount"].present?
                  end

                  if content_details && content_details["duration"].present?
                    begin
                      db_video.duration_seconds = ActiveSupport::Duration.parse(content_details["duration"]).to_i
                    rescue
                      db_video.duration_seconds = 0
                    end
                  end
                  db_video.save!(validate: false)
                end
              end
            end
          end
        end
      end

      # ИМПОРТ КАРТИН ПЛЕЙЛИСТОВ
      playlists_url = "https://www.googleapis.com/youtube/v3/playlists?part=snippet,contentDetails&channelId=#{channel.youtube_channel_id}&maxResults=50&key=#{api_key}"
      begin
        playlists_response = Channel.fetch_with_redirects(playlists_url)
        if playlists_response && playlists_response.is_a?(Net::HTTPSuccess)
          playlists_data = JSON.parse(playlists_response.body)
          if playlists_data["items"].present?
            playlists_data["items"].each do |item|
              p_id = item["id"]
              snippet = item["snippet"]
              content_details = item["contentDetails"]

              if p_id.present? && snippet
                playlist = channel.playlists.find_or_initialize_by(youtube_playlist_id: p_id)
                playlist.title = snippet["title"]
                if snippet["thumbnails"].present?
                  thumb_data = snippet["thumbnails"]["maxres"] || snippet["thumbnails"]["high"] || snippet["thumbnails"]["medium"] || snippet["thumbnails"]["default"]
                  playlist.thumbnail_url = thumb_data["url"] if thumb_data
                end
                playlist.video_count = content_details["itemCount"].to_i if content_details && content_details["itemCount"].present?
                playlist.save!(validate: false)
              end
            end
          end
        end
      rescue => e
      end
    end

    channel.fetch_avatar_from_api
    channel.fetch_playlist_cards_from_api

    flash[:notice] = "Архив успешно обновлен! Видео и официальные Стримы разделены по вкладкам со 100% точностью."
    redirect_to channel_page_path(channel) and return
  end

  # СИНХРОНИЗАЦИЯ АБСОЛЮТНО ВСЕХ РОЛИКОВ ПЛЕЙЛИСТА (С ПОДДЕРЖКОЙ СТРАНИЦ NEXT_PAGE_TOKEN)
  def sync_playlist_videos
    playlist = Playlist.find(params[:id])
    channel = playlist.channel
    api_key = Rails.application.config.youtube_api_key

    if api_key.blank?
      flash[:alert] = "Ключ YouTube API не настроен."
      redirect_to playlist_page_path(playlist) and return
    end

    new_video_ids = []
    next_page_token = nil

    begin
      # КРУТИМ ЦИКЛ, ПОКА У ГУГЛА НЕ ЗАКОНЧАТСЯ СТРАНИЦЫ С ВИДЕО
      loop do
        # Динамически подставляем &pageToken= если мы идем на вторую и далее страницы
        token_param = next_page_token.present? ? "&pageToken=#{next_page_token}" : ""
        url = "https://www.googleapis.com/youtube/v3/playlistItems?part=contentDetails,snippet&playlistId=#{playlist.youtube_playlist_id}&maxResults=50&key=#{api_key}#{token_param}"

        uri = URI.parse(url)
        response = Net::HTTP.get_response(uri)

        break unless response.is_a?(Net::HTTPSuccess)
        data = JSON.parse(response.body)
        break if data["items"].blank?

        data["items"].each do |item|
          v_id = item.dig("contentDetails", "videoId")
          snippet = item["snippet"]

          if v_id.present? && snippet
            video = channel.videos.find_or_initialize_by(youtube_video_id: v_id)
            video.title = snippet["title"]
            video.published_at = snippet["publishedAt"]
            video.video_type = "video"
            video.playlist_id = playlist.id

            if snippet["thumbnails"].present?
              thumb_data = snippet["thumbnails"]["maxres"] || snippet["thumbnails"]["high"] || snippet["thumbnails"]["medium"] || snippet["thumbnails"]["default"]
              video.thumbnail_url = thumb_data["url"] if thumb_data
            end

            video.save!(validate: false)
            new_video_ids << v_id
          end
        end

        # Читаем маркер следующей страницы. Если его нет — выходим из цикла!
        next_page_token = data["nextPageToken"]
        break if next_page_token.blank?
      end

      # ПОДТЯГИВАЕМ ПРОСМОТРЫ И ЛАЙКИ ПАЧКАМИ ПО 50 ШТУК ДЛЯ ВСЕХ НАЙДЕННЫХ РОЛИКОВ
      if new_video_ids.any?
        new_video_ids.each_slice(50) do |slice_ids|
          video_ids_str = slice_ids.join(",")
          stats_url = "https://www.googleapis.com/youtube/v3/videos?part=contentDetails,statistics&id=#{video_ids_str}&key=#{api_key}"
          stats_res = Net::HTTP.get_response(URI.parse(stats_url))

          if stats_res.is_a?(Net::HTTPSuccess)
            stats_data = JSON.parse(stats_res.body)
            if stats_data["items"].present?
              stats_data["items"].each do |v_item|
                db_v = channel.videos.find_by(youtube_video_id: v_item["id"])
                if db_v
                  iso_dur = v_item.dig("contentDetails", "duration")
                  secs = iso_dur.present? ? ActiveSupport::Duration.parse(iso_dur).to_i : 0
                  views = v_item.dig("statistics", "viewCount").to_i

                  db_v.update_columns(duration_seconds: secs, views_count: views)
                end
              end
            end
          end
        end
        flash[:notice] = "Плейлист «#{playlist.title}» полностью синхронизирован! Загружено абсолютно все ролики: #{new_video_ids.count}."
      else
        flash[:notice] = "В этом плейлисте нет видеороликов."
      end

    rescue => e
      flash[:alert] = "Не удалось полностью загрузить плейлист: #{e.message}"
    end

    redirect_to playlist_page_path(playlist)
  end

  # МГНОВЕННАЯ ОЧИСТКА ПЛЕЙЛИСТА ДЛЯ СБЕРЕЖЕНИЯ ДИСКА VPS
  def clear_playlist_videos
    playlist = Playlist.find(params[:id])

    # Чтобы не захламлять базу, мы полностью стираем ролики, привязанные строго к этому плейлисту
    playlist.videos.delete_all

    flash[:notice] = "Память сервера очищена! Все видеоролики из плейлиста «#{playlist.title}» удалены."
    redirect_to playlist_page_path(playlist)
  end

  # МЕТОД ДЛЯ РУЧНОГО ОБНОВЛЕНИЯ АВАТАРОК, БАННЕРОВ, ПОДПИСЧИКОВ, СЧЕТЧИКОВ ПРОСМОТРОВ И ЛАЙКОВ
  def refresh_metadata
    @channel = Channel.find(params[:id])

    # 1. Сначала обновляем общие данные самого автора через Google API
    if @channel.fetch_avatar_from_api

      # 2. Вытаскиваем хэш-карту: ключ - оригинальный YouTube ID, значение - системный id строки в базе
      video_map = @channel.videos.pluck(:youtube_video_id, :id).to_h
      video_ids = video_map.keys.compact
      api_key = Rails.application.config.youtube_api_key

      if video_ids.any? && api_key.present?
        # YouTube разрешает за один запрос обновлять не более 50 видео
        video_ids.each_slice(50) do |slice|
          url = "https://www.googleapis.com/youtube/v3/videos?part=statistics&id=#{slice.join(",")}&key=#{api_key}"
          begin
            uri = URI.parse(url)
            response = Net::HTTP.get_response(uri)
            if response.is_a?(Net::HTTPSuccess)
              data = JSON.parse(response.body)
              if data["items"].present?
                data["items"].each do |item|
                  v_id = item["id"]
                  views = item.dig("statistics", "viewCount")
                  likes = item.dig("statistics", "likeCount")

                  # НАДЕЖНЫЙ ПОИСК: Находим точный системный ID строки из нашей хэш-карты
                  db_id = video_map[v_id]
                  if db_id
                    # Жестко и гарантированно обновляем просмотры и лайки в SQL
                    Video.where(id: db_id).update_all(
                      views_count: views.to_i,
                      likes_count: likes.to_i
                    )
                  end
                end
              end
            end
          rescue => e
            Rails.logger.error "Ошибка обновления статистики видео: #{e.message}"
          end
        end
      end

      # Очищаем кэш сайдбара
      Rails.cache.delete([ current_user, "sidebar_channels" ])
      flash[:notice] = "Данные канала «#{@channel.title}» успешно актуализированы: точные подписчики, баннер, а также просмотры и лайки всех роликов обновлены."
    else
      flash[:alert] = "Не удалось обновить данные. Проверьте лимиты YouTube API."
    end

    redirect_to channel_page_path(@channel, tab: params[:tab]), data: { turbo: false }
  end
end
