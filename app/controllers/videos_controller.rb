class VideosController < ApplicationController
  # 1. Главная страница со всеми видео
  def index
    @videos = Video.includes(:channel).order(published_at: :desc)
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

    @videos = @channel.videos.order(published_at: :desc)
  end

  # Новый метод для страницы просмотра видео
  def show
    @video = Video.find(params[:id])
  end
end
