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

    @videos = @channel.videos
                      .where("watched_seconds IS NULL OR watched_seconds < (duration_seconds * 0.9)")
                      .order(published_at: :desc)
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
end
