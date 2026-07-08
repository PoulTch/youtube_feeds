class VideosController < ApplicationController
  # 1. Главная страница со всеми видео + ИЗОЛИРОВАННАЯ ИСТОРИЯ ПРОСМОТРОВ
  def index
    # ЖЕСТКИЙ СЕКУНДНЫЙ ЗАЗОР: Ролик улетает из истории строго за 10 секунд до финала!
    # (duration_seconds - watched_seconds > 10)
    @history_videos = Video.includes(:channel)
                           .where("watched_seconds > 0 AND (duration_seconds - watched_seconds) > 10")
                           .order(updated_at: :desc)

    # Общая лента контента
    @videos = Video.includes(:channel).order(published_at: :desc)
  end



  # 2. Обработка формы добавления нового канала
  def create_channel
    youtube_id = params[:youtube_channel_id].to_s.strip

    if youtube_id.present?
      channel = Channel.find_by(youtube_channel_id: youtube_id) || Channel.create_by_id(youtube_id)

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
                    # ИСПРАВЛЕНО: Безопасная официальная магия Rails 8 без MatchData конфликтов!
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
      else
        flash[:alert] = "Не удалось добавить канал. Проверьте ID."
      end
    else
      flash[:alert] = "ID канала не может быть пустым."
    end

    # Жёсткий редирект для мгновенной перерисовки сайдбара
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

  # 8. УЛЬТИМАТИВНЫЙ АВТОНОМНЫЙ КВАДРО-ИМПОРТ С ГАРАНТИРОВАННЫМ НАПОЛНЕНИЕМ ПЛЕЙЛИСТОВ
  def fetch_channel_archive
    channel = Channel.find(params[:id])
    new_video_ids = []

    channel_url = "https://www.youtube.com/channel/#{channel.youtube_channel_id}"

    powershell_path = "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
    ytdlp_path = "C:\\Windows\\System32\\yt-dlp.exe"

    # Быстрый flat-playlist для мгновенного сбора ID роликов в массив
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

      # МАГИЯ GOOGLE API v3: Расчет секунд и хронологии
      api_key = ENV["YOUTUBE_API_KEY"]
      if new_video_ids.any? && api_key.present?
        new_video_ids.uniq.each_slice(50) do |slice|
          ids_string = slice.join(",")
          api_url = "https://www.googleapis.com/youtube/v3/videos?part=contentDetails,snippet&id=#{ids_string}&key=#{api_key}"

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

      # МАГИЯ ОФИЦИАЛЬНЫХ ПЛЕЙЛИСТОВ + ПРИНУДИТЕЛЬНЫЙ ДЕСАНТ ПО СУЩЕСТВУЮЩИМ ПАПКАМ
      if api_key.present?
        # 1-й проход: Пробуем собрать публичные плейлисты
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
                  playlist.thumbnail_url = snippet.dig("thumbnails", "high", "url") || snippet.dig("thumbnails", "default", "url")
                  playlist.video_count = content_details["itemCount"].to_i if content_details
                  playlist.save!(validate: false)
                end
              end
            end
          end
        rescue => e
          Rails.logger.error "Ошибка первого прохода плейлистов: #{e.message}"
        end

        # 2-й проход: ГАРАНТИРОВАННОЕ ГЛУБОКОЕ НАПОЛНЕНИЕ С ПАГИНАЦИЕЙ СТРАНИЦ GOOGLE API!
        channel.playlists.each do |playlist|
          next_page_token = nil

          # Запускаем цикл, который будет крутиться, пока у Гугла не кончатся страницы с роликами
          loop do
            page_param = next_page_token.present? ? "&pageToken=#{next_page_token}" : ""
            items_url = "https://www.googleapis.com/youtube/v3/playlistItems?part=snippet&playlistId=#{playlist.youtube_playlist_id}&maxResults=50#{page_param}&key=#{api_key}"

            begin
              items_response = Channel.fetch_with_redirects(items_url)
              break unless items_response && items_response.is_a?(Net::HTTPSuccess)

              items_data = JSON.parse(items_response.body)

              # Запоминаем токен следующей страницы
              next_page_token = items_data["nextPageToken"]

              if items_data["items"].present?
                items_data["items"].each do |pi_item|
                  pv_id = pi_item.dig("snippet", "resourceId", "videoId")
                  pv_title = pi_item.dig("snippet", "title")

                  if pv_id.present?
                    p_video = channel.videos.find_or_initialize_by(youtube_video_id: pv_id)
                    p_video.title = pv_title if p_video.title.blank?
                    p_video.playlist_id = playlist.id # Намертво привязываем видеоролик к папке!
                    p_video.published_at ||= pi_item.dig("snippet", "publishedAt") || Time.current

                    if pi_item.dig("snippet", "thumbnails").present?
                      p_thumb = pi_item.dig("snippet", "thumbnails", "high", "url") || pi_item.dig("snippet", "thumbnails", "default", "url")
                      p_video.thumbnail_url ||= p_thumb
                    end
                    p_video.save!(validate: false)
                  end
                end
              end

              # Если следующей страницы у плейлиста нет — останавливаем бесконечный цикл
              break if next_page_token.blank?

            rescue => e
              Rails.logger.error "Ошибка пагинации для плейлиста #{playlist.title}: #{e.message}"
              break
            end
          end

          # После того как выкачали абсолютно все страницы — обновляем счетчик видео в базе
          playlist.update_columns(video_count: playlist.videos.count)
        end

      end

      # Выкачиваем оригинальную аватарку автора
      channel.fetch_avatar_from_api

      flash[:notice] = "Автономный квадро-архив успешно обновлен! Все папки заполнились контентом."
      redirect_to channel_page_path(channel) and return

    rescue => e
      flash[:alert] = "Ошибка импорта архива: #{e.message}"
      redirect_to channel_page_path(channel) and return
    end
  end
end
