class VideosController < ApplicationController
  # Отключаем проверку токена для сохранения секунд, так как запросы идут фоном через JS
  skip_before_action :verify_authenticity_token, only: [ :save_progress ]

  # 1. Главная страница со всеми видео + ИЗОЛИРОВАННАЯ ИСТОРИЯ ПРОСМОТРОВ
  def index
    # Берем видео с просмотрами и фильтруем через Ruby (вычитание гарантированно сработает)
    @history_videos = Video.includes(:channel)
                           .where("watched_seconds > 0")
                           .order(updated_at: :desc)
                           .select { |v| v.duration_seconds && v.watched_seconds && (v.duration_seconds - v.watched_seconds) > 10 }

    # ИЗОЛИРУЕМ общую ленту
    videos_relation = Video.includes(:channel).order(published_at: :desc)

    # Применяем пагинацию СТРОГО к общей ленте
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

        # 2. МГНОВЕННЫЙ ДЕСАНТ ВРЕМЕНИ: Качаем длительность видеороликов через API v3 прямо сейчас!
        api_key = Rails.application.config.youtube_api_key
        videos_to_update = channel.videos.where(duration_seconds: nil).limit(20)

        if api_key.present? && videos_to_update.any?
          video_ids = videos_to_update.map(&:youtube_video_id).join(",")
          url = "https://www.googleapis.com/youtube/v3/videos?part=contentDetails&id=#{video_ids}&key=#{api_key}"
          begin
            uri = URI.parse(url)
            response = Net::HTTP.get_response(uri)
            if response.is_a?(Net::HTTPSuccess)
              data = JSON.parse(response.body)
              if data["items"].present?
                data["items"].each do |item|
                  v_id = item["id"]
                  iso_duration = item.dig("contentDetails", "duration")
                  if iso_duration.present?
                    seconds = ActiveSupport::Duration.parse(iso_duration).to_i
                    if seconds > 0
                      v = channel.videos.find_by(youtube_video_id: v_id)
                      v.update_columns(duration_seconds: seconds) if v
                    end
                  end
                end
              end
            end
          rescue => e
            Rails.logger.error "Ошибка быстрого сбора времени при создании канала: #{e.message}"
          end
        end

        # 3. МГНОВЕННЫЙ СБОР МЕТАДАННЫХ: Качаем оригинальную аватарку и баннер
        channel.fetch_avatar_from_api

        flash[:notice] = "Канал '#{channel.title}' успешно добавлен! Все тайминги и оформление на месте."
        redirect_to channel_page_path(channel), data: { turbo: false } and return
      else
        flash[:alert] = "Не удалось добавить канал. Проверьте правильность ID."
      end
    else
      flash[:alert] = "ID канала не может быть пустым."
    end

    redirect_to root_path, data: { turbo: false }
  end

  # 3. Страница конкретного одного канала (С ПОДДЕРЖКОЙ ВКЛАДОК И СОРТИРОВКИ ХРОНОЛОГИИ)
  def show_channel
    @channel = Channel.find_by(id: params[:id])

    if @channel.nil?
      flash[:alert] = "К сожалению, этот канал не найден в базе данных."
      redirect_to root_path and return
    end

    # Запоминаем текущую вкладку (по умолчанию — "videos")
    @current_tab = params[:tab] || "videos"

    # Запоминаем текущую сортировку (по умолчанию — "desc", то есть Новые сверху)
    @current_sort = params[:sort] || "desc"

    if @current_tab == "playlists"
      @playlists = @channel.playlists.order(title: :asc)
    else
      # Переворачиваем запрос в зависимости от нажатой кнопки!
      if @current_sort == "asc"
        # Старые: от древних к новым (published_at по возрастанию)
        @videos = @channel.videos.order(published_at: :asc, id: :asc)
      else
        # Новые: от свежих к древним (published_at по убыванию)
        @videos = @channel.videos.order(published_at: :desc, id: :desc)
      end
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

  # 5. Метод вызывается из JS в фоне для сохранения прогресса просмотра
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

  # 7. Метод для удаления канала и всех его видеороликов (РАБОТАЕТ С ФЛЭШЕМ И КНОПКОЙ ОТПИСКИ)
  def destroy
    @channel = Channel.find(params[:id])
    @channel.destroy # Благодаря dependent: :destroy все видео канала сотрутся автоматически!
    flash[:notice] = "Канал «#{@channel.title}» и все его видео успешно удалены."
    redirect_to root_path
  end

  # 8. БРОНЕБОЙНЫЙ РЕАКТИВНЫЙ ИМПОРТ АРХИВА С АВТОМАТИЧЕСКИМ СКАНЕРОМ ПУСТЫХ ТАЙМИНГОВ
  def fetch_channel_archive
    channel = Channel.find(params[:id])
    new_video_ids = []

    channel_url = "https://www.youtube.com/channel/#{channel.youtube_channel_id}"
    powershell_path = "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
    ytdlp_path = "C:\\Windows\\System32\\yt-dlp.exe"

    # 1. Быстрый сбор свежей сотни ID роликов, чтобы мгновенно обновить ленту новинками
    cmd = "#{powershell_path} -Command \"& '#{ytdlp_path}' --flat-playlist --playlist-end 100 --dump-json '#{channel_url}'\""

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
              video = channel.videos.find_or_initialize_by(youtube_video_id: video_id)
              new_video_ids << video_id

              video.title = video_title if video.title.blank?
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

      api_key = ENV["YOUTUBE_API_KEY"]

      if api_key.present?
        # 🎯 АВТОМАТИЗАЦИЯ: Собираем ID свежей сотни + добавляем ВСЕ ролики этого канала, у которых пустые тайминги!
        # Это навсегда избавит нас от ручной работы в консоли для старых видео!
        historic_blank_ids = channel.videos.where(duration_seconds: [ nil, 0 ]).pluck(:youtube_video_id)

        # Склеиваем массивы и убираем дубликаты
        total_ids_to_sync = (new_video_ids + historic_blank_ids).uniq.compact

        # 2. ПАКЕТНАЯ СИНХРОНИЗАЦИЯ С GOOGLE API v3 (Пачками по 50 штук)
        if total_ids_to_sync.any?
          total_ids_to_sync.each_slice(50) do |slice|
            ids_string = slice.join(",")
            api_url = "https://www.googleapis.com/youtube/v3/videos?part=snippet,contentDetails&id=#{ids_string}&key=#{api_key}"

            response = Channel.fetch_with_redirects(api_url)
            if response && response.is_a?(Net::HTTPSuccess)
              api_data = JSON.parse(response.body)
              if api_data["items"].present?
                api_data["items"].each do |item|
                  v_id = item["id"]
                  snippet = item["snippet"]
                  content_details = item["contentDetails"]

                  db_video = channel.videos.find_by(youtube_video_id: v_id)
                  if db_video && snippet
                    db_video.title = snippet["title"] if snippet["title"].present?
                    db_video.published_at = snippet["publishedAt"]
                    db_video.description = snippet["description"] if snippet["description"].present?

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

        # 3. ИМПОРТ ОФИЦИАЛЬНЫХ ПЛЕЙЛИСТОВ
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

                  if content_details && content_details["itemCount"].present?
                    playlist.video_count = content_details["itemCount"].to_i
                  end

                  playlist.save!(validate: false)

                  # Глубокая пагинация роликов плейлиста
                  next_page_token = nil
                  loop do
                    page_param = next_page_token.present? ? "&pageToken=#{next_page_token}" : ""
                    items_url = "https://www.googleapis.com/youtube/v3/playlistItems?part=snippet&playlistId=#{p_id}&maxResults=50#{page_param}&key=#{api_key}"

                    items_response = Channel.fetch_with_redirects(items_url)
                    break unless items_response && items_response.is_a?(Net::HTTPSuccess)

                    items_data = JSON.parse(items_response.body)
                    next_page_token = items_data["nextPageToken"]

                    if items_data["items"].present?
                      items_data["items"].each do |pi_item|
                        pv_id = pi_item.dig("snippet", "resourceId", "videoId")
                        pv_title = pi_item.dig("snippet", "title")

                        if pv_id.present?
                          p_video = channel.videos.find_or_initialize_by(youtube_video_id: pv_id)
                          p_video.title = pv_title if p_video.title.blank?
                          p_video.playlist_id = playlist.id
                          p_video.published_at ||= pi_item.dig("snippet", "publishedAt") || Time.current

                          if pi_item.dig("snippet", "thumbnails").present?
                            p_thumb = pi_item.dig("snippet", "thumbnails", "high", "url") || pi_item.dig("snippet", "thumbnails", "default", "url")
                            p_video.thumbnail_url ||= p_thumb
                          end
                          p_video.save!(validate: false)
                        end
                      end
                    end
                    break if next_page_token.blank?
                  end
                end
              end
            end
          end
        rescue => e
          Rails.logger.error "Ошибка автоматического сбора плейлистов: #{e.message}"
        end
      end

      channel.fetch_avatar_from_api
      flash[:notice] = "Архив успешно обновлен! Все старые и новые тайминги синхронизированы автоматически."
      redirect_to channel_page_path(channel) and return

    rescue => e
      flash[:alert] = "Ошибка импорта архива: #{e.message}"
      redirect_to channel_page_path(channel) and return
    end
  end
end
