class VideosController < ApplicationController
  # 1. Главная страница со всеми видео
  def index
    # Берем видео, у которых либо нет прогресса, либо просмотрено меньше 90% (оставляем зазор на титры)
    @videos = Video.includes(:channel)
                   .where("watched_seconds IS NULL OR watched_seconds < (duration_seconds * 0.9)")
                   .order(published_at: :desc)
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
                    seconds = 0
                    match = iso_duration.match(/PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?/)
                    if match
                      hours   = match[1].to_i
                      minutes = match[2].to_i
                      secs    = match[3].to_i
                      seconds = (hours * 3600) + (minutes * 60) + secs
                    end
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



  # 3. Страница конкретного одного канала (Вынесена отдельно!)
  def show_channel
    @channel = Channel.find_by(id: params[:id])

    if @channel.nil?
      flash[:alert] = "К сожалению, этот канал не найден в базе данных."
      redirect_to root_path and return
    end

    # Сортируем сначала по дате публикации, а если они одинаковые — по ID видео, чтобы не было хаоса!
    @videos = @channel.videos
                      .where("watched_seconds IS NULL OR watched_seconds < (duration_seconds * 0.9)")
                      .order(published_at: :desc, id: :desc)
  end

  # Новый метод для страницы просмотра видео
  def show
    @video = Video.find(params[:id])
  end

  # Метод вызывается из JS в фоне
  def save_progress
    video = Video.find(params[:id])

    # Обновляем колонки в базе данных
    video.update(
      watched_seconds: params[:current_time],
      duration_seconds: params[:total_time]
    )

    head :ok # Отвечаем браузеру, что всё прошло успешно
  end

    # Метод для импорта подписок из CSV-файла YouTube
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
            rss_url = "https://youtube.com/feeds/videos.xml?channel_id=#{youtube_id}"

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
      flash[:alert] = "Пожалуйста, выберите файл для加载."
    end

    redirect_to root_path
  end

  # Метод для удаления канала и всех его видеороликов
  def destroy
    @channel = Channel.find(params[:id])
    @channel.destroy # Благодаря dependent: :destroy все видео канала сотрутся автоматически!
        flash[:notice] = "Канал «#{@channel.title}» и все его видео успешно удалены."
    redirect_to root_path
  end

  # БРОНЕБОЙНЫЙ РЕАКТИВНЫЙ ИМПОРТ АРХИВА С ПРИНУДИТЕЛЬНОЙ СВЕРКОЙ GOOGLE API v3
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

              # ИСПРАВЛЕНО: Безусловно добавляем ID каждого ролика в массив для тотальной сверки через API
              new_video_ids << video_id

              video.title = video_title if video.title.blank?
              video.published_at ||= Time.current # Временный маркер, Google API его перепишет через секунду

              if video_data["thumbnails"].present? && video_data["thumbnails"].is_a?(Array)
                video.thumbnail_url = video_data["thumbnails"].last["url"]
              end
              video.save!(validate: false)
            end
          rescue => e
            # Пропускаем битые строки
          end
        end
      end

      # МАГИЯ GOOGLE API v3: Тотально запрашиваем точные даты и русские названия для ВСЕХ найденных видео!
      if new_video_ids.any?
        api_key = ENV["YOUTUBE_API_KEY"]

        # Разбиваем массив ID на пачки по 50 штук (лимит Google)
        new_video_ids.uniq.each_slice(50) do |slice|
          ids_string = slice.join(",")
          api_url = "https://www.googleapis.com/youtube/v3/videos?part=snippet,contentDetails&id=#{ids_string}&key=#{api_key}"

          response = Channel.fetch_with_redirects(api_url)
          if response && response.is_a?(Net::HTTPSuccess)
            api_data = JSON.parse(response.body)
            if api_data["items"].present?
              api_data["items"].each do |item|
                v_id = item["id"]
                snippet = item["snippet"]

                db_video = channel.videos.find_by(youtube_video_id: v_id)
                if db_video && snippet
                  # ЖЕСТКАЯ ПЕРЕЗАПИСЬ: Стираем старый хаос и пишем 100% официальную дату Google!
                  db_video.title = snippet["title"] if snippet["title"].present?
                  db_video.published_at = snippet["publishedAt"] # ПРИНУДИТЕЛЬНО ОБНОВЛЯЕМ ДАТУ ДО СЕКУНДЫ!
                  db_video.description = snippet["description"] if snippet["description"].present?
                  db_video.save!(validate: false)
                end
              end

            end
          end
        end
      end

      # Выкачиваем оригинальную аватарку автора
      channel.fetch_avatar_from_api

      flash[:notice] = "Архив успешно синхронизирован с Google API! Проверено роликов: #{new_video_ids.uniq.size}"
      redirect_to channel_page_path(channel) and return

    rescue => e
      flash[:alert] = "Ошибка импорта архива: #{e.message}"
      redirect_to channel_page_path(channel) and return
    end
  end
end
