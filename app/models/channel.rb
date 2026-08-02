require "net/http"
require "rexml/document"

class Channel < ApplicationRecord
    # 1. СНАЧАЛА удаляем плейлисты. Но используем :destroy, чтобы сработали правила внутри самой модели Playlist!
    has_many :playlists, dependent: :destroy

    # 2. И только ПОСЛЕ этого очищаем видеоролики канала одной быстрой SQL-командой
    has_many :videos, dependent: :delete_all

  # Метод для создания/обновления канала по его ID
  def self.create_by_id(youtube_id)
    rss_url = "https://www.youtube.com/feeds/videos.xml?channel_id=#{youtube_id}"

    # Используем метод с редиректами
    response = Channel.fetch_with_redirects(rss_url)
    return nil if response.nil? || !response.is_a?(Net::HTTPSuccess)

    doc = REXML::Document.new(response.body)

    title_node = doc.elements["feed/title"]
    channel_title = title_node ? title_node.text : "Неизвестный канал"

    channel = find_or_initialize_by(youtube_channel_id: youtube_id)
    channel.title = channel_title
    channel.rss_url = rss_url
    channel.save
    channel
  end

  # Метод для скачивания video-роликов конкретного канала
  def fetch_videos
    puts "=== [РОБОТ] Начинаю скачивать видео для канала: #{title} (ID: #{youtube_channel_id}) ==="

    correct_rss_url = "https://www.youtube.com/feeds/videos.xml?channel_id=#{youtube_channel_id}"

    response = Channel.fetch_with_redirects(correct_rss_url)

    if response.nil? || !response.is_a?(Net::HTTPSuccess)
      puts "=== [РОБОТ ОШИБКА] Не удалось скачать фид для канала #{title} ==="
      return false
    end

    # ВОТ ЭТА СПАСИТЕЛЬНАЯ СТРОЧКА БЫЛА СЛУЧАЙНО СТЕРТА:
    doc = REXML::Document.new(response.body)
    puts "=== [РОБОТ] XML успешно скачан. Начинаю парсить ролики... ==="

    doc.each_element("feed/entry") do |entry|
      # ИСПОЛЬЗУЕМ СВЕРХТОЧНЫЙ ПОИСК БЕЗ ЗАВЯЗКИ НА НАСТРОЙКИ NAMESPACES СЕРВЕРА
      video_id = entry.elements["*[local-name()='videoId']"]&.text
      title = entry.elements["title"]&.text
      published_at = entry.elements["published"]&.text

      # Ищем группу media:group и внутри нее thumbnail / description
      media_group = entry.elements["*[local-name()='group']"]
      thumbnail_url = nil
      description = nil

      if media_group
        thumb_node = media_group.elements["*[local-name()='thumbnail']"]
        thumbnail_url = thumb_node.attributes["url"] if thumb_node

        desc_node = media_group.elements["*[local-name()='description']"]
        description = desc_node&.text
      end

      # Если вдруг локальный поиск не дал результатов, пробуем старый канонический XML-путь
      video_id ||= entry.elements["yt:videoId"]&.text

      next if video_id.blank?

      video = videos.find_or_initialize_by(youtube_video_id: video_id)
      video.title = title

      # ЖЕЛЕЗНЫЙ КОНТРОЛЬ ВРЕМЕНИ: Парсим дату, и если она улетела в будущее из-за часовых поясов ПК —
      # жестко ставим текущее время, чтобы Pagy мгновенно вывел ролик на экран!
      parsed_time = published_at.present? ? Time.parse(published_at) : Time.current
      video.published_at = parsed_time > Time.current ? Time.current : parsed_time

      video.thumbnail_url = thumbnail_url
      video.description = description

      # НАМЕРТВО маркируем как video, чтобы сразу выкатить на экран
      video.video_type = "video" if video.video_type.blank?

      if video.save
        puts "--> [РОБОТ СХЕМА] Успешно сохранен RSS-ролик: #{video_id}"
      end
    end

    true
  end

  # ОФИЦИАЛЬНЫЙ МЕТОД ОБНОВЛЕНИЯ МЕТАДАННЫХ (АВАТАРКА + ОБЛОЖКА БАННЕРА + ПОДПИСЧИКИ) - ИСПРАВЛЕННЫЙ
  def fetch_avatar_from_api
    api_key = Rails.application.config.youtube_api_key
    return if api_key.blank? || youtube_channel_id.blank?

    # ВНЕДРЕНО: Добавили statistics в part, чтобы забрать счётчик подписчиков
    url = "https://www.googleapis.com/youtube/v3/channels?part=snippet,brandingSettings,statistics&id=#{youtube_channel_id}&key=#{api_key}"

    begin
      uri = URI.parse(url)
      response = Net::HTTP.get_response(uri)

      if response.is_a?(Net::HTTPSuccess)
        data = JSON.parse(response.body)
        item = data.dig("items", 0)
        return false unless item

        # 1. ВОЗВРАЩЕНО НА МЕСТО: Вытаскиваем аватарку
        avatar_url_from_api = item.dig("snippet", "thumbnails", "high", "url") ||
                              item.dig("snippet", "thumbnails", "medium", "url")

        # 2. Вытаскиваем оригинальную обложку (баннер) канала высокой чёткости
        banner_url_from_api = item.dig("brandingSettings", "image", "bannerExternalUrl")

        if banner_url_from_api.present?
          # ВОЗВРАЩАЕМ 2560px: Максимальное HD-качество + канонический десктопный маркер кадрирования
          banner_url_from_api = "#{banner_url_from_api}=w2560-fcrop64=1,00005a57ffffaa57-k-no-nd-v1"
        end

        # 3. ВНЕДРЕНО: Вытаскиваем точное число подписчиков из блока statistics
        sub_count_from_api = item.dig("statistics", "subscriberCount")

        # Жестко пишем все параметры в базу данных PostgreSQL за один микро-запрос!
        updates = {}
        updates[:avatar_url] = avatar_url_from_api if avatar_url_from_api.present?
        updates[:banner_url] = banner_url_from_api if banner_url_from_api.present?
        updates[:subscriber_count] = sub_count_from_api.to_i if sub_count_from_api.present?

        if updates.any?
          self.update_columns(updates)
          puts "--> [API GOOGLE] Успешно обновлены аватарка, баннер и ПОДПИСЧИКИ для: #{self.title}"
          return true
        end
      end
    rescue => e
      Rails.logger.error "Ошибка сбора метаданных через YouTube API: #{e.message}"
    end
    false
  end

  # СВЕРХЭКОНОМНЫЙ АВТОМАТИЧЕСКИЙ СБОР КАРТОЧЕК ПЛЕЙЛИСТОВ (БЕЗ СКАЧИВАНИЯ САМИХ РОЛИКОВ)
  def fetch_playlist_cards_from_api
    api_key = Rails.application.config.youtube_api_key
    return if api_key.blank? || youtube_channel_id.blank?

    playlists_url = "https://www.googleapis.com/youtube/v3/playlists?part=snippet,contentDetails&channelId=#{youtube_channel_id}&maxResults=50&key=#{api_key}"

    begin
      # Пользуемся твоим методом с пробитием редиректов Гугла!
      response = Channel.fetch_with_redirects(playlists_url)
      if response && response.is_a?(Net::HTTPSuccess)
        playlists_data = JSON.parse(response.body)
        if playlists_data["items"].present?
          playlists_data["items"].each do |item|
            p_id = item["id"]
            snippet = item["snippet"]
            content_details = item["contentDetails"]

            if p_id.present? && snippet
              playlist = playlists.find_or_initialize_by(youtube_playlist_id: p_id)
              playlist.title = snippet["title"]

              if snippet["thumbnails"].present?
                thumb_data = snippet["thumbnails"]["maxres"] || snippet["thumbnails"]["high"] || snippet["thumbnails"]["medium"] || snippet["thumbnails"]["default"]
                playlist.thumbnail_url = thumb_data["url"] if thumb_data
              end

              if content_details && content_details["itemCount"].present?
                playlist.video_count = content_details["itemCount"].to_i
              end

              playlist.save!(validate: false)
            end
          end
          puts "--> [API GOOGLE] Успешно подтянуты карточки плейлистов для канала: #{self.title}"
        end
      end
    rescue => e
      Rails.logger.error "Ошибка автоматического сбора карточек плейлистов: #{e.message}"
    end
  end

  # Вспомогательный метод класса для пробития редиректов Гугла
  def self.fetch_with_redirects(url_value, limit = 5)
    return nil if limit.zero?

    uri = URI.parse(url_value)
    request = Net::HTTP::Get.new(uri)
    request["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
      http.request(request)
    end

    case response
    when Net::HTTPSuccess
      response
    when Net::HTTPRedirection
      location = response["location"]
      puts "=== [РОБОТ ИНФО] Редирект #{response.code} на адрес: #{location} ==="
      fetch_with_redirects(location, limit - 1)
    else
      response
    end
  end
end
