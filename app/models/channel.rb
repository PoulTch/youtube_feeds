require "net/http"
require "rexml/document"

class Channel < ApplicationRecord
  has_many :videos, dependent: :destroy

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

  # Метод для скачивания видеороликов конкретного канала
  def fetch_videos
    puts "=== [РОБОТ] Начинаю скачивать видео для канала: #{title} (ID: #{youtube_channel_id}) ==="

    correct_rss_url = "https://www.youtube.com/feeds/videos.xml?channel_id=#{youtube_channel_id}"

    response = Channel.fetch_with_redirects(correct_rss_url)

    if response.nil? || !response.is_a?(Net::HTTPSuccess)
      puts "=== [РОБОТ ОШИБКА] Не удалось скачать фид для канала #{title} ==="
      return false
    end

    doc = REXML::Document.new(response.body)
    puts "=== [РОБОТ] XML успешно скачан. Начинаю парсить ролики... ==="

    doc.each_element("feed/entry") do |entry|
      video_id = entry.elements["yt:videoId"]&.text
      title = entry.elements["title"]&.text
      published_at = entry.elements["published"]&.text

      thumb_element = entry.elements["media:group/media:thumbnail"]
      thumbnail_url = thumb_element ? thumb_element.attributes["url"] : nil

      description = entry.elements["media:group/media:description"]&.text

      next if video_id.nil?

      video = videos.find_or_initialize_by(youtube_video_id: video_id)
      video.title = title
      video.published_at = published_at
      video.thumbnail_url = thumbnail_url
      video.description = description
      video.save
    end

    true
  end

  # ОФИЦИАЛЬНЫЙ МЕТОД ОБНОВЛЕНИЯ МЕТАДАННЫХ (АВАТАРКА + ОБЛОЖКА БАННЕРА)
  def fetch_avatar_from_api
    api_key = Rails.application.config.youtube_api_key
    return if api_key.blank? || youtube_channel_id.blank?

    # Добавляем в part параметр brandingSettings — именно там лежат баннеры-заставки!
    url = "https://www.googleapis.com/youtube/v3/channels?part=snippet,brandingSettings&id=#{youtube_channel_id}&key=#{api_key}"

    begin
      uri = URI.parse(url)
      response = Net::HTTP.get_response(uri)

      if response.is_a?(Net::HTTPSuccess)
        data = JSON.parse(response.body)
        item = data.dig("items", 0)
        return false unless item

        # 1. Вытаскиваем аватарку
        avatar_url_from_api = item.dig("snippet", "thumbnails", "high", "url") ||
                              item.dig("snippet", "thumbnails", "medium", "url")

        # 2. Вытаскиваем сочную узкую обложку (баннер) канала
        banner_url_from_api = item.dig("brandingSettings", "image", "bannerExternalUrl")
        # Google отдает баннер без параметров, добавим технический хвост для идеального отображения на ПК:
        banner_url_from_api = "#{banner_url_from_api}=w1060-fcrop64=1,00005a57ffffaa57-k-no-nd-v1" if banner_url_from_api.present?

        # Жестко пишем оба параметра в базу данных PostgreSQL за один микро-запрос!
        updates = {}
        updates[:avatar_url] = avatar_url_from_api if avatar_url_from_api.present?
        updates[:banner_url] = banner_url_from_api if banner_url_from_api.present?

        if updates.any?
          self.update_columns(updates)
          puts "--> [API GOOGLE] Успешно обновлены аватарка и БАННЕР для: #{self.title}"
          return true
        end
      end
    rescue => e
      Rails.logger.error "Ошибка сбора метаданных через YouTube API: #{e.message}"
    end
    false
  end


  # ВОЗВРАЩЕН ИЗ НЕБЫТИЯ: Вспомогательный метод класса для пробития редиректов Гугла
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
