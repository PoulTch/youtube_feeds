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
    youtube_id = params[:youtube_channel_id].strip

    if youtube_id.present?
      channel = Channel.create_by_id(youtube_id)
      if channel
        channel.fetch_videos
        flash[:notice] = "Канал '#{channel.title}' успешно добавлен!"
      else
        flash[:alert] = "Не удалось добавить канал. Проверьте ID."
      end
    else
      flash[:alert] = "ID канала не может быть пустым."
    end

    redirect_to root_path
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

  # БРОНЕБОЙНЫЙ ИМПОРТ АРХИВА + УМНЫЙ СБОР АВАТАРОК
  def fetch_channel_archive
    channel = Channel.find(params[:id])
    imported_count = 0

    # ИСПРАВЛЕНО: Теперь тут строго правильная ссылка на страницу со всеми видеороликами автора!
    channel_url = "https://www.youtube.com/channel/#{channel.youtube_channel_id}/videos"

    powershell_path = "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
    ytdlp_path = "C:\\Windows\\System32\\yt-dlp.exe"

    cmd = "#{powershell_path} -Command \"& '#{ytdlp_path}' --flat-playlist --playlist-end 100 --dump-json '#{channel_url}'\""
    time_offset = 0

    begin
      IO.popen(cmd) do |io|
        io.each_line do |line|
          clean_line = line.encode("UTF-8", invalid: :replace, undef: :replace, replace: "").strip
          next unless clean_line.start_with?("{")

          begin
            video_data = JSON.parse(clean_line)
            video_id = video_data["id"]
            video_title = video_data["title"]

            # Искусственная хронология
            published_at = Time.current - time_offset.hours
            time_offset += 12

            thumbnail_url = nil
            if video_data["thumbnails"].present? && video_data["thumbnails"].is_a?(Array)
              thumbnail_url = video_data["thumbnails"].last["url"]
            end

            if video_id.present?
              video = channel.videos.find_or_initialize_by(youtube_video_id: video_id)
              video.title = video_title
              video.published_at = published_at
              video.thumbnail_url = thumbnail_url
              video.save!(validate: false)
              imported_count += 1
            end
          rescue => e
            # Пропускаем битые строки
          end
        end
      end
    rescue => e
      flash[:alert] = "Ошибка импорта архива: #{e.message}"
      redirect_to channel_page_path(channel) and return
    end

    # НАШ ТРИУМФАЛЬНЫЙ ФИНАЛ: Запускаем оригинальный сборщик аватарки через yt-dlp!
    # Он сам выкачает настоящее фото, а если не сможет — оставит DiceBear как страховку.
    channel.fetch_avatar_from_api

    # Отправляем флеш-уведомление
    if imported_count > 0
      flash[:notice] = "Ура! Сетевой мост Windows пробит. Из истории автора «#{channel.title}» успешно загружено роликов: #{imported_count}. Сайдбар и оригинальная аватарка обновлены!"
    else
      flash[:notice] = "Все доступные архивные ролики для «#{channel.title}» уже в вашей базе данных! Оригинальная аватарка обновлена."
    end

    # ЖЕЛЕЗНЫЙ РЕДИРЕКТ С ОТКЛЮЧЕНИЕМ TURBO ДЛЯ ОБНОВЛЕНИЯ САЙДБАРА
    redirect_to channel_page_path(channel), data: { turbo: false }
  end
end
